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
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from ..core.tz_resolution import validate_timezone
from .bazi import BaziCalculateResponse, CalcRuleSnapshot
from .daily_fortune import ChartPayload


Context = Literal["general", "marriage", "business"]

# ---------- 引擎规则版本 ----------

#: 合盘确定性引擎规则版本（2026-10-07 合冲标签判定序修复起 = 2）。
#: 语义：iOS CompatibilitySnapshot 持久化此值，加载/预查时与本地镜像比对——
#: 版本不同 = 快照按旧规则算出，须重算（合冲判定序/阈值变更后老快照不得
#: 继续展示旧标签，详见 compute_compatibility_hash 的"不加版本"注释与
#: CLAUDE.md "同一输入同一输出（含规则快照）"约束）。
#: **不参与 compatibility_hash**：hash 是 entitlement / AI 缓存的 content_hash
#: 维度，掺版本会孤儿化全部已购记录与既有缓存键——失效走"快照重算"而非
#: "换键"。
#: bump 时机：_assess_branch_harmony 等确定性判定规则变更；**必须与 iOS
#: CompatibilitySnapshotStore.expectedEngineRuleVersion 同步 bump**（漏 bump
#: 最坏 = 老快照多活一版，不崩溃）。
COMPATIBILITY_RULE_VERSION = 2


# ---------- Request ----------

