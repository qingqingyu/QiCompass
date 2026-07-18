"""POST /api/entitlement/redeem Pydantic v2 schema(M2b)。

iOS StoreKit2 完成购买 → 拿到 transactionId → 调此接口写后端 entitlement 表。
后端调 Apple 验证 + 写表 + 返回 entitled=true。

契约对齐 MONETIZATION.md §购买+校验流程 / §商品 SKU 列表。
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, field_serializer, field_validator


# Apple 商品 SKU(对齐 MONETIZATION.md §商品 SKU 列表)
# 客户端用这个跟 iOS StoreKit2 Product.products() 拿到的 product.id 对齐
ProductId = Literal[
    "com.qicompass.deep_analysis.single",  # 深度解析单次解锁
    "com.qicompass.compatibility.single",  # 合盘单次解锁(M4 启用)
]

# Entitlement 表的 module 字段(基础名,不含 _free/_paid 后缀)
EntitlementModule = Literal[
    "bazi_deep",
    "compatibility",
]


class EntitlementRedeemRequest(BaseModel):
    """POST /api/entitlement/redeem 请求。

    iOS StoreKit2 完成购买后立即调用,把 transactionId 同步到后端。
    后端调 Apple 验证 → 写表 → 返回 entitled=true。
    """

    transaction_id: str = Field(
        ..., description="Apple JWS transactionId(全局唯一 PK)",
        min_length=1)
    product_id: ProductId = Field(
        ..., description="Apple product_id,必须匹配后端 SKU 注册")
    content_hash: str = Field(
        ..., description="命盘 hash(深度解析)或 compatibility_hash(合盘)")
    module: EntitlementModule = Field(
        ..., description="基础 module 名(bazi_deep / compatibility),不含 _free/_paid")
    user_local_id: str = Field(
        ..., description="客户端生成的 UUID(v1 无账号系统的占位)",
        min_length=1)

    @field_validator("transaction_id", "content_hash", "user_local_id")
    @classmethod
    def _strip_and_nonblank(cls, v: str) -> str:
        """strip + 非空校验(避免 "   " 通过)。"""
        normalized = v.strip()
        if not normalized:
            raise ValueError("字段不能为空或纯空白")
        return normalized


class EntitlementRedeemResponse(BaseModel):
    """POST /api/entitlement/redeem 响应。

    失败时不返回此 schema(直接 raise → 错误响应);
    成功时 entitled 永远为 True(类型层面用 Literal[True] 强制)。
    """

    entitled: Literal[True] = Field(
        ..., description="成功标志(永远 True;失败走错误响应)")
    transaction_id: str = Field(
        ..., description="Apple JWS transactionId(回显)")
    purchased_at: datetime = Field(
        ..., description="ISO 8601 UTC,后端写表的时间")
    original_purchase_date: datetime = Field(
        ..., description="ISO 8601 UTC,Apple 返回的原始购买时间")

    @field_serializer("purchased_at")
    def _serialize_purchased_at(self, dt: datetime) -> str:
        """去微秒(对齐 InterpretResponse 的 generated_at 序列化风格)。"""
        return dt.replace(microsecond=0).isoformat()

    @field_serializer("original_purchase_date")
    def _serialize_original_purchase_date(self, dt: datetime) -> str:
        return dt.replace(microsecond=0).isoformat()
