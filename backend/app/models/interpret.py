"""POST /api/interpret Pydantic v2 schema。

契约对齐最终方案 §3 + MONETIZATION.md(M2 拆分)+ v1 prompt 系统(M0-M7):
- content_hash 提升为顶层必填(设计文档 :209 未显式列出,D2 缓存键需要)
- module ∈ 老五值 + v1 新八值
  - 老:bazi_deep(alias)/ bazi_deep_free(2 章免费)/ bazi_deep_paid(5 章付费)/
        compatibility / daily_fortune
  - v1 新:m0_structure(免费)~ m7_manual(付费),按 v1 prompt 系统模块化
- target_date 与 module 交叉校验(daily_fortune 必填,其他必须 null)
- user_local_id 与 module 交叉校验(PAID_MODULES 必填,其他可选)
- parent_fingerprint 与 module 交叉校验(M1-M7 必填,M0 自身不需要)
- m4_age + m4_current_concern 与 m4_health 交叉校验(必填)
- m5_assets_summary + m5_preference 与 m5_wealth 交叉校验(必填)
- context 是 dict,渲染前由 ai/prompts.py 的 validate_context 显式校验必填字段
- prompt_version 不在 Request 中(必须来自后端 config.PROMPT_VERSIONS,禁止客户端决定)
"""

from __future__ import annotations

from datetime import date, datetime
from typing import Any, Literal

from pydantic import BaseModel, Field, field_serializer, field_validator, model_validator


Module = Literal[
    # 老 5 个 module(M2 拆分 + alias + 合盘 + 每日)
    "bazi_deep",          # alias(M2 决策 B 保留,旧 iOS 兼容)
    "bazi_deep_free",     # M2 拆分:2 章免费
    "bazi_deep_paid",     # M2 拆分:5 章付费(需 entitlement)
    "compatibility",
    "daily_fortune",
    # v1 prompt 系统新 8 个 module(M0 主线 → M7 落地手册)
    # Stage 4 加 Literal + 部分接入;Stage 5 加 PROMPT_VERSIONS + 模板后真正可用
    "m0_structure",       # 免费:识别主线结构,产出 structure_fingerprint
    "m1_talent",          # 免费:天赋能力(innate/trained/defensive)
    "m2_high_low",        # 付费:高配/低配(环境/信念/觉察)
    "m3_system",          # 付费:人生系统模式
    "m4_health",          # 付费:健康续航(需 age + current_concern)
    "m5_wealth",          # 付费:财富结构(需 assets_summary + preference)
    "m6_dynamics",        # 付费:结构动力学(高阶)
    "m7_manual",          # 付费:落地手册
]


# v1 prompt 系统模块集合(常量化,避免字面值散落)
V1_MODULES: frozenset[str] = frozenset({
    "m0_structure", "m1_talent", "m2_high_low",
    "m3_system", "m4_health", "m5_wealth",
    "m6_dynamics", "m7_manual",
})

# 付费 module 白名单(替代老 endswith("_paid") 判定;v1 新模块无 _paid 后缀)
# 用 frozenset 作 O(1) 查找;literal 与 Module 对齐
PAID_MODULES: frozenset[str] = frozenset({
    # 老 module:含 _paid 后缀的
    "bazi_deep_paid",
    # v1 新 module:M2-M7 付费(M0+M1 免费)
    "m2_high_low", "m3_system", "m4_health", "m5_wealth",
    "m6_dynamics", "m7_manual",
})

# 需要 parent_fingerprint(M0 输出)的 module:M1-M7(M0 自身不需要)
V1_CHILDREN_MODULES: frozenset[str] = V1_MODULES - {"m0_structure"}

# 需要用户输入(M4/M5)的 module
V1_NEEDS_USER_INPUT: frozenset[str] = frozenset({"m4_health", "m5_wealth"})