class PersonBInput(BaseModel):
    """模式 B（B 临时输入）：字段子集复用 BaziCalculateRequest。

    S02 契约:裸钟面 birth_datetime + timezone + 物理真值 longitude,
    后端按 zoneinfo 解释后现排 B(与 /api/bazi/calculate 同一套规则)。
    """

    # S02 零兼容垫片:未知字段(含旧 city)直接 422,不静默丢弃
    model_config = ConfigDict(extra="forbid")

    birth_datetime: datetime = Field(
        ..., description="出生钟面时间(ISO 8601, naive 无 offset), "
                         "例 1990-03-15T14:30:00;时区由 timezone 字段解释")
    timezone: str = Field(
        ..., description="出生地 IANA 时区名, 例 Asia/Shanghai")
    gender: Literal["male", "female"]
    longitude: float = Field(
        ..., description="出生地经度(东正西负)")
    latitude: float | None = Field(
        None, description="存档用")
    place_name: str | None = Field(
        None, description="展示用城市名, 不参与 hash")
    geoname_id: int | None = Field(
        None, description="GeoNames ID, 仅日志/诊断")
    zi_hour_rule: Literal["zi_next_day"] = Field(
        "zi_next_day", description="MVP 固定 zi_next_day, 内部 setSect(1)")

    @field_validator("birth_datetime")
    @classmethod
    def must_be_naive(cls, v: datetime) -> datetime:
        if v.tzinfo is not None or v.utcoffset() is not None:
            raise ValueError(
                "birth_datetime 必须为裸钟面时间(naive, 不带 offset);"
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


class CompatibilityRequest(BaseModel):
    """POST /api/bazi/compatibility 请求。"""

    person_a_hash: str = Field(
        ..., pattern=r"^[0-9a-f]{64}$",
        description="A 盘 content_hash(64 位 sha256 hex), 引用已存档 ChartSnapshot")
    person_b_hash: str | None = Field(
        None, pattern=r"^[0-9a-f]{64}$",
        description="模式 A: B 盘 content_hash(64 位 sha256 hex), 引用已存档 ChartSnapshot")
    person_b: PersonBInput | None = Field(
        None, description="模式 B: B 临时输入字段（与 person_b_hash 互斥）")
    chart_payload_a: ChartPayload = Field(
        ..., description="A 盘瘦身 payload, 含日主/喜忌/四柱")
    chart_payload_b: ChartPayload | None = Field(
        None, description="模式 A 必填; 模式 B 由后端现排后内部生成")
    context: Context = Field("general", description="合盘语境, 仅参与 hash + AI prompt")
    # 2026-10-07 P0 收口:chart_payload 与 hash 单向不可逆,服务端无法复算——
    # 携带排盘端点签发的 payload 族 per-chart token,端点做 token↔hash↔payload
    # 三方对账后才签发合盘 token(否则「假 payload 换合法签发」循环信任)。
    context_token_a: str | None = Field(
        None, max_length=32768,
        description="A 盘 per-chart token(/api/bazi/calculate 响应 "
                    "context_tokens.payload);schema 可选,端点显式强制"
                    "(缺失 → 403,让单测可直接构造本模型)")
    context_token_b: str | None = Field(
        None, max_length=32768,
        description="模式 A: B 盘 per-chart token(模式 B 后端现排, 必须为 null)")

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
        """模式 A (person_b_hash 给定) 下 chart_payload_b 必填（不静默）。

        context_token_b 的模式约束:模式 A 允许、模式 B 必须为 null
        (B 由后端现排无 token);「模式 A 必须带 token」不在 schema 层强制
        (token 存在性由端点 403 把关,单测构造模型不必带)。
        """
        if self.person_b_hash is not None and self.chart_payload_b is None:
            raise ValueError(
                "模式 A (person_b_hash) 下 chart_payload_b 必填")
        if self.person_b is not None and self.context_token_b is not None:
            raise ValueError(
                "模式 B (person_b) 下 context_token_b 必须为 null"
                "(B 由后端现排, 无 per-chart token)")
        return self


# ---------- Response ----------

class QualitativeAssessment(BaseModel):
    """四项定性评估（确定性，不走 LLM）。禁止任何数字分。

    字段值均为中文短语, 取值集见最终方案 §1.2:
    - five_elements: 互补佳 / 有一定互补 / 互补较弱 / 信息不足
    - day_master_relation: 同气 / 相生 / 相克
    - zodiac_match: 六合 / 三合 / 六冲 / 三刑 / 相害 / 无特殊合冲
    - branch_harmony: 无冲无刑 / 一冲一合 / 多冲少合 / 多合少冲 / 多刑多害 / 略有冲刑害
    """

    five_elements: Literal[
        "互补佳", "有一定互补", "互补较弱", "信息不足"]
    day_master_relation: Literal["同气", "相生", "相克"]
    zodiac_match: Literal[
        "六合", "三合", "六冲", "三刑", "相害", "无特殊合冲"]
    branch_harmony: Literal[
        "无冲无刑", "一冲一合", "多冲少合", "多合少冲", "多刑多害", "略有冲刑害"]


class SyncedFortune(BaseModel):
    """单条流年同步（共 3 条, 当前年 +1/+2/+3）。"""

    year: int
    person_a: str = Field(..., description="形如「乙亥运 丙午年」")
    person_b: str = Field(..., description="形如「丁丑运 丙午年」")
    sync: Literal["同步走强", "同步承压", "运势分化", "难以定性"] = Field(
        ..., description="同步走强 / 同步承压 / 运势分化 / 难以定性")


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
    calc_rule_snapshot: CalcRuleSnapshot | None = Field(
        None, description=(
            "模式 B 用 B 排盘的快照; 模式 A 若 payload 带了快照则用 A 的, "
            "否则为 None(模式 A 后端零排盘,无真实经度/时区偏移,不塞占位值)"
        ))
    rule_version: int = Field(
        default=COMPATIBILITY_RULE_VERSION,
        description=(
            "确定性引擎规则版本(客户端快照据此判断是否须重算; "
            "不参与 compatibility_hash)"
        ))
    # 2026-10-07 P0 收口:合盘 context 核心字段绑定 token(interpret/translate
    # 验签;由已对账的 A/B payload token claims + 引擎定性评估派生)
    context_token: str | None = Field(
        None, description="compat 族 context_token(客户端存档随请求回传)")
