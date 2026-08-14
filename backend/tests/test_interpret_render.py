"""ai/prompts.py 渲染测试(纯单元测试,不调 API)。

验收用例(最终方案 §10):
3. test_three_modules_render:三 module 各自 context → render_prompt 输出含预期占位符值
4. test_special_pattern_honest_degradation:special_pattern → prompt 含诚实降级约束文本
"""

from __future__ import annotations

import re

import pytest

from app.ai.prompts import (
    BAZI_DEEP_SPECIAL_PATTERN_SUFFIX,
    PROMPT_VERSIONS,
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
    """十五 module(老 7 + v1 8)的 REQUIRED_FIELDS 非空;bazi_deep / compatibility 系列(alias/_free/_paid)各共享字段清单。"""
    assert set(REQUIRED_FIELDS.keys()) == {
        # 老 module
        "bazi_deep", "bazi_deep_free", "bazi_deep_paid",
        "compatibility", "compatibility_free", "compatibility_paid",
        "daily_fortune",
        # v1 prompt 系统(Stage 5 落地)
        "m0_structure", "m1_talent", "m2_high_low", "m3_system",
        "m4_health", "m5_wealth", "m6_dynamics", "m7_manual",
    }
    for module, fields in REQUIRED_FIELDS.items():
        assert fields, f"{module} REQUIRED_FIELDS 不应为空"
    # 确认部分 module 特有字段
    assert "shensha_list" in REQUIRED_FIELDS["bazi_deep"]
    assert "context_label" in REQUIRED_FIELDS["compatibility"]
    assert "hour_pillars_with_relations" in REQUIRED_FIELDS["daily_fortune"]
    # M2 拆分:bazi_deep / _free / _paid 共用同一份字段清单(共享 header)
    assert REQUIRED_FIELDS["bazi_deep"] is REQUIRED_FIELDS["bazi_deep_free"]
    assert REQUIRED_FIELDS["bazi_deep"] is REQUIRED_FIELDS["bazi_deep_paid"]
    # M4 拆分:compatibility / _free / _paid 共用同一份字段清单(共享 header)
    assert REQUIRED_FIELDS["compatibility"] is REQUIRED_FIELDS["compatibility_free"]
    assert REQUIRED_FIELDS["compatibility"] is REQUIRED_FIELDS["compatibility_paid"]
    # v1 module 特有字段断言
    assert REQUIRED_FIELDS["m0_structure"] == ["chart"], "M0 只需 chart"
    assert "structure_fingerprint" in REQUIRED_FIELDS["m1_talent"]
    assert "current_concern" in REQUIRED_FIELDS["m4_health"], (
        "M4 context 含 current_concern(对齐模板占位符)")
    assert "age" in REQUIRED_FIELDS["m4_health"]
    assert "assets_summary" in REQUIRED_FIELDS["m5_wealth"]
    assert "chart" not in REQUIRED_FIELDS["m7_manual"], "M7 不需 chart(基于 M1-M6 结论)"


def test_bazi_deep_free_render_replaces_placeholders():
    """bazi_deep_free context → render 输出含 header 占位符值 + 免费章节写作要求。"""
    prompt = render_prompt("bazi_deep_free", BAZI_DEEP_CONTEXT)
    # header 字段已替换(共享同 bazi_deep)
    assert BAZI_DEEP_CONTEXT["gender"] in prompt
    assert BAZI_DEEP_CONTEXT["shensha_list"] in prompt
    # 免费章节写作要求存在(MONETIZATION.md §免费内容分界)
    assert "性格底色" in prompt
    assert "事业方向" in prompt
    assert "免费 2 章" in prompt
    # 不应包含付费章节关键词
    assert "财运" not in prompt
    assert "爱情" not in prompt
    assert "{" not in prompt


def test_bazi_deep_paid_render_replaces_placeholders():
    """bazi_deep_paid context → render 输出含 header 占位符值 + 付费 5 章写作要求。"""
    prompt = render_prompt("bazi_deep_paid", BAZI_DEEP_CONTEXT)
    # header 字段已替换
    assert BAZI_DEEP_CONTEXT["gender"] in prompt
    assert BAZI_DEEP_CONTEXT["shensha_list"] in prompt
    # 付费章节写作要求存在(MONETIZATION.md §付费章节)
    assert "财运" in prompt
    assert "爱情" in prompt
    assert "健康" in prompt
    assert "六亲" in prompt
    assert "晚年" in prompt
    assert "付费 5 章" in prompt
    assert "{" not in prompt


def test_bazi_deep_alias_still_works():
    """决策 B:bazi_deep alias 仍可用,渲染老的 300-500 字综合版本(向后兼容)。"""
    prompt = render_prompt("bazi_deep", BAZI_DEEP_CONTEXT)
    # 老模板的写作要求存在
    assert "300-500" in prompt
    # 不含 M2 新加的章节关键词
    assert "免费 2 章" not in prompt
    assert "付费 5 章" not in prompt


def test_compatibility_free_render_replaces_placeholders():
    """compatibility_free context → render 输出含 header 占位符值 + 免费 2 章写作要求。"""
    prompt = render_prompt("compatibility_free", COMPATIBILITY_CONTEXT)
    # header 字段已替换(共享同 compatibility)
    assert COMPATIBILITY_CONTEXT["context_label"] in prompt
    assert COMPATIBILITY_CONTEXT["gender_a"] in prompt
    assert COMPATIBILITY_CONTEXT["day_master_a"] in prompt
    assert COMPATIBILITY_CONTEXT["five_elements_assessment"] in prompt
    assert COMPATIBILITY_CONTEXT["synced_fortune_table"] in prompt
    # 免费 2 章写作要求存在(MONETIZATION.md §合盘 §免费/付费内容分界)
    assert "基础相处模式" in prompt
    assert "互补与冲突总览" in prompt
    assert "免费 2 章" in prompt
    # 不应包含付费章节关键词(S1:爱情深度已全局替换为五行共振,两者都不得泄漏到免费)
    assert "五行共振" not in prompt
    assert "爱情深度" not in prompt
    assert "合作事业" not in prompt
    assert "{" not in prompt


def test_compatibility_paid_render_replaces_placeholders():
    """compatibility_paid context → render 输出含 header 占位符值 + 付费 4 章写作要求。"""
    prompt = render_prompt("compatibility_paid", COMPATIBILITY_CONTEXT)
    # header 字段已替换
    assert COMPATIBILITY_CONTEXT["context_label"] in prompt
    assert COMPATIBILITY_CONTEXT["day_master_a"] in prompt
    # 付费 4 章写作要求存在(S1:第一章已替换为五行共振)
    assert "五行共振" in prompt
    # 五行共振章内容要素(决策 §Q4:机制 + 互动体现 + 护栏句)
    assert "补喜神" in prompt
    assert "日主生克" in prompt
    assert "不预设关系类型" in prompt
    assert "爱情深度" not in prompt
    assert "合作事业" in prompt
    assert "财运合拍" in prompt
    assert "流年同步" in prompt
    assert "付费 4 章" in prompt
    # 不应包含免费章节关键词作为章节标题(免费段已拆走)
    assert "免费 2 章" not in prompt
    assert "{" not in prompt


def test_compatibility_alias_still_works():
    """M4:compatibility alias 仍可用,渲染老的 6 章综合版本(向后兼容)。"""
    prompt = render_prompt("compatibility", COMPATIBILITY_CONTEXT)
    # 老模板的 6 章写作要求存在
    assert "6 章" in prompt
    assert "基础相处模式" in prompt
    assert "流年同步" in prompt
    # S1:第三章已替换为五行共振(决策 §Q3/§Q4)
    assert "五行共振" in prompt
    assert "不预设关系类型" in prompt
    assert "爱情深度" not in prompt
    # 不含 M4 新加的拆分关键词
    assert "免费 2 章" not in prompt
    assert "付费 4 章" not in prompt


def test_compatibility_global_guardrail_in_all_three_templates():
    """S2 全局护栏(决策 §Q5):3 个合盘 module 的通用要求首项均为
    「叙事用『两人』而非关系预设词;不预设关系类型」。"""
    for module in ("compatibility", "compatibility_free", "compatibility_paid"):
        prompt = render_prompt(module, COMPATIBILITY_CONTEXT)
        assert "不预设关系类型（婚恋/友谊/合作/亲情）" in prompt, f"{module} 缺全局护栏句"
        assert "情侣/夫妻/朋友/合伙人" in prompt, f"{module} 缺「两人」叙事约束"
        # S2 验收标准:护栏句位于通用要求段首项(挪到中部会弱化 LLM 注意力,测试必须锁位置)
        assert "通用要求：\n- 叙事用「两人」而非" in prompt, f"{module} 护栏句不在通用要求首项"


def test_compatibility_local_guardrails_two_high_risk_chapters():
    """S3 局部护栏(决策 §Q5):仅 2 个高风险章节加针对性护栏——
    免费「基础相处模式」(防同居/伴侣场景预设) + paid/alias「合作事业」
    (公共目标协作涵盖多种关系);其余章节不加(避免过度工程)。"""
    # 免费模板:基础相处模式局部护栏
    free_prompt = render_prompt("compatibility_free", COMPATIBILITY_CONTEXT)
    assert "不写同居/伴侣等具体生活场景预设" in free_prompt, "free 基础相处模式缺局部护栏"

    # paid + alias:合作事业局部护栏
    for module in ("compatibility_paid", "compatibility"):
        prompt = render_prompt(module, COMPATIBILITY_CONTEXT)
        assert "涵盖夫妻共业/朋友共谋/合伙人共事" in prompt, f"{module} 合作事业缺局部护栏"

    # 中低风险章节不加局部护栏(互补冲突/财运合拍/流年同步/五行共振无额外护栏句)。
    # 计数断言锁「只加指定章节」:多一处/漏一处都红。
    paid_prompt = render_prompt("compatibility_paid", COMPATIBILITY_CONTEXT)
    alias_prompt = render_prompt("compatibility", COMPATIBILITY_CONTEXT)
    assert paid_prompt.count("不写具体关系预设") == 1, "paid 只应有合作事业一处「不写具体关系预设」"
    assert alias_prompt.count("不写具体关系预设") == 1, "alias 只应有合作事业一处「不写具体关系预设」"
    assert free_prompt.count("不写具体关系预设") == 0, "free 无合作事业章,不应出现该护栏句式"
    assert free_prompt.count("不写同居/伴侣等具体生活场景预设") == 1, "free 基础相处模式护栏只应一处"
    assert alias_prompt.count("不写同居/伴侣等具体生活场景预设") == 0, "alias 基础相处模式按 §Q5 不加局部护栏"


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


def test_special_pattern_only_for_bazi_deep_series():
    """降级段对 bazi_deep 系列(alias/_free/_paid)追加;compatibility/daily_fortune 不受影响。"""
    # 三个 bazi_deep 系列 module 都追加
    for module in ("bazi_deep", "bazi_deep_free", "bazi_deep_paid"):
        prompt = render_prompt(module, BAZI_DEEP_SPECIAL_PATTERN_CONTEXT)
        assert "从格特征" in prompt, f"{module} 应追加从格降级段"
        assert BAZI_DEEP_SPECIAL_PATTERN_SUFFIX.strip() in prompt

    # compatibility / daily_fortune 不追加
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


# ===== v1 prompt 系统(Stage 5):M0-M7 模板渲染 =====


# 全局 System Prompt 必须含的关键短语(任何 v1 模板渲染后都应包含)
_V1_SYSTEM_PROMPT_MARKERS = (
    "命理结构分析师",
    "命是底盘，运是时机",
    "禁止",
    "严格按要求的 JSON 输出",
)


def _v1_chart_json() -> str:
    """v1 chart JSON 字符串(对齐 v1 §1 schema 简化版,标量 str 即可)。"""
    return (
        '{"meta":{"locale":"zh-CN","gender":"female",'
        '"solar_term_boundary":"雨水后"},'
        '"pillars":{"year":{"stem":"庚","branch":"午"}},'
        '"day_master":{"stem":"己","element":"土","strength_label":"中和"},'
        '"ten_god_weights":{"比肩":8,"劫财":22}}'
    )


def test_v1_m0_renders_with_chart_only():
    """M0 只需 chart context,渲染后含 _V1_SYSTEM_PROMPT + chart JSON。"""
    prompt = render_prompt("m0_structure", {"chart": _v1_chart_json()})
    # 全局 system prompt 关键短语
    for marker in _V1_SYSTEM_PROMPT_MARKERS:
        assert marker in prompt, f"M0 prompt 缺 SYSTEM_PROMPT 关键短语 {marker!r}"
    # chart JSON 已注入(用 chart 特有字段名断言,避免 system prompt 里的"自己"误通过)
    assert "雨水后" in prompt
    assert '"stem":"己"' in prompt
    # M0 模块标识
    assert "M0" in prompt or "主线结构" in prompt
    # 输出 JSON schema 在 prompt 里(双花括号 escape 后应还原为单花括号)
    assert '"structure_fingerprint"' in prompt
    # 无未填充占位符(通用检查:不含任何 {word} 形式的单花括号残留)
    leftover = re.findall(r'(?<!\{)\{[a-z_][a-z0-9_]*\}(?!\})', prompt)
    assert not leftover, f"M0 prompt 中仍有未填充占位符: {leftover}"


def test_v1_m1_renders_with_chain_inputs():
    """M1 需 chart + structure_fingerprint + main_axis + core_loop。"""
    ctx = {
        "chart": _v1_chart_json(),
        "structure_fingerprint": "伤官生财循环,外显执行力",
        "main_axis": '{"dominant":"伤官","secondary":"财"}',
        "core_loop": '{"from":"伤官","to":"财"}',
    }
    prompt = render_prompt("m1_talent", ctx)
    assert "伤官生财循环" in prompt
    assert '"dominant":"伤官"' in prompt
    assert "innate" in prompt
    assert "one_leverage" in prompt
    # 无未填充占位符(与 M0/M2-M6 同标准检查)
    leftover = re.findall(r'(?<!\{)\{[a-z_][a-z0-9_]*\}(?!\})', prompt)
    assert not leftover, f"M1 prompt 中仍有未填充占位符: {leftover}"
    # M1 追加了 _V1_LENGTH_HINT_LONG(篇幅约束 1500-2500 字)
    assert "1500-2500" in prompt, "M1 应含篇幅约束(加长版)"


def test_v1_m2_to_m6_render_with_chain_inputs():
    """M2-M6 各自的链式注入字段都能渲染(无未填充占位符)。"""
    # 每 module 的"输出 JSON schema 标志字段"(验证双花括号 escape 已正确还原)
    expected_json_markers = {
        "m2_high_low": '"threshold"',
        "m3_system": '"operating_mode"',
        "m4_health": '"battery_type"',
        "m5_wealth": '"income_forms"',
        "m6_dynamics": '"energy_path"',
    }
    test_cases = [
        ("m2_high_low", {
            "chart": _v1_chart_json(), "structure_fingerprint": "fp",
            "innate": '[{"name":"创造力"}]', "defensive": '[{"name":"讨好"}]',
        }),
        ("m3_system", {
            "chart": _v1_chart_json(), "structure_fingerprint": "fp",
        }),
        ("m4_health", {
            "chart": _v1_chart_json(), "structure_fingerprint": "fp",
            "age": 30, "current_concern": "睡眠不好",
        }),
        ("m5_wealth", {
            "chart": _v1_chart_json(), "structure_fingerprint": "fp",
            "innate": '[{"name":"创造力"}]',
            "ideal_life_structure": '{"time":"灵活"}',
            "assets_summary": "中等收入", "preference": "平衡",
        }),
        ("m6_dynamics", {
            "chart": _v1_chart_json(), "structure_fingerprint": "fp",
            "core_loop": '{"from":"伤官","to":"财"}',
            "innate": '[{"name":"创造力"}]', "defensive": '[{"name":"讨好"}]',
            "threshold": '{"environment":{"enables":"自主权"}}',
        }),
    ]
    for module, ctx in test_cases:
        prompt = render_prompt(module, ctx)
        marker = expected_json_markers[module]
        assert marker in prompt, (
            f"{module} 渲染后应含 JSON schema marker {marker!r},"
            f"实际:{prompt[:300]}"
        )
        # 无未填充 context 占位符(通用检查:不含任何 {word} 形式的单花括号残留)
        leftover = re.findall(r'(?<!\{)\{[a-z_][a-z0-9_]*\}(?!\})', prompt)
        assert not leftover, f"{module} prompt 中仍有未填充占位符: {leftover}"


def test_v1_m7_renders_without_chart():
    """M7 不需要 chart(基于 M1-M6 结论的总结)。"""
    ctx = {
        "one_leverage": "伤官生财",
        "switch_actions": '["减少讨好"]',
        "environment_checklist": '["是否需要自主权"]',
        "leverage": '{"point":"伤官"}',
    }
    prompt = render_prompt("m7_manual", ctx)
    assert "伤官生财" in prompt
    assert "90 天" in prompt or "90天" in prompt
    # M7 模板不含 {chart} 占位符,渲染后也不应出现 chart JSON 数据
    assert "{chart}" not in prompt
    assert '"pillars"' not in prompt, "M7 不应含 chart 数据(pillars 字段)"


def test_v1_m4_accepts_int_age():
    """M4 age 字段可以是 int(validate_context 允许标量)。"""
    ctx = {
        "chart": _v1_chart_json(),
        "structure_fingerprint": "fp",
        "age": 35,  # int
        "current_concern": "焦虑",
    }
    prompt = render_prompt("m4_health", ctx)
    assert "35" in prompt


def test_v1_m0_missing_chart_returns_invalid_input_error():
    """M0 缺 chart 字段 → InvalidInputError(422)。"""
    with pytest.raises(InvalidInputError, match="缺字段"):
        render_prompt("m0_structure", {})  # 缺 chart


def test_v1_m1_missing_chain_field_returns_invalid_input_error():
    """M1 缺 main_axis → InvalidInputError(422)。"""
    ctx = {
        "chart": _v1_chart_json(),
        "structure_fingerprint": "fp",
        # 故意缺 main_axis / core_loop
    }
    with pytest.raises(InvalidInputError, match="缺字段"):
        render_prompt("m1_talent", ctx)


def test_v1_m0_rejects_non_scalar_chart():
    """v1 module 仍要求标量 context(dict 类型 chart 应被拒)。"""
    bad_ctx = {"chart": {"meta": "not a string"}}  # dict 不是标量
    with pytest.raises(InvalidInputError, match="类型非法"):
        render_prompt("m0_structure", bad_ctx)


def test_v1_prompt_versions_registered():
    """所有 m0-m7 必须在 PROMPT_VERSIONS 注册(Stage 5 落地后)。"""
    for module in (
        "m0_structure", "m1_talent", "m2_high_low", "m3_system",
        "m4_health", "m5_wealth", "m6_dynamics", "m7_manual",
    ):
        assert module in PROMPT_VERSIONS, (
            f"{module} 必须在 PROMPT_VERSIONS 注册"
        )
        assert isinstance(PROMPT_VERSIONS[module], int)
        assert PROMPT_VERSIONS[module] >= 1
