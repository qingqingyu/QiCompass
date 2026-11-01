"""Apple App Store Server API 真实 SDK 包装(M2b)。

依赖 `app-store-server-library`(苹果官方 Python SDK),封装:
- AppStoreServerAPIClient:调 Apple getTransactionInfo API(JWT 签名)
- SignedDataVerifier:验签 JWS 响应(ECDSA P-256 + Apple Root CA)

设计要点:
- **lazy import**:SDK 在 __init__ 内 import,缺失时抛 RuntimeError(不污染模块顶部)
  → main.py lifespan 捕获后 fallback MockAppleServerAPI,不阻塞启动
- **翻译层**:SDK 类型 JWSTransactionDecodedPayload 翻译成 AppleTransactionInfo
  dataclass,屏蔽 SDK 类型污染到路由层 / store
- **错误统一**:所有失败模式(网络/签名/SDK 5xx/两环境均 404)统一抛
  AppleVerificationError(502);退款经 is_refunded 标志上抛由路由层定夺
  EntitlementError(403)

线程池策略:SDK 全同步,路由层用 run_in_threadpool 调用。

不引入新依赖:仅依赖 app-store-server-library(用户 2026-07-18 同意)。
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

from ..errors import AppleVerificationError
from .protocol import (
    AppleNotificationPayload,
    AppleTransactionInfo,
)

logger = logging.getLogger(__name__)

# Apple Root CA 证书目录(与本文件同包;证书文件不入 git 的场景见部署文档)
_CERTS_DIR = Path(__file__).parent / "certs"


def _parse_apple_date(ms_timestamp: int | None) -> datetime:
    """Apple 返回的 ms 时间戳 → UTC datetime。

    Apple 的 originalPurchaseDate 是毫秒级 UNIX 时间戳。None 时返回 epoch(占位,
    实际调用方应该确保字段存在)。
    """
    if ms_timestamp is None:
        return datetime(1970, 1, 1, tzinfo=timezone.utc)
    return datetime.fromtimestamp(ms_timestamp / 1000, tz=timezone.utc)


class AppleServerAPIClient:
    """真 SDK 包装类。实现 AppleServerAPI Protocol。

    构造时实际 import SDK + 实例化 **production + sandbox 两套**
    AppStoreServerAPIClient / SignedDataVerifier(TASK-02 2026-11-01:
    App Review 与 TestFlight 在生产构建里用的是沙盒交易,单环境客户端
    查 prod 必 404 → redeem 失败 → 审核被拒 Guideline 2.1;Apple 官方
    协议 = 先查 production,仅"交易不存在"回落 sandbox)。同一组 API key
    / issuer / bundle id 对两环境通用,环境只是 client 构造参数。

    缺 SDK / env 配置 / Root CA 证书时抛 RuntimeError。

    2026-08-23 起 main.py 对本类构造失败**不降级 Mock**(fail-fast 启动失败):
    Mock 验证全通过,env 配齐的生产环境降级 = entitlement 校验形同虚设。
    Mock 只服务 env 未配齐的 dev/test 场景(由 main.py 按 env 判断)。
    """

    def __init__(
        self, *,
        bundle_id: str,
        key_id: str,
        issuer_id: str,
        private_key: str,
        app_apple_id: str,
    ):
        # lazy import:SDK 缺失时抛清晰错误(不污染模块顶部 import)
        try:
            from appstoreserverlibrary.api_client import AppStoreServerAPIClient
            from appstoreserverlibrary.signed_data_verifier import (
                SignedDataVerifier,
            )
            from appstoreserverlibrary.models_library import (
                Environment,
            )
        except ImportError as e:
            raise RuntimeError(
                "app-store-server-library 未安装。"
                "运行 `pip install app-store-server-library>=1.3.0,<2.0.0`"
                f"(import error: {e})"
            ) from e

        self._bundle_id = bundle_id
        self._app_apple_id = app_apple_id

        try:
            roots = _load_apple_root_certs()

            # production 套件(交易查询的第一顺位)
            self._client_prod = AppStoreServerAPIClient(
                signing_key=private_key,
                key_id=key_id,
                bundle_id=bundle_id,
                issuer_id=issuer_id,
                environment=Environment.PRODUCTION,
            )
            self._verifier_prod = SignedDataVerifier(
                root_certificates=roots,
                bundle_id=bundle_id,
                app_apple_id=int(app_apple_id),
                environment=Environment.PRODUCTION,
                enable_online_checks=False,
            )

            # sandbox 套件(App Review / TestFlight 交易的回落顺位;
            # 验签器环境与 JWS payload environment claim 必须一致,选错必失败)
            self._client_sbx = AppStoreServerAPIClient(
                signing_key=private_key,
                key_id=key_id,
                bundle_id=bundle_id,
                issuer_id=issuer_id,
                environment=Environment.SANDBOX,
            )
            self._verifier_sbx = SignedDataVerifier(
                root_certificates=roots,
                bundle_id=bundle_id,
                app_apple_id=int(app_apple_id),
                environment=Environment.SANDBOX,
                enable_online_checks=False,
            )
        except Exception as e:
            # SDK 内部错误(参数格式不对 / 私钥无效等)
            raise RuntimeError(
                f"AppleServerAPIClient 初始化失败: {type(e).__name__}: {e}"
            ) from e

        logger.info(
            "apple_client.init_ok bundle_id=%s environments=production+sandbox",
            bundle_id,
        )

    def verify_transaction(self, transaction_id: str) -> AppleTransactionInfo:
        """调 Apple getTransactionInfo + 验签 → 标准化 dataclass。

        环境策略(TASK-02 2026-11-01):**production 优先,仅 404(交易
        不存在)回落 sandbox**;其他错误(网络 / 签名 / 5xx / 4xx 非 404)
        原样上抛不回落——回落掩盖真实故障违反错误显式传播。两环境均 404
        → 显式 AppleVerificationError(Apple 官方协议如此规定的兜底语义)。

        Raises:
            AppleVerificationError(502):网络 / 签名无效 / 两环境均 404
        """
        payload, environment = self._lookup_transaction(
            "production", transaction_id)
        if payload is None:
            payload, environment = self._lookup_transaction(
                "sandbox", transaction_id)
            if payload is None:
                raise AppleVerificationError(
                    f"交易 {transaction_id} 在 production 与 sandbox 均不存在"
                    f"(App Review / TestFlight 沙盒回落已尝试,两环境 404)"
                )
        return self._translate_payload(payload, transaction_id, environment)

    def _lookup_transaction(
        self, environment: Literal["production", "sandbox"],
        transaction_id: str,
    ) -> tuple[Any, Literal["production", "sandbox"] | None]:
        """单环境查交易 + 用同环境 verifier 验签。

        验签器环境必须与交易 JWS 的 environment claim 一致(选错必验签
        失败),故 prod 查到的用 _verifier_prod、sandbox 查到的用
        _verifier_sbx。

        Returns:
            (payload, environment):payload=None 表示该环境 404(交易不存在,
            调用方可回落另一环境);environment 与入参一致,None 时无意义
        Raises:
            AppleVerificationError:非 404 的 API 错误 / 空响应 / 验签失败
            (不回落,向上抛)
        """
        from appstoreserverlibrary.api_client import APIException

        client, verifier = (
            (self._client_prod, self._verifier_prod)
            if environment == "production"
            else (self._client_sbx, self._verifier_sbx)
        )
        try:
            response = client.get_transaction_info(transaction_id)
            signed_tx_info = response.signedTransactionInfo
            if not signed_tx_info:
                raise AppleVerificationError(
                    f"Apple({environment}) 返回空 signedTransactionInfo "
                    f"(transaction_id={transaction_id})"
                )
            payload = verifier.verify_and_decode_signed_transaction(
                signed_tx_info)
            return payload, environment
        except AppleVerificationError:
            raise
        except APIException as e:
            if e.http_status_code == 404:
                # 交易在该环境不存在:唯一允许触发回落的信号
                return None, None
            api_error_name = getattr(e.api_error, "name", None)
            api_error_desc = (
                f"api_error={api_error_name}" if api_error_name is not None
                else f"raw_api_error={e.raw_api_error}"
            )
            raise AppleVerificationError(
                f"Apple({environment}) getTransactionInfo 失败 "
                f"(transaction_id={transaction_id}): "
                f"http_status={e.http_status_code} "
                f"{api_error_desc} "
                f"{e.error_message or ''}".strip()
            ) from e
        except Exception as e:
            # 统一包装:网络 / 签名 / SDK 内部错误
            raise AppleVerificationError(
                f"Apple({environment}) verify_transaction 失败 "
                f"(transaction_id={transaction_id}): "
                f"{type(e).__name__}: {e}"
            ) from e

    def verify_notification(self, jws_body: str) -> AppleNotificationPayload:
        """验签 Apple Server Notification V2 JWS payload。

        环境路由(TASK-02 2026-11-01):按 JWS payload 的 environment
        claim(嵌在内层 data / summary / externalPurchaseToken,外层
        payload 无此字段——见 _peek_jws_environment 报文格式说明)选
        同环境 verifier(prod/sandbox 验签器互斥,选错必失败)。
        peek 仅用于路由,**不作信任依据**——真实性仍由所选 verifier 的
        ECDSA P-256 + Apple Root CA 验签保证;缺 claim / 值未知 / JWS
        格式坏 → 显式抛错,不猜默认环境。

        Raises:
            AppleVerificationError(502):签名无效 / 解析失败 / 缺 environment
        """
        environment = _peek_jws_environment(jws_body)
        verifier = (
            self._verifier_prod if environment == "production"
            else self._verifier_sbx
        )
        try:
            notification = (
                verifier.verify_and_decode_signed_notification(jws_body)
            )

            # notificationType 是 enum,取 .name 或 .value
            ntype = getattr(
                notification.notificationType, "value",
                getattr(notification.notificationType, "name", str(notification.notificationType)),
            )

            # data.signedTransactionInfo 二次 decode 拿 transaction_id
            # (内层交易 JWS 与通知同环境,用同一个 verifier)
            tx_id = "<unknown>"
            data = getattr(notification, "data", None)
            if data and getattr(data, "signedTransactionInfo", None):
                tx_payload = verifier.verify_and_decode_signed_transaction(
                    data.signedTransactionInfo)
                tx_id = getattr(tx_payload, "transactionId", "<unknown>")

            return AppleNotificationPayload(
                notification_type=str(ntype).upper(),
                transaction_id=str(tx_id),
                environment=environment,
                raw_summary=f"type={ntype}",
            )
        except Exception as e:
            raise AppleVerificationError(
                f"Apple verify_notification 失败({environment}): "
                f"{type(e).__name__}: {e}"
            ) from e

    def _translate_payload(
        self, payload: Any, requested_tx_id: str,
        environment: Literal["production", "sandbox"],
    ) -> AppleTransactionInfo:
        """SDK 的 JWSTransactionDecodedPayload → AppleTransactionInfo。

        提取关键字段:
        - transactionId:Apple 全局唯一
        - productId:用于校验请求的 product_id 匹配
        - originalPurchaseDate:用户首次购买时间(改生辰重购不变)
        - is_refunded:Apple statusField 表示退款(M2c webhook 是主信号,这里是兜底)
        """
        tx_id = getattr(payload, "transactionId", None) or requested_tx_id
        product_id = getattr(payload, "productId", "")
        if not product_id:
            raise AppleVerificationError(
                f"Apple payload 缺 productId (transaction_id={requested_tx_id})")

        original_purchase_date_ms = getattr(
            payload, "originalPurchaseDate", None)
        # Apple SDK 返回的日期可能是 int(ms) 或 datetime,统一处理
        if isinstance(original_purchase_date_ms, datetime):
            opd = original_purchase_date_ms
        elif isinstance(original_purchase_date_ms, int):
            opd = _parse_apple_date(original_purchase_date_ms)
        else:
            opd = datetime(1970, 1, 1, tzinfo=timezone.utc)

        # is_refunded 判断:
        # getTransactionInfo 不直接返回 refund 标志(REFUND 通过 webhook 推)
        # 但 statusField 可以判断 revocation;具体逻辑 M2c 落地
        is_refunded = False  # 默认 False,真实退款通过 webhook deactivate
        revocation_date = getattr(payload, "revocationDate", None)
        if revocation_date is not None:
            is_refunded = True  # 已被 revoke

        return AppleTransactionInfo(
            transaction_id=str(tx_id),
            product_id=str(product_id),
            original_purchase_date=opd,
            is_refunded=is_refunded,
            environment=environment,
        )


def _normalize_environment_claim(
    claim: object, *, source: str,
) -> Literal["production", "sandbox"]:
    """environment claim 原始值("Production"/"Sandbox")→ 环境枚举。

    值缺失 / 非串 / 未知(Xcode / LocalTesting 等)→ 显式抛错,不猜
    默认环境(错误显式传播;SDK 对未知环境也必验签失败,猜了只会
    把失败推迟一层还丢掉可读性)。
    """
    if not isinstance(claim, str) or not claim.strip():
        raise AppleVerificationError(
            f"JWS payload {source} 缺 environment claim,"
            f"无法路由 verifier(拒绝猜测默认环境)")
    normalized = claim.strip().lower()
    if normalized == "production":
        return "production"
    if normalized == "sandbox":
        return "sandbox"
    raise AppleVerificationError(
        f"JWS payload {source} environment 值未知:{claim!r}"
        f"(期望 Production/Sandbox)")


def _peek_jws_environment(jws_body: str) -> Literal["production", "sandbox"]:
    """未验签地读 JWS payload 的 environment claim(仅用于 verifier 路由)。

    **报文格式事实(2026-11-01 修正)**:Apple Server Notification V2 的
    外层 payload(responseBodyV2DecodedPayload)**没有**顶层 environment
    字段——claim 按负载类型嵌在内层,与 SDK SignedDataVerifier.
    _verify_notification 的推导同源(字段清单亦经 Apple 官方 Node SDK
    ResponseBodyV2DecodedPayload.ts 核对):
    1. data.environment(data / summary / externalPurchaseToken 三者互斥)
    2. summary.environment
    3. externalPurchaseToken.externalPurchaseId 以 "SANDBOX" 开头 →
       sandbox,否则 production
    此函数**不做任何信任判断**——只把 claim 翻译成环境枚举,真实性由
    后续所选 verifier 的完整 ECDSA + Apple Root CA 验签保证(verifier
    验签后还会复核 environment claim 与自身配置一致,选错必失败)。
    三处都取不到 claim / 值未知 / JWS 格式坏 → 显式 AppleVerificationError,
    不猜默认环境(错误显式传播)。
    """
    import base64
    import json as _json

    parts = jws_body.split(".")
    if len(parts) != 3:
        raise AppleVerificationError(
            f"JWS 格式非法(段数={len(parts)},期望 3),"
            f"无法读取 environment claim 路由 verifier")
    payload_b64 = parts[1]
    try:
        padded = payload_b64 + "=" * (-len(payload_b64) % 4)
        payload = _json.loads(base64.urlsafe_b64decode(padded))
    except Exception as e:
        raise AppleVerificationError(
            f"JWS payload 解码失败,无法读取 environment claim: "
            f"{type(e).__name__}: {e}"
        ) from e
    if not isinstance(payload, dict):
        raise AppleVerificationError(
            f"JWS payload 非对象({type(payload).__name__}),"
            f"无法读取 environment claim 路由 verifier")

    # data / summary / externalPurchaseToken 互斥,按 SDK 同款顺序推导;
    # 键在场但非对象 = 报文畸形,报"非对象"而非笼统的"缺负载"(诊断准确)
    data = payload.get("data")
    if "data" in payload:
        if not isinstance(data, dict):
            raise AppleVerificationError(
                f"JWS payload data 非对象({type(data).__name__}),"
                f"无法读取 environment claim 路由 verifier")
        return _normalize_environment_claim(
            data.get("environment"), source="data")
    summary = payload.get("summary")
    if "summary" in payload:
        if not isinstance(summary, dict):
            raise AppleVerificationError(
                f"JWS payload summary 非对象({type(summary).__name__}),"
                f"无法读取 environment claim 路由 verifier")
        return _normalize_environment_claim(
            summary.get("environment"), source="summary")
    ept = payload.get("externalPurchaseToken")
    if "externalPurchaseToken" in payload:
        if not isinstance(ept, dict):
            raise AppleVerificationError(
                f"JWS payload externalPurchaseToken 非对象"
                f"({type(ept).__name__}),"
                f"无法读取 environment claim 路由 verifier")
        external_purchase_id = ept.get("externalPurchaseId")
        if not isinstance(external_purchase_id, str) or not external_purchase_id:
            raise AppleVerificationError(
                "JWS payload externalPurchaseToken 缺 externalPurchaseId,"
                "无法路由 verifier(拒绝猜测默认环境)")
        return (
            "sandbox" if external_purchase_id.startswith("SANDBOX")
            else "production"
        )
    raise AppleVerificationError(
        "JWS payload 缺 data / summary / externalPurchaseToken 负载,"
        "无法定位 environment claim 路由 verifier(拒绝猜测默认环境)")


def _load_apple_root_certs(certs_dir: Path | None = None) -> list[bytes]:
    """加载 Apple Root CA 证书列表(DER .cer,全量读入返回)。

    证书来源:https://www.apple.com/certificateauthority/
    (App Store Server API JWS 与 Server Notifications V2 验签链的根证书,
    当前为 Apple Root CA - G3)。放置路径:backend/app/entitlement/certs/*.cer。

    失败语义(2026-08-23 重写,fail-fast):
    - 目录缺失 / 无 .cer / 文件无法按 DER X.509 解析 → RuntimeError。
    - 不再返回空 list:SDK _ChainVerifier 对空 root 列表**必抛**
      VerificationException(已对照 app-store-server-library 1.x 源码
      _verify_chain_without_caching 确认,fail-closed 而非跳过校验)——
      老实现"空 list 只做签名格式校验"是对库行为的误记。env 配齐后走
      真支付路径,证书缺失属部署错误,应启动即失败而非运行期全部 502。

    certs_dir 参数仅供测试注入;生产恒用包内 _CERTS_DIR。
    """
    directory = certs_dir if certs_dir is not None else _CERTS_DIR
    if not directory.is_dir():
        raise RuntimeError(
            f"Apple Root CA 目录缺失:{directory}。"
            f"请从 https://www.apple.com/certificateauthority/ 下载"
            f" Apple Root CA - G3(.cer)放入该目录(env 配齐时必须)")
    files = sorted(directory.glob("*.cer"))
    if not files:
        raise RuntimeError(
            f"Apple Root CA 目录为空(无 .cer 文件):{directory}。"
            f"请从 https://www.apple.com/certificateauthority/ 下载"
            f" Apple Root CA - G3(.cer)放入该目录(env 配齐时必须)")

    # DER 解析校验(cryptography 为 app-store-server-library 的传递依赖,
    # 本模块仅在此处直接使用;lazy import 对齐文件既有风格)
    try:
        from cryptography import x509 as _x509
    except ImportError as e:
        raise RuntimeError(
            f"cryptography 不可用,无法校验 Apple Root CA:"
            f"pip install app-store-server-library 会一并安装({e})"
        ) from e

    certs: list[bytes] = []
    for cert_file in files:
        data = cert_file.read_bytes()
        try:
            _x509.load_der_x509_certificate(data)
        except Exception as e:
            raise RuntimeError(
                f"Apple Root CA 文件无法解析(DER X.509):"
                f"{cert_file.name}({type(e).__name__}: {e})。"
                f"请重新从 apple.com/certificateauthority 下载"
            ) from e
        certs.append(data)
    logger.info(
        "apple_client.root_certs_loaded count=%d dir=%s",
        len(certs), directory,
    )
    return certs
