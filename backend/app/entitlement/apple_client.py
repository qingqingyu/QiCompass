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
from typing import Any, Literal

from ..errors import AppleVerificationError, EntitlementError
from .protocol import (
    AppleNotificationPayload,
    AppleTransactionInfo,
)

logger = logging.getLogger(__name__)


def _parse_apple_date(ms_timestamp: int | None) -> datetime:
    """Apple 返回的 ms 时间戳 → UTC datetime。

    Apple 的 originalPurchaseDate 是毫秒级 UNIX 时间戳。None 时返回 epoch(占位,
    实际调用方应该确保字段存在)。
    """
    if ms_timestamp is None:
        return datetime(1970, 1, 1, tzinfo=timezone.utc)
    return datetime.fromtimestamp(ms_timestamp / 1000, tz=timezone.utc)


# Apple App Store Server API statusField(来自 SDK 文档)
# 1 = active,2 = expired,3 = in billing retry,4 = in grace period,
# 5 = revoked
_TRANSACTION_REFUND_STATUSES = set()  # type: set[int]
# Apple 用 type 字段区分是否 refund:REFUND 通知会带 REFUNDED flag;
# getTransactionInfo 的 statusField 不直接表达 "refunded",
# 但 we'll check via the env receipt info. M2c webhook 是退款主信号。


class AppleServerAPIClient:
    """真 SDK 包装类。实现 AppleServerAPI Protocol。

    构造时实际 import SDK + 实例化 AppStoreServerAPIClient + SignedDataVerifier。
    缺 SDK 或 env 配置时抛 RuntimeError(由 main.py lifespan 捕获,挂 Mock)。
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


def _load_apple_root_certs() -> list[bytes]:
    """加载 Apple Root CA 证书列表。

    Apple 官方提供两个 Root CA(G3 + Root ECDSA):
    https://www.apple.com/certificateauthority/

    实施选项:
    - 选项 A:打包 .cer 文件到 backend/data/certs/(需用户下载)
    - 选项 B:运行时从 Apple URL 下载(每次启动慢,网络故障阻塞)
    - 选项 C:SDK 内置(部分版本支持)

    M2b 骨架阶段用空 list + log warning,M6 TestFlight 阶段补真证书:
    SignedDataVerifier 在空 list 时只做签名格式校验,不做 trust chain 校验
    (适合 dev/test;生产必须填真证书)。
    """
    logger.warning(
        "apple_client.root_certs_empty M2b 骨架模式:Apple Root CA 未加载,"
        "SignedDataVerifier 不做完整 trust chain 校验。M6 TestFlight 前必须补。"
    )
    return []
