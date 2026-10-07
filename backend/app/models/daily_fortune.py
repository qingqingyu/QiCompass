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

from .bazi import CalcRuleSnapshot, LuckPillar


# ---------- chart_payload（客户端 → 后端，可信源）----------

class PillarRef(BaseModel):
    """单柱引用（chart_payload.four_pillars 用，仅含排盘命中冲所需字段）。"""

    gan: str = Field(..., description="天干，如「甲」")
    zhi: str = Field(..., description="地支，如「子」")


class ChartPayload(BaseModel):
    """客户端从存档 ChartSnapshot.payload 解出的核心字段。

    后端**不**重新跑 BaziEngine.calculate，**不**反推 birth，**不**做完整性校验，
    只信任客户端传来的日主/喜忌/四柱。chart_hash 不参与完整性断言。

    兼容字段（合盘用，daily_fortune 不填不影响）:
    - luck_pillars: 合盘算「{大运} {流年}」必需
    - calc_rule_snapshot: 合盘 response 需要回显规则快照
    """

    day_master: str = Field(..., description="日主天干，如「甲」")
    day_master_element: str = Field(..., description="日主五行英文 key（wood/fire/earth/metal/water）")
    # unknown_hour(S09):时辰未知盘(S01 引擎输出,喜忌留空)。日柱歧义盘按
    # 决策 D5 在客户端全拦,不会调本接口
    day_master_strength: Literal[
        "weak", "balanced", "strong", "special_pattern", "unknown_hour"]
    favorable_elements: list[str] = Field(default_factory=list)
    unfavorable_elements: list[str] = Field(default_factory=list)
    four_pillars: dict[str, PillarRef] = Field(
        ..., description="{year,month,day,hour} 四柱，每柱含 gan/zhi。用于 chong_targets 命中检测。"
        "时辰未知盘（day_master_strength=unknown_hour）缺 hour 键（引擎对缺失位置跳过冲合检测）")

    # 合盘扩展字段（daily_fortune 不填; compatibility 必填）
    luck_pillars: list[LuckPillar] = Field(
        default_factory=list,
        description="合盘用:daily_fortune 不填; compatibility 用于定位未来年份的大运")
    calc_rule_snapshot: CalcRuleSnapshot | None = Field(
        None,
        description="合盘用:daily_fortune 不填; compatibility response 回显所需")


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


# ---------- 今日信号（2026-09-30 BP 评审 S6，确定性规则，0 AI 成本）----------

class DayElements(BaseModel):
    """流日天干/地支五行（中文五行字，与 chart_payload.favorable_elements 同语）。

    iOS 经 BaziTerms/ElementColors 映射显示与取色，客户端不做历法计算。
    """

    stem_element: str = Field(..., description="流日天干五行，如「火」")
    branch_element: str = Field(..., description="流日地支五行，如「木」")


class DaySignalItem(BaseModel):
    """单条今日信号：流日带来的五行对喜忌的命中方向。

    direction="up"（流日带来喜用五行）/ "down"（流日带来忌神五行）。
    同一五行天干地支都命中时去重为一条；喜忌为空（时辰未知/从格）→ 整表为空，
    iOS 只显示流日五行、不标 ↑↓。
    """

    element: str = Field(..., description="五行，如「火」")
    direction: Literal["up", "down"]


class DailyFortuneRequest(BaseModel):
    """POST /api/bazi/daily-fortune 请求。"""

    chart_hash: str = Field(..., description="缓存键 + 日志关联，**不**做完整性断言")
    target_date: date = Field(..., description="业务日期（iOS 按 zi_hour_rule 算好）")
    chart_payload: ChartPayload
    # 2026-10-07 P0 收口:chart_payload 客户端自持不可复算——携带排盘端点签发的
    # payload 族 per-chart token,端点对账后才签发当日 daily token。
    # schema 层可None(生图端点复用本模型且不需要 token,有独立成本护栏);
    # /api/bazi/daily-fortune 端点显式强制,缺失 → 403 CONTEXT_TOKEN_REQUIRED。
    context_token: str | None = Field(
        None, max_length=32768,
        description="该盘排盘响应的 context_tokens.payload(per-chart 对账用;"
                    "daily-fortune 端点必填,image 端点忽略)")


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
    day_elements: DayElements = Field(
        ..., description="流日天干/地支五行（S6 今日信号的数据底座）")
    day_signal: list[DaySignalItem] = Field(
        default_factory=list,
        description="流日五行对喜忌的命中（↑喜/↓忌）；喜忌为空（时辰未知/从格）为空表")
    lunar_date: str = Field(..., description="形如「六月初六」")
    huangli_yi: list[str] = Field(default_factory=list, description="黄历宜")
    huangli_ji: list[str] = Field(default_factory=list, description="黄历忌")
    tomorrow_preview: TomorrowPreview
    calc_rule_snapshot: dict[str, Any] = Field(..., description="规则快照，含 library/sect 等")
    # 2026-10-07 P0 收口:daily context 核心字段绑定 token(interpret 验签;
    # claims 含 target_date,同盘不同日不可互用)
    context_token: str | None = Field(
        None, description="daily 族 context_token(当日签发,客户端随 interpret 请求回传)")
