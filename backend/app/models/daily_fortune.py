"""POST /api/bazi/daily-fortune Pydantic v2 schema。

契约对齐最终方案 §2.1（chart_payload 模式）:
- 客户端传 chart_payload（日主天干/五行/强弱/喜忌/四柱），后端不反推 birth、不持久化 ChartSnapshot
- chart_hash 仅作缓存键 + 日志关联，**不**做完整性断言
- zi_hour_rule **不**进请求：业务日期判定由 iOS 在客户端完成（决策 §3.6）
- 服务端拿到什么 target_date 就按它排，纯函数
"""

from __future__ import annotations

from datetime import date
from typing import Any, Literal

from pydantic import BaseModel, Field


# ---------- chart_payload（客户端 → 后端，可信源）----------

class PillarRef(BaseModel):
    """单柱引用（chart_payload.four_pillars 用，仅含排盘命中冲所需字段）。"""

    gan: str = Field(..., description="天干，如「甲」")
    zhi: str = Field(..., description="地支，如「子」")


class ChartPayload(BaseModel):
    """客户端从存档 ChartSnapshot.payload 解出的核心字段。

    后端**不**重新跑 BaziEngine.calculate，**不**反推 birth，**不**做完整性校验，
    只信任客户端传来的日主/喜忌/四柱。chart_hash 不参与完整性断言。
    """

    day_master: str = Field(..., description="日主天干，如「甲」")
    day_master_element: str = Field(..., description="日主五行英文 key（wood/fire/earth/metal/water）")
    day_master_strength: Literal["weak", "balanced", "strong", "special_pattern"]
    favorable_elements: list[str] = Field(default_factory=list)
    unfavorable_elements: list[str] = Field(default_factory=list)
    four_pillars: dict[str, PillarRef] = Field(
        ..., description="{year,month,day,hour} 四柱，每柱含 gan/zhi。用于 chong_targets 命中检测")


# ---------- Response ----------

class HourPillar(BaseModel):
    """单时辰条（共 12 条）。"""

    hour: str = Field(..., description="地支名，如「子」")
    time_range: str = Field(..., description="时间段，如「23:00-01:00」")
    pillar: str = Field(..., description="时柱干支，如「甲子」")
    relation: str = Field(..., description="流时天干对日主的十神关系，如「比肩」")
    chong: str | None = Field(None, description="流时冲（地支字），无冲为 null")
    chong_targets: list[str] = Field(
        default_factory=list,
        description="命盘四柱中被冲到的位置，如「年支寅」；未命中为空数组")


class TomorrowPreview(BaseModel):
    """明日预告（仅三字段，不含 12 时辰/黄历）。"""

    day_pillar: str
    day_relation: str
    day_chong: str | None


class DailyFortuneRequest(BaseModel):
    """POST /api/bazi/daily-fortune 请求。"""

    chart_hash: str = Field(..., description="缓存键 + 日志关联，**不**做完整性断言")
    target_date: date = Field(..., description="业务日期（iOS 按 zi_hour_rule 算好）")
    chart_payload: ChartPayload


class DailyFortuneResponse(BaseModel):
    """POST /api/bazi/daily-fortune 响应。"""

    day_pillar: str
    day_relation_to_day_master: str = Field(
        ..., description="流日天干对日主的十神关系")
    day_chong: str | None = Field(None, description="流日冲（地支字）")
    day_chong_targets: list[str] = Field(
        default_factory=list,
        description="命盘四柱中被冲到的位置；未命中为空数组")
    hour_pillars: list[HourPillar] = Field(..., description="12 条")
    current_hour_index: int | None = Field(
        None, description="服务端固定 null，由 iOS 本地按 Calendar 算")
    lunar_date: str = Field(..., description="形如「六月初六」")
    huangli_yi: list[str] = Field(default_factory=list, description="黄历宜")
    huangli_ji: list[str] = Field(default_factory=list, description="黄历忌")
    tomorrow_preview: TomorrowPreview
    calc_rule_snapshot: dict[str, Any] = Field(..., description="规则快照，含 library/sect 等")
