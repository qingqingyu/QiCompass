"""POST /api/interpret Pydantic v2 schema。

契约对齐最终方案 §3:
- content_hash 提升为顶层必填(设计文档 :209 未显式列出,D2 缓存键需要)
- module ∈ 三值;target_date 与 module 交叉校验(daily_fortune 必填,其他必须 null)
- context 是 dict,渲染前由 ai/prompts.py 的 validate_context 显式校验必填字段
- prompt_version 不在 Request 中(必须来自后端 config.PROMPT_VERSIONS,禁止客户端决定)
"""

from __future__ import annotations

from datetime import date, datetime
from typing import Any, Literal

from pydantic import BaseModel, Field, field_serializer, field_validator, model_validator


Module = Literal["bazi_deep", "compatibility", "daily_fortune"]


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
    question: Any | None = Field(
        None, description="保留字段,MVP 忽略")

    @field_validator("content_hash")
    @classmethod
    def content_hash_not_blank(cls, v: str) -> str:
        normalized = v.strip()
        if not normalized:
            raise ValueError("content_hash 不能为空")
        return normalized

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

    @field_serializer("generated_at")
    def _serialize_generated_at(self, dt: datetime) -> str:
        """去微秒:iOS .iso8601 dateDecodingStrategy 不支持小数秒。"""
        return dt.replace(microsecond=0).isoformat()
