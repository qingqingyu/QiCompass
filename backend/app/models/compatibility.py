"""POST /api/bazi/compatibility Pydantic v2 schema。

契约对齐最终方案 §2.1（双模式 A/B）:
- 模式 A（B 已存档）: 客户端传 person_b_hash + chart_payload_b, 后端零排盘
- 模式 B（B 临时输入）: 客户端传 person_b{...}, 后端现排 B
- person_b / person_b_hash 互斥且至少一个（不静默，422）
- 模式 A 下 chart_payload_b 必填（不静默，422）
- chart_payload_a 始终必填（与 daily-fortune §1.A 一致：客户端可信源、服务端无状态）

context 只参与 hash + AI prompt 维度，**不**参与定性评估计算（不变量，
见 test_compatibility.py 的 context 隔离用例）。
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, Field, field_validator, model_validator

from .bazi import BaziCalculateResponse, CalcRuleSnapshot
from .daily_fortune import ChartPayload


Context = Literal["general", "marriage", "business"]


# ---------- Request ----------

class PersonBInput(BaseModel):
    """模式 B（B 临时输入）：字段子集复用 BaziCalculateRequest。

    后端按 birth_datetime + gender + (city|longitude) + zi_hour_rule 现排 B。
    """

    birth_datetime: datetime = Field(
        ..., description="ISO 8601, 必须含时区, 例 1990-03-15T14:30:00+08:00")
    gender: Literal["male", "female"]
    city: str | None = Field(None, description="城市名, 与 longitude 至少传一个")
    longitude: float | None = Field(
        None, description="经度（东正西负）, 优先级高于 city")
    zi_hour_rule: Literal["zi_next_day"] = Field(
        "zi_next_day", description="MVP 固定 zi_next_day, 内部 setSect(1)")

    @field_validator("birth_datetime")
    @classmethod
    def must_be_timezone_aware(cls, v: datetime) -> datetime:
        if v.tzinfo is None or v.utcoffset() is None:
            raise ValueError("birth_datetime 必须含时区(offset-aware)")
        return v

    @field_validator("longitude")
    @classmethod
    def longitude_range(cls, v: float | None) -> float | None:
        if v is not None and not (-180.0 <= v <= 180.0):
            raise ValueError("longitude 必须在 [-180, 180] 区间")
        return v

    @model_validator(mode="after")
    def city_or_longitude_required(self) -> "PersonBInput":
        if self.city is None and self.longitude is None:
            raise ValueError("city 和 longitude 至少传一个")
        return self


class CompatibilityRequest(BaseModel):
    """POST /api/bazi/compatibility 请求。"""

    person_a_hash: str = Field(..., description="A 盘 content_hash, 引用已存档 ChartSnapshot")
    person_b_hash: str | None = Field(
        None, description="模式 A: B 盘 content_hash, 引用已存档 ChartSnapshot")
    person_b: PersonBInput | None = Field(
        None, description="模式 B: B 临时输入字段（与 person_b_hash 互斥）")
    chart_payload_a: ChartPayload = Field(
        ..., description="A 盘瘦身 payload, 含日主/喜忌/四柱")
    chart_payload_b: ChartPayload | None = Field(
        None, description="模式 A 必填; 模式 B 由后端现排后内部生成")
    context: Context = Field("general", description="合盘语境, 仅参与 hash + AI prompt")

    @model_validator(mode="after")
    def person_b_mode_exclusive(self) -> "CompatibilityRequest":
        """person_b 与 person_b_hash 互斥且至少一个（不静默吞）。"""
        has_b_obj = self.person_b is not None
        has_b_hash = self.person_b_hash is not None
        if has_b_obj and has_b_hash:
            raise ValueError(
                "person_b 与 person_b_hash 互斥, 不得同时传"
                "(模式 A 传 hash, 模式 B 传 object)")
        if not has_b_obj and not has_b_hash:
            raise ValueError(
                "person_b 与 person_b_hash 至少传一个"
                "(模式 A 传 hash, 模式 B 传 object)")
        return self

    @model_validator(mode="after")
    def chart_payload_b_consistency(self) -> "CompatibilityRequest":
        """模式 A (person_b_hash 给定) 下 chart_payload_b 必填（不静默）。"""
        if self.person_b_hash is not None and self.chart_payload_b is None:
            raise ValueError(
                "模式 A (person_b_hash) 下 chart_payload_b 必填")
        return self


# ---------- Response ----------

class QualitativeAssessment(BaseModel):
    """四项定性评估（确定性，不走 LLM）。禁止任何数字分。

    字段值均为中文短语, 取值集见最终方案 §1.2:
    - five_elements: 互补佳 / 有一定互补 / 互补较弱 / 信息不足
    - day_master_relation: 同气 / 相生 / 相克 / 生扶偏单向
    - zodiac_match: 六合 / 三合 / 六冲 / 三刑 / 相害 / 无特殊合冲
    - branch_harmony: 无冲无刑 / 一冲一合 / 多冲少合 / 多合少冲 / 多刑多害
    """

    five_elements: str
    day_master_relation: str
    zodiac_match: str
    branch_harmony: str


class SyncedFortune(BaseModel):
    """单条流年同步（共 3 条, 当前年 +1/+2/+3）。"""

    year: int
    person_a: str = Field(..., description="形如「乙亥运 丙午年」")
    person_b: str = Field(..., description="形如「丁丑运 丙午年」")
    sync: str = Field(
        ..., description="同步走强 / 同步承压 / 运势分化 / 节奏错位 / 难以定性")


class CompatibilityResponse(BaseModel):
    """POST /api/bazi/compatibility 响应。

    person_a_chart 始终为 None（A 永远从本地存档渲染, 后端不重排）。
    person_b_chart 在模式 A 下为 None（B 也从本地存档渲染）, 模式 B 下为后端现排结果。
    客户端应使用本地 ChartSnapshot 渲染 A/B 双盘的纳音/藏干/十神等丰富字段。
    """

    compatibility_hash: str
    person_a_chart: BaziCalculateResponse | None = Field(
        None, description="始终 None。A 从本地 ChartSnapshot 渲染")
    person_b_chart: BaziCalculateResponse | None = Field(
        None, description="模式 A None; 模式 B 为后端现排的 B 盘完整响应")
    qualitative_assessment: QualitativeAssessment
    synced_fortune: list[SyncedFortune] = Field(..., description="3 条")
    calc_rule_snapshot: CalcRuleSnapshot
