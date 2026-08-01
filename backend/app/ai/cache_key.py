"""AI 缓存键 value object(ADR-0009 七维度身份)。

把原本散落在 interpret.py 3 处 + cache.py 3 方法签名 + singleflight key 的 7 参数
收敛到一个 frozen dataclass,防止漏维度(典型 bug:加新维度时漏改一处)。

frozen=True 自动生成 __hash__,可作 SingleflightCoalescer 的 dict key。
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class CacheKey:
    """AI 解读缓存键(七维度身份)。

    七个字段全部参与 SQL PRIMARY KEY + singleflight dict key,任一不同即视为不同缓存条目。
    ADR-0009 强约束"切换 provider/model 后旧结果不冒充当前模型缓存"由 provider/model 两字段保证。

    Attributes:
        content_hash: ChartSnapshot hash 或 compatibility_hash
        module: "bazi_deep" / "compatibility" / "daily_fortune"
        prompt_version: 后端 PROMPT_VERSIONS 配置(改 prompt → +1 → 老缓存自然失效)
        target_date: daily_fortune 用 ISO date 字符串,其他传 None(内部转空串)
        prompt_hash: 渲染后 prompt 的 sha256(防止同 content_hash 不同 context 污染)
        provider: AI provider 身份(anthropic / openai)
        model: AI model 身份(claude-sonnet-4-6 / gpt-5.5)
    """

    content_hash: str
    module: str
    prompt_version: int
    target_date: str | None
    prompt_hash: str
    provider: str
    model: str
