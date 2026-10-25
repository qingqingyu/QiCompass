"""问事(今日页问事窗)请求/响应模型——S4b-3,2026-10-25。

口径:MONETIZATION.md §问事窗。每条用户消息扣 1 次;重复问(同 owner 同盘
同日同题)走重复语境重生成;answer/follow_up_suggestions 输出契约。
"""

from __future__ import annotations

from datetime import date
from typing import Any, Literal

from pydantic import BaseModel, Field


class DailyAskTurn(BaseModel):
    """对话上文一轮(role 限 user/ai;文本上限与 _FIELD_CHAR_LIMITS 分档)。"""

    role: Literal["user", "ai"]
    text: str = Field(..., min_length=1, max_length=2000)


class DailyAskRequest(BaseModel):
    """POST /api/bazi/daily-ask 请求。"""

    content_hash: str = Field(
        ..., max_length=128,
        description="命盘 hash(daily 族 context_token 对账维度)")
    context: dict[str, Any] = Field(
        ..., description="盘面上下文(daily_fortune 同契约,核心字段须与 token 一致;"
                         "ask 专属 4 字段由此端点注入,客户端不传)")
    context_token: str | None = Field(
        None, max_length=32768,
        description="daily 族 context_token(今日运势响应签发;缺/伪 → 403 "
                    "CONTEXT_TOKEN_*——与 /api/interpret 同契约,模型层可空、"
                    "端点验签统一拦,不落 422)")
    target_date: date = Field(..., description="问事日(须与 token 的 target_date 一致)")
    user_local_id: str | None = Field(
        None, max_length=128,
        description="钱包 owner(匿名必填;登录请求以 user_id 优先)")
    question: str = Field(
        ..., min_length=1, max_length=200,
        description="本轮提问(每条用户消息扣 1 次)")
    history: list[DailyAskTurn] = Field(
        default_factory=list,
        description="对话上文(最近几轮;端点只取末 6 轮注入,超过 20 轮 422——"
                    "客户端负责截断)")
    daily_interpretation: str = Field(
        ..., min_length=1, max_length=4096,
        description="今日解读正文(客户端回传它在今日页已渲染的五段文本;"
                    "作答须与它一致——回传自己的解读无伪造成收益,盘身由 token 锚)")
    device_token: str | None = Field(
        None, max_length=4096,
        description="Apple DeviceCheck token(iOS DCDevice.generateToken;首次"
                    "铸造试用时带,缺省走纯 IP 限铸闸降级)")


class DailyAskResponse(BaseModel):
    """POST /api/bazi/daily-ask 响应。"""

    answer: str
    follow_up_suggestions: list[str]
    cached: bool = Field(
        ..., description="True = 命中共享缓存(未调 LLM、未扣次数)")
    balance: int = Field(
        ..., description="本次之后的剩余次数(试用+钱包合计;iOS 展示用)")


class AskBalanceResponse(BaseModel):
    """GET /api/ask/balance 响应。"""

    balance: int = Field(
        ..., description="剩余次数(首次查询自动铸造 3 次试用,装机即领)")


class AskRedeemRequest(BaseModel):
    """POST /api/ask/redeem 请求(次数包;iOS StoreKit 2 完成购买后调)。"""

    transaction_id: str = Field(..., max_length=128)
    product_id: str = Field(..., max_length=128,
                            description="须为次数包 SKU(ASK_PACK_PRODUCT_ID)")
    user_local_id: str | None = Field(
        None, max_length=128,
        description="匿名购买的钱包 owner;登录请求以 user_id 优先")


class AskRedeemResponse(BaseModel):
    """POST /api/ask/redeem 响应。"""

    credits: int = Field(..., description="本单入账次数")
    balance: int = Field(..., description="入账后剩余次数")
    transaction_id: str
    purchased_at: str