class InterpretRequest(BaseModel):
    """POST /api/interpret 请求。"""

    content_hash: str = Field(
        ..., description="缓存键:bazi_deep 用命盘 hash,compatibility 用 compatibility_hash,"
                         "daily_fortune 用命盘 hash")
    module: Module
    context: dict[str, Any] = Field(
        ..., description="prompt 渲染负载(各 module 形状不同,由 ai/prompts.py 校验)")
    target_date: date | None = Field(
        None, description="daily_fortune 必填(ISO date),其他 module 必须为 null")
    user_local_id: str | None = Field(
        None, description="付费 module 必填(PAID_MODULES),其他可选;"
                          "用于 entitlement 查询(MONETIZATION.md)")
    question: Any | None = Field(
        None, description="保留字段,MVP 忽略")

    # v1 prompt 系统新字段(M0-M7 链式调用 + 按需模块)
    # max_length 防御:客户端理论上不会超,但 422 比 OOM 优雅(M0 fingerprint
    # 实际是固定长度 hash,用户输入也应合理短)
    parent_fingerprint: str | None = Field(
        None, max_length=256,
        description="M0 产出的 structure_fingerprint;M1-M7 必填"
                    "(M0 自身不需要)。用于链式调用缓存隔离 parent_hash 维度。")
    m4_age: int | None = Field(
        None, description="M4(m4_health)必填:年龄", ge=0, le=150)
    m4_current_concern: str | None = Field(
        None, max_length=500,
        description="M4(m4_health)必填:当前困扰(睡眠/疲劳/体重/情绪 等)")
    m5_assets_summary: str | None = Field(
        None, max_length=500,
        description="M5(m5_wealth)必填:资产/收入概况(可粗略)")
    m5_preference: str | None = Field(
        None, max_length=100,
        description="M5(m5_wealth)必填:偏好(保守/平衡/进攻)")

    @field_validator("content_hash")
    @classmethod
    def content_hash_not_blank(cls, v: str) -> str:
        normalized = v.strip()
        if not normalized:
            raise ValueError("content_hash 不能为空")
        return normalized

    @field_validator("user_local_id")
    @classmethod
    def user_local_id_stripped(cls, v: str | None) -> str | None:
        """strip 后非空校验(传入 "  " 视为 None,避免 is not None 误判)。"""
        if v is None:
            return None
        normalized = v.strip()
        return normalized or None

    @field_validator("parent_fingerprint")
    @classmethod
    def parent_fingerprint_stripped(cls, v: str | None) -> str | None:
        """strip 后非空校验(同 user_local_id 策略)。"""
        if v is None:
            return None
        normalized = v.strip()
        return normalized or None

    @field_validator("m4_current_concern")
    @classmethod
    def m4_current_concern_stripped(cls, v: str | None) -> str | None:
        if v is None:
            return None
        normalized = v.strip()
        return normalized or None

    @field_validator("m5_assets_summary")
    @classmethod
    def m5_assets_summary_stripped(cls, v: str | None) -> str | None:
        if v is None:
            return None
        normalized = v.strip()
        return normalized or None

    @field_validator("m5_preference")
    @classmethod
    def m5_preference_stripped(cls, v: str | None) -> str | None:
        if v is None:
            return None
        normalized = v.strip()
        return normalized or None

    @model_validator(mode="after")
    def target_date_matches_module(self) -> "InterpretRequest":
        if self.module == "daily_fortune":
            if self.target_date is None:
                raise ValueError(
                    "module=daily_fortune 时 target_date 必填(ISO date)")
        else:
            if self.target_date is not None:
                raise ValueError(
                    f"module={self.module} 时 target_date 必须为 null"
                    f"(仅 daily_fortune 使用 target_date)")
        return self

    @model_validator(mode="after")
    def paid_module_requires_user_local_id(self) -> "InterpretRequest":
        """付费 module 必须带 user_local_id(entitlement 查询需要)。

        路由层(/api/interpret)在步骤 2.5 会用 (content_hash, module, user_local_id)
        查 entitlement,缺一不可。这里在 schema 层先拦,返 422 比 403 更准确。

        白名单 PAID_MODULES 替代老 endswith("_paid") 判定:v1 新 module
        (m2_high_low ~ m7_manual)无 _paid 后缀但都是付费。
        """
        if self.module in PAID_MODULES and not self.user_local_id:
            raise ValueError(
                f"module={self.module} 时 user_local_id 必填"
                f"(付费内容需要 entitlement 校验)")
        return self

    @model_validator(mode="after")
    def v1_children_require_parent_fingerprint(self) -> "InterpretRequest":
        """v1 prompt 系统:M1-M7 必须带 parent_fingerprint(M0 输出)。

        M0 自身不需要 parent(它是 fingerprint 的产生者)。
        老模块(bazi_deep_*等)不需要 parent(走老 prompt 路径)。
        链式调用:M0 先跑 → 客户端解析 structure_fingerprint → 注入 M1-M7 请求。
        """
        if self.module in V1_CHILDREN_MODULES and not self.parent_fingerprint:
            raise ValueError(
                f"module={self.module} 时 parent_fingerprint 必填"
                f"(M0 产出的 structure_fingerprint,链式调用必需)")
        return self

    @model_validator(mode="after")
    def m4_health_requires_user_inputs(self) -> "InterpretRequest":
        """M4 健康模块必填 age + current_concern(v1 按需模块设计)。

        反向校验:非 m4_health 时 m4_age / m4_current_concern 必须为 null,
        防止客户端对无关 module 塞字段(语义严谨 + 未来扩展不埋雷)。
        """
        if self.module == "m4_health":
            if self.m4_age is None:
                raise ValueError(
                    "module=m4_health 时 m4_age 必填(年龄)")
            if not self.m4_current_concern:
                raise ValueError(
                    "module=m4_health 时 m4_current_concern 必填"
                    "(睡眠/疲劳/体重/情绪 等)")
        else:
            if self.m4_age is not None:
                raise ValueError(
                    f"module={self.module} 时 m4_age 必须为 null"
                    f"(仅 m4_health 使用)")
            if self.m4_current_concern is not None:
                raise ValueError(
                    f"module={self.module} 时 m4_current_concern 必须为 null"
                    f"(仅 m4_health 使用)")
        return self

    @model_validator(mode="after")
    def m5_wealth_requires_user_inputs(self) -> "InterpretRequest":
        """M5 财富模块必填 assets_summary + preference(v1 按需模块设计)。

        反向校验:非 m5_wealth 时 m5_* 必须为 null(同 m4 策略)。
        """
        if self.module == "m5_wealth":
            if not self.m5_assets_summary:
                raise ValueError(
                    "module=m5_wealth 时 m5_assets_summary 必填"
                    "(资产/收入概况,可粗略)")
            if not self.m5_preference:
                raise ValueError(
                    "module=m5_wealth 时 m5_preference 必填"
                    "(保守/平衡/进攻)")
        else:
            if self.m5_assets_summary is not None:
                raise ValueError(
                    f"module={self.module} 时 m5_assets_summary 必须为 null"
                    f"(仅 m5_wealth 使用)")
            if self.m5_preference is not None:
                raise ValueError(
                    f"module={self.module} 时 m5_preference 必须为 null"
                    f"(仅 m5_wealth 使用)")
        return self


class InterpretResponse(BaseModel):
    """POST /api/interpret 响应。"""

    interpretation: str
    prompt_version: int = Field(
        ..., description="后端本次用的版本号(客户端存本地 SwiftData 缓存键对齐用)")
    cached: bool = Field(
        ..., description="是否命中后端缓存(调试/验收用)")
    generated_at: datetime = Field(
        ..., description="ISO 8601 UTC,解读生成时间(缓存命中时为原生成时间)")
    provider: Literal["anthropic", "openai"] = Field(
        ..., description="本次解读实际使用的 AI provider")
    model: str = Field(
        ..., min_length=1, description="本次解读实际使用的模型")
    language: str = Field(
        ...,
        description="本次解读实际使用的语言代码(规范化:zh / en,未来扩展 ja / es)。"
                   "从 Accept-Language header 解析;客户端存入 SwiftData 缓存键对齐用"
                   "(i18n 决策 10 方案 3:后端是 language 事实源)")

    @field_serializer("generated_at")
    def _serialize_generated_at(self, dt: datetime) -> str:
        """去微秒:iOS .iso8601 dateDecodingStrategy 不支持小数秒。"""
        return dt.replace(microsecond=0).isoformat()
