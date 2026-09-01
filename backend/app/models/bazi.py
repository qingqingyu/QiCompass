"""八字排盘 Pydantic v2 schema。

字段对齐 bazi-app-design-doc.md:96-156。
喜忌/神煞由确定性规则引擎填充(决策 1 扶抑+调候+从格检测 / 决策 2 《三命通会》20 神煞)。
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_serializer, field_validator

from ..core.tz_resolution import validate_timezone


# ---------- Request ----------

class BaziCalculateRequest(BaseModel):
    """POST /api/bazi/calculate 请求(S02 契约:裸钟面 + IANA 时区 + 物理真值)。

    契约变更(docs/城市搜索设计决策.md Q4/Q5):
    - 删 city 字段(后端不再持有城市表,客户端发物理真值)
    - birth_datetime 改**裸钟面时间(naive)**,按 timezone 解释(后端 zoneinfo,
      历史夏令时规则自动套用);歧义/跳过小时降级 boundary_warning
    - longitude 必填;latitude/place_name/geoname_id 存档与日志用,不参与 hash
    """

    # S02 零兼容垫片:未知字段(含旧 city)直接 422,不静默丢弃
    model_config = ConfigDict(extra="forbid")

    birth_datetime: datetime = Field(
        ..., description="出生钟面时间(ISO 8601,naive 无 offset),"
                         "例 1988-05-05T02:30:00;时区由 timezone 字段解释")
    timezone: str = Field(
        ..., description="出生地 IANA 时区名,例 Asia/Shanghai;"
                         "1986-91 中国夏令时等历史规则由后端 zoneinfo 套用")
    gender: Literal["male", "female"]
    longitude: float = Field(
        ..., description="出生地经度(东正西负),客户端来自城市库或自定义输入")
    latitude: float | None = Field(
        None, description="存档用(下游真太阳时不用纬度)")
    place_name: str | None = Field(
        None, description="展示用城市名(如 北京 / San Francisco),不参与 content_hash")
    geoname_id: int | None = Field(
        None, description="GeoNames 城市 ID,仅日志/诊断,非 load-bearing")
    zi_hour_rule: Literal["zi_next_day"] = Field(
        "zi_next_day", description="MVP 固定 zi_next_day,内部 setSect(1)")

    # ---- 时辰未知契约(docs/时辰未知设计决策.md,2026-08-31)----
    # hour_known 是唯一事实源(不用 00:00:00 哨兵伪装);默认 True 保老客户端不 422
    hour_known: bool = Field(
        True, description="是否知道出生时刻。false 时 birth_datetime 的时辰部分"
        "被忽略(统一按候选区间中点占位排盘:否 11:30 / 是 23:30 / 不确定 12:00,"
        "D3 2026-09-01 修订),响应 pillars.hour 置 null,喜忌引擎降级 unknown_hour")
    late_night: bool | None = Field(
        None, description="「是否在半夜(约 11 点后)出生」二值问题(D3,三态:"
        "True=是 / False=否 / None=不确定),仅 hour_known=false 时参与判定;"
        "hour_known=true 时忽略。**日柱歧义判据 = D3 三步区间测试**(2026-09-01 "
        "修订,非单边阈值):候选墙钟区间(否 [00:00,23:00) / 是 [23:00,24:00) / "
        "不确定全天)+ 真太阳时 offset_minutes → 真太阳时候选区间,歧义 ⟺ 区间"
        "内部严格包含一个真太阳时 23:00 换日点(见 true_solar_time."
        "day_pillar_ambiguous 场景表:西偏答「是」确定,东偏答「否」歧义)。"
        "歧义 → 日柱置 null(不猜);确定 → 占位中点落在该确定日柱区间内")

    @field_validator("birth_datetime")
    @classmethod
    def must_be_naive(cls, v: datetime) -> datetime:
        if v.tzinfo is not None or v.utcoffset() is not None:
            raise ValueError(
                "birth_datetime 必须为裸钟面时间(naive,不带 offset);"
                "时区走 timezone 字段(S02 契约)")
        return v

    @field_validator("timezone")
    @classmethod
    def timezone_must_be_iana(cls, v: str) -> str:
        validate_timezone(v)
        return v

    @field_validator("longitude")
    @classmethod
    def longitude_range(cls, v: float) -> float:
        if not (-180.0 <= v <= 180.0):
            raise ValueError("longitude 必须在 [-180, 180] 区间")
        return v

    @field_validator("latitude")
    @classmethod
    def latitude_range(cls, v: float | None) -> float | None:
        if v is not None and not (-90.0 <= v <= 90.0):
            raise ValueError("latitude 必须在 [-90, 90] 区间")
        return v


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
    """四柱。day/hour 可为 null(时辰未知显式缺失表达,docs/时辰未知设计决策.md):

    - hour_known=false → hour 恒为 null(时辰部分未知,禁用哨兵假精度)
    - 日柱歧义(hour_known=false 且 D3 区间测试命中:真太阳时候选区间内部
      含 23:00 换日点,2026-09-01 修订——西偏答「是」/东偏答「否」等场景
      见 true_solar_time.day_pillar_ambiguous)→ day 亦为 null(日主无,
      日主系派生输出一并置空)
    - 年柱/月柱歧义(S02/D10 节气边界双排盘比对:立春日/节交界日出生且
      时辰未知)→ year/month 亦为 null(生肖系/调候得令/大运序列级联置空,
      详见 pillar_ambiguity 字段;不猜,禁取 00:00 或 23:59 侧任一结果)
    """

    year: Pillar | None = None
    month: Pillar | None = None
    day: Pillar | None = None
    hour: Pillar | None = None


class PillarAmbiguity(BaseModel):
    """时辰未知时的柱歧义标记(S02/D10,进响应 + calc_rule_snapshot + content_hash)。

    - year/month:D10 节气边界双排盘比对命中(立春日/节交界日,≈3.3% 用户)
    - day:D3 区间测试命中(true_solar_time.day_pillar_ambiguous,2026-09-01
      修订:真太阳时候选区间内部含 23:00 换日点;「不确定」恒命中,西偏答
      「是」/东偏答「否」等场景见该函数场景表)
    - 不命中 → 全 False(响应与 S01 基础态一致);hour_known=true 恒不产生
      本对象(老路径零改动,响应字段为 null)
    - 不变量:pillar_ambiguity.<pos> == True ⟺ pillars.<pos> 为 null
    """

    year: bool = False
    month: bool = False
    day: bool = False


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
    # S02 契约:出生地 IANA 时区(审计/展示;老快照可能为空)
    birth_timezone: str | None = None
    # 时辰未知 S01:排盘是否含时柱(缺此字段则补时辰前后无法从快照分辨,
    # 「同一输入永远同一输出 + 快照可审计」被破坏)。默认 True 兼容老
    # ChartPayload 回显(2026-08-15 教训:payload 加字段必须可缺省)
    hour_known: bool = True
    # 时辰未知 S02/D10:柱歧义标记(年/月 = 节气边界双排盘;day = D3 区间测试)。
    # hour_known=true 恒 None(老路径快照不变);hour_known=false 必有值
    # (全 False = 无歧义)——歧义状态进快照,同 hash 可审计歧义降级口径
    pillar_ambiguity: PillarAmbiguity | None = None


# ---------- Meta 块(v1 prompt 系统:M0 chart JSON 注入) ----------

class MetaBlock(BaseModel):
    """v1 prompt 系统 §1 chart.meta 块。

    描述出生时间/空间/规则上下文,LLM 用其判断 solar_term_boundary 等结构信号。
    所有字段确定性产出(同输入同输出),不含 calculated_at。
    """

    locale: str = "zh-CN"
    gender: Literal["male", "female"]
    birth_local: str  # ISO 8601,含时区
    true_solar_time: str  # ISO 8601,naive(已剥离时区,真太阳时本地)
    late_zishi_rule: Literal["day_change_at_23", "zi_same_day"]
    solar_term_boundary: str  # 如 "雨水后",取 lunar.getPrevJieQi().getName() + "后"


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
    # 时辰未知时为 null:真太阳时含时辰信息,基于 12:00 占位的值属假精度,
    # 不漏到响应(占位一致性验收);偏移量本身只由日期+经度+时区决定,保留
    true_solar_time: datetime | None = None
    true_solar_offset_minutes: float

    @field_serializer("true_solar_time")
    def _serialize_true_solar_time(self, dt: datetime | None) -> str | None:
        """去微秒:iOS .iso8601 dateDecodingStrategy 不支持小数秒。"""
        if dt is None:
            return None
        return dt.replace(microsecond=0).isoformat()
    pillars: Pillars
    ming_gong: GanZhiNaYin
    shen_gong: GanZhiNaYin
    tai_yuan: GanZhiNaYin
    element_balance: ElementBalance

    # 决策 1 喜忌 —— 扶抑+调候+从格检测(D3)
    favorable_elements: list[str] = Field(default_factory=list)
    unfavorable_elements: list[str] = Field(default_factory=list)
    # unknown_hour(D4):时柱缺失或日柱歧义 → 引擎不硬算,喜忌留空
    # (镜像 special_pattern 从格诚实降级先例)
    day_master_strength: (Literal[
        "strong", "weak", "balanced", "special_pattern", "unknown_hour"
    ] | None) = None
    tiaoshou_applied: bool = False
    xiji_method: str | None = None  # "扶抑+调候" | "扶抑+调候(从格特征检测命中,未判定具体格局)"
    pattern_hint: Literal["zhuanwang", "cong"] | None = None

    # 决策 2 神煞 —— 《三命通会》20 个固定清单
    shensha: list[ShenshaItem] = Field(default_factory=list)
    # 时辰未知 S01:按可用柱查(时支/日支相关条目自然缺失),显式标注不静默
    shensha_incomplete: bool = False

    # 2026-08-01 grill-me 决策 #13 chart anchor sentence
    # 后端确定性拼接(0 AI 成本),iOS 在深度解析 Tab 顶部 instant 显示
    anchor_sentence: str | None = None

    # v1 prompt 系统:M0 chart JSON 注入字段(供 LLM 结构分析)
    # ten_god_weights: 全局十神权重,4 柱天干+地支藏干统计(10 个十神 → 计数)
    # useful_god_candidates: 喜用五行中文 list(从 favorable_elements 复用)
    # meta: 出生上下文(locale/gender/birth_local/true_solar_time/late_zishi_rule/solar_term_boundary)
    ten_god_weights: dict[str, int] = Field(default_factory=dict)
    useful_god_candidates: list[str] = Field(default_factory=list)
    meta: MetaBlock | None = None
    # 2026-08-11 生肖 wire up:年柱地支对应生肖(英文,对齐 iOS Zodiac_*.imageset)
    # pillars.year.zhi 已按立春算,这里仅查表暴露(修正客户端公历年推算的立春边界 bug)
    # 年柱歧义(S02/D10 立春日 + 时辰未知)→ null(年支不确定则生肖不猜,
    # 供 S08 生肖屏降级);老响应恒有值,Optional 化不破坏回显
    year_branch_zodiac: str | None = None
    # 2026-08-13 onboarding 反馈屏「好朋友 / 需磨合」:
    # 好朋友 = 六合 1 + 三合 2 = 3 支;需磨合 = 六冲 1 支。
    # 英文生肖名,复用 branch_relations.py(合盘引擎同一事实源)。
    # 年柱系派生:年柱歧义时随生肖一并置 null(对齐 year_branch_zodiac,不猜)
    year_branch_friends: list[str] | None = None
    year_branch_clash: str | None = None
    # 时辰未知 S02/D10:柱歧义标记(见 PillarAmbiguity)。hour_known=true
    # 恒 None(老路径响应形状不变);hour_known=false 必有值(全 False =
    # 与 S01 基础态一致,零歧义)
    pillar_ambiguity: PillarAmbiguity | None = None

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
