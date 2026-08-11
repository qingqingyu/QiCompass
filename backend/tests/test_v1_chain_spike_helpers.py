"""v1 链式 spike 辅助函数单元测试(Stage 6)。

跑这些测试不需要 AI key,只校验:
- parse_llm_json:LLM 文本 → dict(去 markdown fence + json.loads)
- validate_v1_module_output:dict → failures 列表(必填字段 + 数组长度 + 禁词)
"""

from __future__ import annotations

import pytest

from spikes.prompt_validation.run_v1_chain_spike import (
    parse_llm_json,
    validate_v1_module_output,
)


# ===== parse_llm_json =====


def test_parse_plain_json():
    """无 markdown fence 的纯 JSON。"""
    text = '{"a": 1, "b": "x"}'
    parsed = parse_llm_json(text)
    assert parsed == {"a": 1, "b": "x"}


def test_parse_json_with_markdown_fence():
    """LLM 加了 ```json ... ``` 围栏(即使 prompt 禁止,偶尔会发生)。"""
    text = '```json\n{"a": 1}\n```'
    parsed = parse_llm_json(text)
    assert parsed == {"a": 1}


def test_parse_json_with_bare_fence():
    """LLM 加了 ``` ... ``` 无 language 标签的围栏。"""
    text = '```\n{"a": 1}\n```'
    parsed = parse_llm_json(text)
    assert parsed == {"a": 1}


def test_parse_json_with_prefix_and_suffix_text():
    """LLM 加了前言后语(违反 prompt 要求,但需要健壮处理)。"""
    text = '好的,以下是分析结果:\n{"a": 1}\n以上就是全部内容。'
    parsed = parse_llm_json(text)
    assert parsed == {"a": 1}


def test_parse_json_rejects_non_json():
    """纯文本(无 JSON)→ ValueError。"""
    with pytest.raises(ValueError, match="非合法 JSON"):
        parse_llm_json("这是纯文本,没有 JSON")


def test_parse_json_rejects_array_top_level():
    """顶层是 array(非 dict)→ ValueError。"""
    with pytest.raises(ValueError, match="顶层非 object"):
        parse_llm_json('[1, 2, 3]')


def test_parse_json_rejects_truncated():
    """截断的 JSON → ValueError。"""
    with pytest.raises(ValueError, match="非合法 JSON"):
        parse_llm_json('{"a": ')


def test_parse_json_with_nested_object_and_surrounding_text():
    """前言后语 + 嵌套对象:rfind('}') 取最外层,正常解析。"""
    text = '好的,以下是分析:{\"a\": {\"b\": 1}, \"c\": [1, 2]}结束'
    parsed = parse_llm_json(text)
    assert parsed == {"a": {"b": 1}, "c": [1, 2]}


# ===== validate_v1_module_output =====


def test_m0_valid_output_no_failures():
    """M0 合规输出:全字段 + fingerprint ≤ 40 字 → 0 failures。"""
    parsed = {
        "main_axis": {"dominant": "伤官"},
        "core_loop": {"from": "伤官", "to": "财"},
        "structure_type": {"name": "伤官生财", "one_line": "..."},
        "capability_source": {"text": "...", "evidence": "..."},
        "structure_fingerprint": "伤官生财驱动,外显创造力",  # ≤ 40 字
    }
    assert validate_v1_module_output("m0_structure", parsed) == []


def test_m0_fingerprint_too_long_returns_failure():
    """M0 structure_fingerprint > 40 字 → failure。"""
    parsed = {
        "main_axis": {}, "core_loop": {}, "structure_type": {},
        "capability_source": {},
        "structure_fingerprint": "一" * 41,  # 41 字
    }
    failures = validate_v1_module_output("m0_structure", parsed)
    assert any("structure_fingerprint" in f for f in failures)


def test_m0_missing_fields_returns_failure():
    """M0 缺 main_axis → failure。"""
    parsed = {
        "core_loop": {}, "structure_type": {},
        "capability_source": {}, "structure_fingerprint": "fp",
    }
    failures = validate_v1_module_output("m0_structure", parsed)
    assert any("main_axis" in f for f in failures)


def test_m0_fingerprint_non_str_returns_failure():
    """M0 structure_fingerprint 非 str(int / list / None)→ failure。"""
    for bad_fp in [123, ["a", "b"], None, {"x": 1}]:
        parsed = {
            "main_axis": {}, "core_loop": {}, "structure_type": {},
            "capability_source": {}, "structure_fingerprint": bad_fp,
        }
        failures = validate_v1_module_output("m0_structure", parsed)
        assert any("structure_fingerprint" in f for f in failures), (
            f"fp={bad_fp!r} 应被拒绝"
        )


