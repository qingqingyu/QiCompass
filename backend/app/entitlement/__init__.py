"""Entitlement 模块(M2 后端付费系统)。

对外暴露:
- EntitlementStore:entitlement 表 CRUD + active 查询(对齐 ai/cache.py 模式)
- AppleServerAPI:Protocol,屏蔽 Apple SDK 实现细节
- MockAppleServerAPI:测试 / dev 用,不真调 Apple
- AppleTransactionInfo / AppleNotificationPayload:dataclass 数据载体
"""

from __future__ import annotations

from .protocol import (
    AppleNotificationPayload,
    AppleServerAPI,
    AppleTransactionInfo,
    MockAppleServerAPI,
)
from .store import EntitlementStore

__all__ = [
    "AppleNotificationPayload",
    "AppleServerAPI",
    "AppleTransactionInfo",
    "EntitlementStore",
    "MockAppleServerAPI",
]
