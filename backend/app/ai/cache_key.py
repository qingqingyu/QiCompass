"""AI 缓存键 value object(十维度身份 = 七维基础 + parent_hash + user_input_hash + language)。

把原本散落在 interpret.py 3 处 + cache.py 3 方法签名 + singleflight key 的参数
收敛到一个 frozen dataclass,防止漏维度(典型 bug:加新维度时漏改一处)。

frozen=True 自动生成 __hash__,可作 SingleflightCoalescer 的 dict key。

v1 prompt 系统新增两维:
- parent_hash:M0 产出的 structure_fingerprint 哈希,用于 M1-M7 链式调用缓存隔离
  (同 chart 但不同 M0 输出 → 不同缓存)
- user_input_hash:M4(age+concern)/ M5(assets+preference)用户输入哈希
  (同 chart 同 fingerprint 但不同用户输入 → 不同缓存)
老模块这两字段默认空串,行为不变。
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class CacheKey:
    """AI 解读缓存键(十维度身份)。

    十个字段全部参与 SQL PRIMARY KEY + singleflight dict key,任一不同即视为不同缓存条目。
    ADR-0009 强约束"切换 provider/model 后旧结果不冒充当前模型缓存"由 provider/model 两字段保证。
    i18n 决策 3:同一 content_hash + module + prompt_version 但不同 language = 不同缓存条目
    (避免英文用户拿到中文缓存,反之亦然)。

    Attributes:
        content_hash: ChartSnapshot hash 或 compatibility_hash
        module: "bazi_deep" / "compatibility" / "daily_fortune" /
            v1 新增 "m0_structure" ~ "m7_manual"
        prompt_version: 后端 PROMPT_VERSIONS 配置(改 prompt → +1 → 老缓存自然失效)
        target_date: daily_fortune 用 ISO date 字符串,其他传 None(内部转空串)
        prompt_hash: 渲染后 prompt 的 sha256(防止同 content_hash 不同 context 污染)
        provider: AI provider 身份(anthropic / openai)
        model: AI model 身份(claude-sonnet-4-6 / gpt-5.5)
        parent_hash: v1 链式调用 — M0 structure_fingerprint 的 sha256。
            M0 自身无 parent → 空串;M1-M7 必填(否则同 chart 不同 M0 输出会污染)。
            老模块(bazi_deep/compatibility/daily_fortune)留空串,行为不变。
        user_input_hash: v1 按需模块 — M4/M5 用户输入的 sha256。
            M4 = age + current_concern;M5 = assets_summary + preference。
            非按需模块留空串。
        language: 目标语言代码("zh" / "en",未来扩展 "ja" / "es")
    """

    content_hash: str
    module: str
    prompt_version: int
    target_date: str | None
    prompt_hash: str
    provider: str
    model: str
    # v1 prompt 系统新增字段(默认空串 → 老模块行为不变)
    parent_hash: str = ""
    user_input_hash: str = ""
    language: str = "zh"  # 默认 zh(向后兼容老 CacheKey 调用,i18n 决策 3)
