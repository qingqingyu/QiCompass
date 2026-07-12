"""ai/prompts.py 渲染测试(纯单元测试,不调 API)。

验收用例(最终方案 §10):
3. test_three_modules_render:三 module 各自 context → render_prompt 输出含预期占位符值
4. test_special_pattern_honest_degradation:special_pattern → prompt 含诚实降级约束文本
"""

from __future__ import annotations

import pytest

from app.ai.prompts import (
    BAZI_DEEP_SPECIAL_PATTERN_SUFFIX,
    REQUIRED_FIELDS,
    render_prompt,
    validate_context,
)
from app.errors import InvalidInputError
from tests.fixtures.interpret_cases import (
    BAZI_DEEP_CONTEXT,
    BAZI_DEEP_SPECIAL_PATTERN_CONTEXT,
    COMPATIBILITY_CONTEXT,
    DAILY_FORTUNE_CONTEXT,
)


# ===== 3. 三 module 渲染 =====


def test_bazi_deep_render_replaces_placeholders():
    """bazi_deep context → render_prompt 输出含预期占位符值(非 {xxx} 残留)。"""
    prompt = render_prompt("bazi_deep", BAZI_DEEP_CONTEXT)
    # 关键字段已替换
    assert BAZI_DEEP_CONTEXT["gender"] in prompt
    assert BAZI_DEEP_CONTEXT["city"] in prompt
    assert BAZI_DEEP_CONTEXT["true_solar_time"] in prompt
    assert BAZI_DEEP_CONTEXT["year_gan"] in prompt
    assert BAZI_DEEP_CONTEXT["day_gan_element"] in prompt
    assert BAZI_DEEP_CONTEXT["favorable_elements"] in prompt
    assert BAZI_DEEP_CONTEXT["unfavorable_elements"] in prompt
    assert BAZI_DEEP_CONTEXT["shensha_list"] in prompt
    assert BAZI_DEEP_CONTEXT["current_luck_pillar"] in prompt
    # 无未填充占位符残留
    assert "{" not in prompt, f"prompt 中仍有未填充占位符: {prompt}"


def test_compatibility_render_replaces_placeholders():
    """compatibility context → render_prompt 输出含预期占位符值。"""
    prompt = render_prompt("compatibility", COMPATIBILITY_CONTEXT)
    assert COMPATIBILITY_CONTEXT["context_label"] in prompt
    assert COMPATIBILITY_CONTEXT["gender_a"] in prompt
    assert COMPATIBILITY_CONTEXT["day_master_a"] in prompt
    assert COMPATIBILITY_CONTEXT["five_elements_assessment"] in prompt
    assert COMPATIBILITY_CONTEXT["day_master_relation"] in prompt
    assert COMPATIBILITY_CONTEXT["zodiac_match"] in prompt
    assert COMPATIBILITY_CONTEXT["branch_harmony"] in prompt
    assert COMPATIBILITY_CONTEXT["synced_fortune_table"] in prompt
    assert "{" not in prompt, f"prompt 中仍有未填充占位符: {prompt}"


def test_daily_fortune_render_replaces_placeholders():
    """daily_fortune context → render_prompt 输出含预期占位符值。"""
    prompt = render_prompt("daily_fortune", DAILY_FORTUNE_CONTEXT)
    assert DAILY_FORTUNE_CONTEXT["day_master"] in prompt
    assert DAILY_FORTUNE_CONTEXT["day_master_element"] in prompt
    assert DAILY_FORTUNE_CONTEXT["date"] in prompt
    assert DAILY_FORTUNE_CONTEXT["lunar_date"] in prompt
    assert DAILY_FORTUNE_CONTEXT["day_pillar"] in prompt
    assert DAILY_FORTUNE_CONTEXT["day_relation"] in prompt
    assert DAILY_FORTUNE_CONTEXT["day_chong"] in prompt
    assert DAILY_FORTUNE_CONTEXT["hour_pillars_with_relations"] in prompt
    assert DAILY_FORTUNE_CONTEXT["huangli_yi"] in prompt
    assert DAILY_FORTUNE_CONTEXT["huangli_ji"] in prompt
    assert "{" not in prompt, f"prompt 中仍有未填充占位符: {prompt}"


