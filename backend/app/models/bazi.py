"""八字排盘 Pydantic v2 schema。

字段对齐 bazi-app-design-doc.md:96-156。
喜忌/神煞由确定性规则引擎填充(决策 1 扶抑+调候+从格检测 / 决策 2 《三命通会》20 神煞)。
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, field_serializer, field_validator, model_validator


# ---------- Request ----------

class BaziCalculateRequest(BaseModel):
    """POST /api/bazi/calculate 请求。"""

    birth_datetime: datetime = Field(
        ..., description="ISO 8601,必须含时区,例 1990-03-15T14:30:00+08:00")
    gender: Literal["male", "female"]
    city: str | None = Field(None, description="城市名,与 longitude 至少传一个")
    longitude: float | None = Field(
        None, description="经度(东正西负),优先级高于 city")
    zi_hour_rule: Literal["zi_next_day"] = Field(
        "zi_next_day", description="MVP 固定 zi_next_day,内部 setSect(1)")

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
    def city_or_longitude_required(self) -> "BaziCalculateRequest":
        if self.city is None and self.longitude is None:
            raise ValueError("city 和 longitude 至少传一个")
        return self


# ---------- Pillar ----------

class Pillar(BaseModel):
    """单柱结构(年/月/日/时通用)。"""

    gan_zhi: str
    gan: str
    zhi: str
    gan_element: str  # metal/wood/water/fire/earth
    zhi_element: str
    hide_gan: list[str]
    shishen_gan: str
    shishen_zhi: list[str]
    nayin: str
    dishi: str  # 十二长生(临官/帝旺/...)
    xunkong: str  # 旬空(地支字)


class Pillars(BaseModel):
    year: Pillar
    month: Pillar
    day: Pillar
    hour: Pillar


class GanZhiNaYin(BaseModel):
    """干支 + 纳音(命宫/身宫/胎元用)。"""

    gan_zhi: str
    nayin: str


class ElementBalance(BaseModel):
    wood: int = 0
    fire: int = 0
    earth: int = 0
    metal: int = 0
    water: int = 0


class LuckPillar(BaseModel):
    gan_zhi: str
    start_year: int
    end_year: int
    start_age: int
    end_age: int


class CurrentPillar(BaseModel):
    """current_luck_pillar 用(含起止年)。"""

    gan_zhi: str
    start_year: int
    end_year: int


class CalcRuleSnapshot(BaseModel):
    library: str
    sect: int
    zi_hour_rule: str
    true_solar_longitude: float
    true_solar_offset_minutes: float
    schema_version: int


# ---------- 神煞 ----------

class ShenshaItem(BaseModel):
    """单条神煞命中(决策 2 《三命通会》单一来源)。"""

    name: str
    position: Literal["年柱", "月柱", "日柱", "时柱"]
    source: str = "三命通会"


# ---------- Response ----------

class BaziCalculateResponse(BaseModel):
    """POST /api/bazi/calculate 响应。"""

    content_hash: str
    true_solar_time: datetime
    true_solar_offset_minutes: float

    @field_serializer("true_solar_time")
    def _serialize_true_solar_time(self, dt: datetime) -> str:
        """去微秒:iOS .iso8601 dateDecodingStrategy 不支持小数秒。"""
        return dt.replace(microsecond=0).isoformat()
    pillars: Pillars
    ming_gong: GanZhiNaYin
    shen_gong: GanZhiNaYin
    tai_yuan: GanZhiNaYin
    element_balance: ElementBalance

    # 决策 1 喜忌 —— 扶抑+调候+从格检测(D3)
    favorable_elements: list[str] = Field(default_factory=list)
    unfavorable_elements: list[str] = Field(default_factory=list)
    day_master_strength: Literal["strong", "weak", "balanced", "special_pattern"] | None = None
    tiaoshou_applied: bool = False
    xiji_method: str | None = None  # "扶抑+调候" | "扶抑+调候(从格特征检测命中,未判定具体格局)"
    pattern_hint: Literal["zhuanwang", "cong"] | None = None

    # 决策 2 神煞 —— 《三命通会》20 个固定清单
    shensha: list[ShenshaItem] = Field(default_factory=list)

    luck_pillars: list[LuckPillar]
    current_luck_pillar: CurrentPillar | None = None
    current_year_pillar: str | None = None
    current_day_pillar: str | None = None
    current_hour_pillar: str | None = None

    calc_rule_snapshot: CalcRuleSnapshot
    boundary_warning: str | None = None


# ---------- Error ----------

class ErrorBody(BaseModel):
    code: str
    message: str
    request_id: str | None = None
    content_hash: str | None = None


class ErrorResponse(BaseModel):
    error: ErrorBody
