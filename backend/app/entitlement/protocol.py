"""Apple Server API Protocol + Mock + 数据载体。

设计意图:
- `AppleServerAPI` Protocol 屏蔽 SDK 实现细节(app-store-server-library),
  路由层只依赖 Protocol,不直接 import SDK 类型
- `MockAppleServerAPI` 让 M2a(无 Apple key)+ 单元测试不依赖真 Apple
- dataclass 是 SDK 类型 → 后端内部类型的翻译层,避免 SDK 类型污染到路由 / store

M2a 阶段只 import 这个文件 + store.py,M2b 才 import apple_client.py(真 SDK 包装)。
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Literal, Protocol


@dataclass(frozen=True)
class AppleTransactionInfo:
    """Apple transaction 验证后的标准化信息。

    由 AppleServerAPIClient(M2b)从 JWSTransactionDecodedPayload 翻译而来。
    路由层只依赖此 dataclass,不依赖 SDK 类型。
    """

    transaction_id: str
    product_id: str
    original_purchase_date: datetime  # UTC,Apple 返回的原始购买时间
    is_refunded: bool  # Apple statusField 表示已退款


@dataclass(frozen=True)
class AppleNotificationPayload:
    """Apple Server Notification V2 解码后的标准化信息。"""

    notification_type: str  # "REFUND" / "REVOKE" / "DID_CHANGE_RENEWAL_STATUS" / ...
    transaction_id: str
    raw_summary: str = ""  # 调试用,简短描述原始 payload(不包含敏感数据)


class AppleServerAPI(Protocol):
    """Apple App Store Server API 抽象接口。

    所有方法同步(SDK 是同步的),由路由层通过 run_in_threadpool 调用。

    所有失败模式(网络 / 签名无效 / transaction 不存在 / Apple 5xx)统一抛
    AppleVerificationError(502)。Apple 明确返回 status=退款时抛
    EntitlementError(用户已无权)。
    """

    def verify_transaction(self, transaction_id: str) -> AppleTransactionInfo:
        """调 getTransactionInfo + 验签,返回标准化 dataclass。"""
        ...

    def verify_notification(self, jws_body: str) -> AppleNotificationPayload:
        """验签 Server Notification V2 JWS payload,返回标准化 dataclass。"""
        ...


class MockAppleServerAPI:
    """测试 / dev 用的 Mock 实现(M2a 默认挂这个,不真调 Apple)。

    使用方式:
    - 默认:verify_transaction 返回固定 info(product_id 从输入取)
    - verify_fails=True:抛 AppleVerificationError(测试错误路径)
    - tx_info 自定义:精确控制返回的 dataclass

    M2a 阶段:后端启动时若无 Apple key,挂 MockAppleServerAPI(),
    iOS dev 可以用任何 transaction_id 走通 redeem 流程(只为打通链路,
    生产前必须切真 SDK)。
    """

    def __init__(
        self,
        *,
        verify_fails: bool = False,
        tx_info: AppleTransactionInfo | None = None,
        notification: AppleNotificationPayload | None = None,
    ):
        self._verify_fails = verify_fails
        self._default_tx_info = tx_info or AppleTransactionInfo(
            transaction_id="<mock>",
            product_id="com.qicompass.deep_analysis.single",
            original_purchase_date=datetime(2026, 1, 1),
            is_refunded=False,
        )
        self._default_notification = notification or AppleNotificationPayload(
            notification_type="REFUND",
            transaction_id="<mock>",
            raw_summary="mock-notification",
        )
        # 调用计数 + 历史(测试用)
        self.verify_transaction_calls: list[str] = []
        self.verify_notification_calls: list[str] = []

    def verify_transaction(self, transaction_id: str) -> AppleTransactionInfo:
        self.verify_transaction_calls.append(transaction_id)
        if self._verify_fails:
            # 延迟 import 避免循环依赖
            from ..errors import AppleVerificationError
            raise AppleVerificationError(
                f"MockAppleServerAPI verify_fails=True 模拟 Apple 验证失败 "
                f"(transaction_id={transaction_id})")
        # 返回带请求 transaction_id 的 info(让调用方能断言)
        return AppleTransactionInfo(
            transaction_id=transaction_id,
            product_id=self._default_tx_info.product_id,
            original_purchase_date=self._default_tx_info.original_purchase_date,
            is_refunded=self._default_tx_info.is_refunded,
        )

    def verify_notification(self, jws_body: str) -> AppleNotificationPayload:
        self.verify_notification_calls.append(jws_body)
        if self._verify_fails:
            from ..errors import AppleVerificationError
            raise AppleVerificationError(
                "MockAppleServerAPI verify_fails=True 模拟 Apple 验证失败 (notification)")
        return self._default_notification