def test_three_modules_all_fields_required():
    """三 module 的 REQUIRED_FIELDS 非空且互不重叠(确保各模板独立校验)。"""
    assert set(REQUIRED_FIELDS.keys()) == {"bazi_deep", "compatibility", "daily_fortune"}
    for module, fields in REQUIRED_FIELDS.items():
        assert fields, f"{module} REQUIRED_FIELDS 不应为空"
    # 确认部分 module 特有字段
    assert "shensha_list" in REQUIRED_FIELDS["bazi_deep"]
    assert "context_label" in REQUIRED_FIELDS["compatibility"]
    assert "hour_pillars_with_relations" in REQUIRED_FIELDS["daily_fortune"]


# ===== 4. 从格诚实降级 =====


def test_special_pattern_honest_degradation():
    """day_master_strength="special_pattern" → prompt 含诚实降级约束文本。"""
    prompt = render_prompt("bazi_deep", BAZI_DEEP_SPECIAL_PATTERN_CONTEXT)
    # 降级约束段已追加
    assert "从格特征" in prompt
    assert "未下硬性喜忌结论" in prompt
    assert "避免编造扶抑法喜忌" in prompt
    # 降级段确实是 BAZI_DEEP_SPECIAL_PATTERN_SUFFIX
    assert BAZI_DEEP_SPECIAL_PATTERN_SUFFIX.strip() in prompt


def test_normal_pattern_no_degradation_suffix():
    """普通盘(day_master_strength != special_pattern)→ prompt 不含降级约束段。"""
    prompt = render_prompt("bazi_deep", BAZI_DEEP_CONTEXT)
    assert BAZI_DEEP_CONTEXT["day_master_strength"] == "weak"
    assert "从格特征" not in prompt
    assert BAZI_DEEP_SPECIAL_PATTERN_SUFFIX.strip() not in prompt


def test_special_pattern_only_for_bazi_deep():
    """降级段只对 bazi_deep 追加;compatibility/daily_fortune 不受影响。"""
    # compatibility 不会追加(其 context 里没有 day_master_strength 作为降级触发)
    prompt_c = render_prompt("compatibility", COMPATIBILITY_CONTEXT)
    assert "从格特征" not in prompt_c

    prompt_d = render_prompt("daily_fortune", DAILY_FORTUNE_CONTEXT)
    assert "从格特征" not in prompt_d


# ===== validate_context 单元测试 =====


def test_validate_context_missing_field_raises_invalid_input():
    """缺字段 → InvalidInputError,message 含缺失字段名列表。"""
    incomplete = {k: v for k, v in BAZI_DEEP_CONTEXT.items()
                  if k not in ("favorable_elements", "shensha_list")}
    with pytest.raises(InvalidInputError) as exc_info:
        validate_context("bazi_deep", incomplete)
    msg = str(exc_info.value)
    assert "favorable_elements" in msg
    assert "shensha_list" in msg


def test_validate_context_unknown_module_raises_value_error():
    """module 未注册 → ValueError(代码 bug,非用户错误)。"""
    with pytest.raises(ValueError, match="未知 module"):
        validate_context("nonexistent_module", {})


def test_validate_context_all_fields_present_passes():
    """字段齐全 → 不抛异常。"""
    validate_context("bazi_deep", BAZI_DEEP_CONTEXT)  # 不抛即通过
    validate_context("compatibility", COMPATIBILITY_CONTEXT)
    validate_context("daily_fortune", DAILY_FORTUNE_CONTEXT)


def test_validate_context_non_scalar_value_raises_invalid_input():
    """值类型为 list/dict(非标量)→ InvalidInputError(str.format_map 会污染 prompt)。"""
    bad_context = {**BAZI_DEEP_CONTEXT, "gender": ["男", "female"]}
    with pytest.raises(InvalidInputError, match="类型非法"):
        validate_context("bazi_deep", bad_context)


def test_validate_context_scalar_types_accepted():
    """标量类型(str/int/float/bool)均应通过校验。"""
    mixed = {**BAZI_DEEP_CONTEXT, "tiaoshou_applied": True, "favorable_elements": "火"}
    validate_context("bazi_deep", mixed)  # 不抛即通过