def test_m4_array_length_violations():
    """M4 数组长度约束:imbalance_risks 必须 3 条 / reset_7day 必须 7 条。"""
    parsed = {
        "battery_type": {}, "imbalance_risks": ["only_one"],  # 应 3
        "recovery_levers": ["a", "b", "c"],
        "reset_7day": ["d1", "d2", "d3"],  # 应 7
        "weekly_maintenance": [], "medical_note": "建议",
    }
    failures = validate_v1_module_output("m4_health", parsed)
    assert any("imbalance_risks" in f for f in failures)
    assert any("reset_7day" in f for f in failures)


def test_m5_six_income_forms_required():
    """M5 income_forms 必须 6 条(rank 1-6)。"""
    parsed = {
        "income_forms": [{"form": "工资", "rank": 1}],  # 应 6
        "leaks": [], "strategies": {},
        "asset_ideas": ["a", "b", "c"], "disclaimer": "x",
    }
    failures = validate_v1_module_output("m5_wealth", parsed)
    assert any("income_forms" in f for f in failures)


def test_m7_strict_counts():
    """M7 use_cases 必须 3 / falsification_signals 必须 2。"""
    parsed = {
        "true_leverage": {}, "use_cases": ["only_one"],
        "next_90_days": {},
        "falsification_signals": ["only_one"],
    }
    failures = validate_v1_module_output("m7_manual", parsed)
    assert any("use_cases" in f for f in failures)
    assert any("falsification_signals" in f for f in failures)


def test_array_field_non_list_returns_failure():
    """数组字段是 string / None / int → failure(而非静默跳过长度校验)。"""
    parsed = {
        "battery_type": {},
        "imbalance_risks": "not a list",  # string
        "recovery_levers": None,           # None
        "reset_7day": 3,                   # int
        "weekly_maintenance": [],
        "medical_note": "ok",
    }
    failures = validate_v1_module_output("m4_health", parsed)
    assert any("imbalance_risks" in f and "非 list" in f for f in failures)
    assert any("recovery_levers" in f and "非 list" in f for f in failures)
    assert any("reset_7day" in f and "非 list" in f for f in failures)


def test_forbidden_words_in_output_returns_failure():
    """LLM 输出含禁词(注定/必然/破财)→ failure。"""
    parsed = {
        "main_axis": {}, "core_loop": {}, "structure_type": {},
        "capability_source": {},
        "structure_fingerprint": "注定要破财的命",
    }
    failures = validate_v1_module_output("m0_structure", parsed)
    assert any("禁词" in f for f in failures)


def test_extended_forbidden_words_caught():
    """v1.md §4 扩展禁词(寿元/绝症/必赚/稳赚/包治)也被拦截。"""
    # 用 m4_health 测(medical_note 是 M4 字段,扩展禁词多在医疗/财富语境)
    parsed_m4 = {
        "battery_type": {}, "imbalance_risks": [], "recovery_levers": [],
        "reset_7day": [], "weekly_maintenance": [],
        "medical_note": "包治百病",
    }
    failures = validate_v1_module_output("m4_health", parsed_m4)
    assert any("禁词" in f for f in failures)


def test_unknown_module_returns_empty_failures():
    """未知 module(没在 _MODULE_REQUIRED_FIELDS)→ 不报 failure(默认宽容)。

    设计权衡:spike 工具链对新加 module 宽容,避免 spike 脚本因新 module
    没更新校验表而全盘失败。
    """
    parsed = {"anything": "ok"}
    assert validate_v1_module_output("m99_unknown", parsed) == []


# ===== _run_one_module 返回值契约(回归 P0 bug:status dict 必须含 parsed) =====


def test_run_one_module_status_dict_has_parsed_key():
    """_run_one_module 返回的 status dict 必须含 parsed 字段。

    回归:此前 _run_one_module 只返回 has_parsed(布尔),run_chain_for_case
    却查 status["parsed"] / status.get("parsed"),real API 模式链路 broken
    (dry-run 不触发,无人发现)。
    """
    import asyncio
    from pathlib import Path
    from tempfile import TemporaryDirectory

    from spikes.prompt_validation.run_v1_chain_spike import _run_one_module

    class _StubClient:
        provider = "stub"
        model = "stub-model"

        async def interpret(self, prompt: str, *, temperature: float = 0.0) -> str:
            # 返回 M0 合规 JSON
            return '{"main_axis": {}, "core_loop": {}, "structure_type": {}, "capability_source": {}, "structure_fingerprint": "合规指纹"}'

    with TemporaryDirectory() as tmp:
        case_dir = Path(tmp) / "case_xx"
        case_dir.mkdir()

        status = asyncio.run(_run_one_module(
            module="m0_structure",
            context={"chart": "{}"},
            case_dir=case_dir,
            ai_client=_StubClient(),
            dry_run=False,
        ))

    # 关键断言:status 必须含 parsed 字段(run_chain_for_case 依赖它)
    assert "parsed" in status, (
        "status dict 缺 parsed 字段,run_chain_for_case 的链式注入会失败"
    )
    assert isinstance(status["parsed"], dict)
    assert status["parsed"]["structure_fingerprint"] == "合规指纹"
    assert status["ok"] is True
