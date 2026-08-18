"""LLM JSON 输出解析(迁自 spikes/prompt_validation/run_v1_chain_spike.py)。

独立成叶子模块而非放在 runner.py,原因:S05 的 judge.py 也要复用
parse_llm_json,若放在 runner 会在 runner(调 judge)与 judge(调 parse)
之间形成循环 import。判据逻辑零改动,纯迁移。
"""

from __future__ import annotations

import json
import re
from typing import Any


def parse_llm_json(text: str) -> dict[str, Any]:
    """从 LLM 文本响应中解析 JSON。

    LLM 输出即使 prompt 要求"不加 markdown 代码块围栏",偶尔还是会带 ```json ... ```
    或前后空白。本函数:
    1. 去 markdown fence(若存在)
    2. json.loads(text)
    3. 校验顶层是 dict

    Raises:
        ValueError: JSON 解析失败 / 顶层非 dict
    """
    cleaned = text.strip()
    # 去 markdown code fence(```json ... ``` 或 ``` ... ```)
    fence_match = re.match(r"^```(?:json)?\s*(.*?)\s*```$", cleaned, re.DOTALL)
    if fence_match:
        cleaned = fence_match.group(1).strip()
    # 截第一个 { 到最后一个 }(防 LLM 加前后语)
    first_brace = cleaned.find("{")
    last_brace = cleaned.rfind("}")
    if first_brace != -1 and last_brace != -1 and last_brace > first_brace:
        cleaned = cleaned[first_brace:last_brace + 1]
    try:
        parsed = json.loads(cleaned)
    except json.JSONDecodeError as e:
        raise ValueError(
            f"LLM 输出非合法 JSON: {e}(text 头 200 字: {cleaned[:200]!r})"
        ) from e
    if not isinstance(parsed, dict):
        raise ValueError(
            f"LLM 输出 JSON 顶层非 object(type={type(parsed).__name__})"
        )
    return parsed
