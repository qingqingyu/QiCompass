"""L1 确定性校验层(不花钱,必跑)。

判据实现(validate_v1_module_output + 两张表)迁自
spikes/prompt_validation/run_v1_chain_spike.py,**单一事实源**:
spike 与 evalkit 共用本模块,禁止第二份拷贝。

L1 判什么:JSON 可解析(在 llm_json.parse_llm_json)/ 必填顶层字段齐 /
数组长度精确 / structure_fingerprint 非空且 ≤40 字 / 双层禁词
(生产 ABSOLUTE_CONCLUSIONS + v1 §4 扩展词表,两层分别成条 failure,
便于 UI 区分"违反生产红线"与"违反 v1 §4 但生产未禁")。
"""

from __future__ import annotations

import json
from typing import Any

from app.ai.forbidden_words import scan as scan_forbidden_words

# 每个 module 必填的顶层字段(对齐 prompts.py M0-M7 模板的 JSON 输出 schema)
_MODULE_REQUIRED_FIELDS: dict[str, tuple[str, ...]] = {
    "m0_structure": (
        "main_axis", "core_loop", "structure_type",
        "capability_source", "structure_fingerprint",
    ),
    "m1_talent": ("innate", "trained", "defensive", "one_leverage"),
    "m2_high_low": (
        "high_config", "low_config", "threshold",
        "early_warnings", "switch_actions",
    ),
    "m3_system": (
        "operating_mode", "failure_environments",
        "ideal_life_structure", "stability_vs_volatility",
        "environment_checklist",
    ),
    "m4_health": (
        "battery_type", "imbalance_risks", "recovery_levers",
        "reset_7day", "weekly_maintenance", "medical_note",
    ),
    "m5_wealth": (
        "income_forms", "leaks", "strategies",
        "asset_ideas", "disclaimer",
    ),
    "m6_dynamics": (
        "energy_path", "leverage", "vulnerability", "upgrade_path",
    ),
    "m7_manual": (
        "true_leverage", "use_cases", "next_90_days",
        "falsification_signals",
    ),
}

# v1 §4 扩展禁词(生产 app/ai/forbidden_words.py 当前只含 ABSOLUTE_CONCLUSIONS,
# 不含寿元/绝症/必赚/稳赚/包治/血光/克夫/大凶/劫难/破财 等)。
# evalkit 用扩展列表做更严的校验,识别"v1 §4 禁止但生产未禁"的输出。
# 生产是否同步扩展由后续决策(暂不扩,避免影响老 module)。
_V1_EXTENDED_FORBIDDEN_WORDS: tuple[str, ...] = (
    "注定", "必然", "命中该", "逃不掉", "破财", "血光",
    "克夫", "大凶", "劫难", "寿元", "绝症", "必赚", "稳赚", "包治",
)


def validate_v1_module_output(module: str, parsed: dict[str, Any]) -> list[str]:
    """校验 LLM 输出 JSON 是否符合 v1 §3 schema。

    Returns:
        failures 列表(空 = 全过)
    """
    failures: list[str] = []

    # 1. 必填顶层字段
    required = _MODULE_REQUIRED_FIELDS.get(module, ())
    missing = [f for f in required if f not in parsed]
    if missing:
        failures.append(f"缺字段:{missing}")

    # 2. structure_fingerprint 长度(M0 必填,≤ 40 字)
    if module == "m0_structure":
        fp = parsed.get("structure_fingerprint", "")
        if not isinstance(fp, str) or not fp:
            failures.append("structure_fingerprint 为空或非 str")
        elif len(fp) > 40:
            failures.append(
                f"structure_fingerprint 长度 {len(fp)} 超 40 字: {fp!r}"
            )

    # 3. 数组字段长度约束
    array_constraints = {
        "m2_high_low": [("early_warnings", 3), ("switch_actions", 3)],
        "m3_system": [("environment_checklist", 5)],
        "m4_health": [
            ("imbalance_risks", 3), ("recovery_levers", 3),
            ("reset_7day", 7),
        ],
        "m5_wealth": [("income_forms", 6), ("asset_ideas", 3)],
        "m7_manual": [("use_cases", 3), ("falsification_signals", 2)],
    }
    for field, expected_len in array_constraints.get(module, []):
        value = parsed.get(field)
        if not isinstance(value, list):
            failures.append(
                f"{field} 非 list(类型={type(value).__name__})"
            )
        elif len(value) != expected_len:
            failures.append(
                f"{field} 长度 {len(value)} != 期望 {expected_len}"
            )

    # 4. 禁词扫描(双层)
    # 4a. 生产 ABSOLUTE_CONCLUSIONS(走 app.ai.forbidden_words.scan)
    text_blob = json.dumps(parsed, ensure_ascii=False)
    production_hits = scan_forbidden_words(text_blob)
    if production_hits:
        failures.append(f"生产禁词命中:{production_hits}")
    # 4b. v1 §4 扩展禁词(evalkit 侧列表,不动生产词表)
    extended_hits = [w for w in _V1_EXTENDED_FORBIDDEN_WORDS if w in text_blob]
    if extended_hits:
        failures.append(f"v1 §4 扩展禁词命中:{extended_hits}")

    return failures


def check_deterministic(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """L1 聚合入口(module-agnostic,与 L2 签名对齐便于统一编排)。

    Args:
        module: v1 module ID
        parsed_output: parse_llm_json 后的 LLM 输出 dict
        engine_result: 排盘结果(本层不用,签名为编排统一)

    Returns:
        failures 列表,空 = 全过

    Raises:
        ValueError: 未知 module。静默返回空 failures 会让新加模块
            悄悄失去 L1 保护(spike 时代的宽容策略在常驻评测机上不可接受)
    """
    if module not in _MODULE_REQUIRED_FIELDS:
        raise ValueError(
            f"未知 module: {module!r}(evalkit L1 需注册到 "
            f"_MODULE_REQUIRED_FIELDS,合法值: {list(_MODULE_REQUIRED_FIELDS)})"
        )
    return validate_v1_module_output(module, parsed_output)
