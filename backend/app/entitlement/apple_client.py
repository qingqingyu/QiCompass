"""Apple App Store Server API 真实 SDK 包装(M2b)。

依赖 `app-store-server-library`(苹果官方 Python SDK),封装:
- AppStoreServerAPIClient:调 Apple getTransactionInfo API(JWT 签名)
- SignedDataVerifier:验签 JWS 响应(ECDSA P-256 + Apple Root CA)

设计要点:
- **lazy import**:SDK 在 __init__ 内 import,缺失时抛 RuntimeError(不污染模块顶部)
  → main.py lifespan 捕获后 fallback MockAppleServerAPI,不阻塞启动
- **翻译层**:SDK 类型 JWSTransactionDecodedPayload 翻译成 AppleTransactionInfo
  dataclass,屏蔽 SDK 类型污染到路由层 / store
- **错误统一**:所有失败模式(网络/签名/transaction 不存在/SDK 5xx)统一抛
  AppleVerificationError(502),Apple 明确返回 status=退款时抛 EntitlementError

线程池策略:SDK 全同步,路由层用 run_in_threadpool 调用。

不引入新依赖:仅依赖 app-store-server-library(用户 2026-07-18 同意)。
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

from ..errors import AppleVerificationError, EntitlementError
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

    构造时实际 import SDK + 实例化 AppStoreServerAPIClient + SignedDataVerifier。
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
        environment: Literal["sandbox", "production"],
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
        self._environment = environment

        try:
            env_enum = (
                Environment.PRODUCTION if environment == "production"
                else Environment.SANDBOX
            )

            self._client = AppStoreServerAPIClient(
                signing_key=private_key,
                key_id=key_id,
                bundle_id=bundle_id,
                issuer_id=issuer_id,
                environment=env_enum,
            )

            # Apple Root CA(SDK 内置或从 Apple 官方下载)
            # SDK 推荐用 RootCertificationsProvide 内置的 prod + test CA
            # 这里用库提供的常量;实际实施时若 SDK API 有差异,按库版本调整
            self._verifier = SignedDataVerifier(
                root_certificates=_load_apple_root_certs(),
                bundle_id=bundle_id,
                app_apple_id=int(app_apple_id),
                environment=env_enum,
                enable_online_checks=False,
            )
        except Exception as e:
            # SDK 内部错误(参数格式不对 / 私钥无效等)
            raise RuntimeError(
                f"AppleServerAPIClient 初始化失败: {type(e).__name__}: {e}"
            ) from e

        logger.info(
            "apple_client.init_ok bundle_id=%s environment=%s",
            bundle_id, environment,
        )

    def verify_transaction(self, transaction_id: str) -> AppleTransactionInfo:
        """调 Apple getTransactionInfo + 验签 → 标准化 dataclass。

        Raises:
            AppleVerificationError(502):网络 / 签名无效 / transaction 不存在
            EntitlementError(403):Apple 明确返回已退款 status
        """
        try:
            # Step 1: 调 Apple API 拿 JWS
            response = self._client.get_transaction_info(transaction_id)
            signed_tx_info = response.signedTransactionInfo
            if not signed_tx_info:
                raise AppleVerificationError(
                    f"Apple 返回空 signedTransactionInfo (transaction_id={transaction_id})"
                )

            # Step 2: 验签 JWS
            payload = self._verifier.verify_and_decode_signed_transaction(
                signed_tx_info)

            # Step 3: 翻译成 dataclass
            return self._translate_payload(payload, transaction_id)

        except (AppleVerificationError, EntitlementError):
            raise
        except Exception as e:
            # 统一包装:网络 / 签名 / SDK 内部错误
            raise AppleVerificationError(
                f"Apple verify_transaction 失败 (transaction_id={transaction_id}): "
                f"{type(e).__name__}: {e}"
            ) from e

    def verify_notification(self, jws_body: str) -> AppleNotificationPayload:
        """验签 Apple Server Notification V2 JWS payload。

        Raises:
            AppleVerificationError(502):签名无效 / 解析失败
        """
        try:
            notification = (
                self._verifier.verify_and_decode_signed_notification(jws_body)
            )

            # notificationType 是 enum,取 .name 或 .value
            ntype = getattr(
                notification.notificationType, "value",
                getattr(notification.notificationType, "name", str(notification.notificationType)),
            )

            # data.signedTransactionInfo 二次 decode 拿 transaction_id
            tx_id = "<unknown>"
            data = getattr(notification, "data", None)
            if data and getattr(data, "signedTransactionInfo", None):
                tx_payload = self._verifier.verify_and_decode_signed_transaction(
                    data.signedTransactionInfo)
                tx_id = getattr(tx_payload, "transactionId", "<unknown>")

            return AppleNotificationPayload(
                notification_type=str(ntype).upper(),
                transaction_id=str(tx_id),
                raw_summary=f"type={ntype}",
            )
        except Exception as e:
            raise AppleVerificationError(
                f"Apple verify_notification 失败: "
                f"{type(e).__name__}: {e}"
            ) from e

    def _translate_payload(
        self, payload: Any, requested_tx_id: str,
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
        )


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
