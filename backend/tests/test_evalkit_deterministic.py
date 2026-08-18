"""evalkit L1 确定性校验层单测(S02)。

全部手写字典,零 API 调用。判据实现是 S01 从 spike 迁入的
validate_v1_module_output(单一事实源),本文件主要测:
- check_deterministic 包装层(签名 / 未知 module raise)
- 各模块正例 / 缺字段 / 数组长度 / fingerprint / 双层禁词
- 与 spike 的委托关系(同输入同输出)
"""

from __future__ import annotations

import pytest

from evalkit.checks.deterministic import (
    check_deterministic,
    validate_v1_module_output,
)
from spikes.prompt_validation.run_v1_chain_spike import (
    validate_v1_module_output as spike_validate,
)

_ENGINE_RESULT = {
    "favorable_elements": ["metal", "water"],
    "unfavorable_elements": ["fire", "earth"],
    "day_master_strength": "weak",
    "shensha": [],
}


def _m0_ok() -> dict:
    return {
        "main_axis": {"dominant": "伤官"},
        "core_loop": {"from": "伤官", "to": "财"},
        "structure_type": {"name": "伤官生财", "one_line": "..."},
        "capability_source": {"text": "...", "evidence": "..."},
        "structure_fingerprint": "伤官生财驱动,外显创造力",  # ≤ 40 字
    }


def _m4_ok() -> dict:
    return {
        "battery_type": {"name": "..."},
        "imbalance_risks": ["a", "b", "c"],
        "recovery_levers": ["a", "b", "c"],
        "reset_7day": [f"d{i}" for i in range(7)],
        "weekly_maintenance": [],
        "medical_note": "建议",
    }


# ===== check_deterministic 包装层 =====


def test_check_deterministic_passes_valid_output():
    """正例:完整合法输出 → 空 failures。"""
    assert check_deterministic(
        "m0_structure", _m0_ok(), _ENGINE_RESULT) == []


def test_check_deterministic_delegates_to_validator():
    """委托关系:check_deterministic 与 validate_v1_module_output 同输出。"""
    bad = {"core_loop": {}}
    assert (check_deterministic("m0_structure", bad, _ENGINE_RESULT)
            == validate_v1_module_output("m0_structure", bad))


def test_check_deterministic_unknown_module_raises():
    """未知 module → raise,不静默返回空(新模块悄悄失去 L1 保护不可接受)。"""
    with pytest.raises(ValueError, match="未知 module"):
        check_deterministic("m9_nonexistent", {"x": 1}, _ENGINE_RESULT)


def test_single_source_with_spike():
    """单一事实源:spike 的 validator 与 evalkit 的是同一函数对象。"""
    assert spike_validate is validate_v1_module_output


# ===== 必填字段 =====


def test_missing_field_failure_contains_field_name():
    parsed = _m0_ok()
    del parsed["main_axis"]
    failures = check_deterministic("m0_structure", parsed, _ENGINE_RESULT)
    assert any("main_axis" in f for f in failures)


def test_every_module_valid_output_passes():
    """8 个模块各一组正例 → 全过。"""
    ok_outputs = {
        "m0_structure": _m0_ok(),
        "m1_talent": {
            "innate": [], "trained": [], "defensive": [],
            "one_leverage": "创造力",
        },
        "m2_high_low": {
            "high_config": {}, "low_config": {}, "threshold": {},
            "early_warnings": ["a", "b", "c"],
            "switch_actions": ["a", "b", "c"],
        },
        "m3_system": {
            "operating_mode": {}, "failure_environments": [],
            "ideal_life_structure": {}, "stability_vs_volatility": {},
            "environment_checklist": ["q1", "q2", "q3", "q4", "q5"],
        },
        "m4_health": _m4_ok(),
        "m5_wealth": {
            "income_forms": [{"form": f"f{i}", "rank": i}
                             for i in range(1, 7)],
            "leaks": [], "strategies": {},
            "asset_ideas": ["a", "b", "c"], "disclaimer": "x",
        },
        "m6_dynamics": {
            "energy_path": {}, "leverage": {},
            "vulnerability": {}, "upgrade_path": {},
        },
        "m7_manual": {
            "true_leverage": {},
            "use_cases": ["a", "b", "c"],
            "next_90_days": {},
            "falsification_signals": ["a", "b"],
        },
    }
    for module, parsed in ok_outputs.items():
        assert check_deterministic(module, parsed, _ENGINE_RESULT) == [], (
            f"{module} 正例不应有 failure"
        )


# ===== 数组长度 =====


def test_array_length_mismatch_failure():
    parsed = _m4_ok()
    parsed["reset_7day"] = ["d1", "d2", "d3", "d4", "d5"]  # 5 != 7
    failures = check_deterministic("m4_health", parsed, _ENGINE_RESULT)
    assert any("reset_7day" in f and "5" in f and "7" in f
               for f in failures)


def test_array_field_not_list_failure():
    parsed = _m4_ok()
    parsed["recovery_levers"] = "not a list"
    failures = check_deterministic("m4_health", parsed, _ENGINE_RESULT)
    assert any("recovery_levers" in f and "非 list" in f for f in failures)


# ===== structure_fingerprint =====


def test_fingerprint_too_long_failure():
    parsed = _m0_ok()
    parsed["structure_fingerprint"] = "一" * 41
    failures = check_deterministic("m0_structure", parsed, _ENGINE_RESULT)
    assert any("structure_fingerprint" in f for f in failures)


def test_fingerprint_empty_failure():
    parsed = _m0_ok()
    parsed["structure_fingerprint"] = ""
    failures = check_deterministic("m0_structure", parsed, _ENGINE_RESULT)
    assert any("structure_fingerprint" in f for f in failures)


# ===== 双层禁词 =====


def test_production_forbidden_word_failure():
    """生产层禁词(注定/绝对)→ failure 标明生产层。"""
    parsed = _m0_ok()
    parsed["structure_fingerprint"] = "注定要分手的结构"
    failures = check_deterministic("m0_structure", parsed, _ENGINE_RESULT)
    assert any("生产禁词" in f for f in failures)


def test_extended_forbidden_word_failure():
    """仅 v1 §4 扩展层禁词(稳赚,生产未禁)→ failure 标明扩展层。"""
    parsed = _m4_ok()
    parsed["medical_note"] = "此法稳赚不赔"
    failures = check_deterministic("m4_health", parsed, _ENGINE_RESULT)
    assert any("v1 §4 扩展禁词" in f for f in failures)
    assert not any("生产禁词" in f for f in failures)


def test_production_and_extended_layers_reported_separately():
    """两层同时命中 → 两条 failure 分别可辨。"""
    parsed = _m4_ok()
    parsed["medical_note"] = "绝对稳赚"
    failures = check_deterministic("m4_health", parsed, _ENGINE_RESULT)
    assert sum("生产禁词" in f for f in failures) == 1
    assert sum("v1 §4 扩展禁词" in f for f in failures) == 1
