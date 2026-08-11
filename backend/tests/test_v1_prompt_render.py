"""v1 prompt 系统 M0-M7 模板渲染测试 + chart_builder 测试。

覆盖范围(Stage 5C):
1. M0-M7 各自 render_prompt 基本路径
2. M0-M7 必填字段缺失 → InvalidInputError
3. _V1_SYSTEM_PROMPT 前缀拼接(所有 v1 模块以"你是一位命理结构分析师"开头)
4. chart 字段是 JSON 字符串(含 ensure_ascii=False)
5. 链式注入字段(structure_fingerprint 等)是 JSON 字符串
6. PROMPT_VERSIONS 8 个新 entry 全部 = 1
7. 篇幅约束(M1/M2/M3/M5/M7 含"1500-2500 字"提示,M0/M4/M6 不含)
8. chart_builder.build_v1_chart() 基本路径 + 从格降级
9. v1 模板无未填充占位符残留(无 { 残留)
"""

from __future__ import annotations

import json
from copy import deepcopy

import pytest

from app.ai.prompts import (
    M0_STRUCTURE_TEMPLATE,
    M1_TALENT_TEMPLATE,
    M2_HIGH_LOW_TEMPLATE,
    M3_SYSTEM_TEMPLATE,
    M4_HEALTH_TEMPLATE,
    M5_WEALTH_TEMPLATE,
    M6_DYNAMICS_TEMPLATE,
    M7_MANUAL_TEMPLATE,
    PROMPT_VERSIONS,
    REQUIRED_FIELDS,
    render_prompt,
)
from app.engine.chart_builder import build_v1_chart
from app.errors import InvalidInputError


# ===== Fixtures =====

# 设计文档 §1 chart schema 示例(chart_builder 输出形状)
_CHART_DICT = {
    "meta": {
        "locale": "zh-CN",
        "gender": "female",
        "birth_local": "1990-03-05T07:20:00+09:00",
        "true_solar_time": "1990-03-05T06:52:00",
        "late_zishi_rule": "day_change_at_23",
        "solar_term_boundary": "惊蛰后",
    },
    "pillars": {"year": {"gan": "庚", "zhi": "午"}},
    "day_master": {"stem": "甲", "element": "木",
                    "strength_score": None, "strength_label": "偏弱"},
    "ten_gods": {"year_stem": "七杀", "month_stem": "正财", "hour_stem": "伤官"},
    "ten_god_weights": {"比肩": 0, "劫财": 3},
    "five_elements": {"木": 2, "火": 2, "土": 1, "金": 1, "水": 2},
    "useful_god_candidates": ["火", "土"],
    "luck_pillars": [{"start_age": 7, "stem": "戊", "branch": "寅"}],
    "current_luck": {"start_age": 27, "stem": "丙", "branch": "子",
                     "ten_god": None},
    "current_year": {"stem": "丙", "branch": "午", "ten_god": None},
}

# chart 占位符值 = JSON 字符串(对齐 plan 决策)
CHART_JSON = json.dumps(_CHART_DICT, ensure_ascii=False, indent=2)

# 链式注入字段(M0-M6 各自输出的 JSON 字符串,作为下一级 M 的 context 字段)
_MAIN_AXIS_JSON = json.dumps(
    {"dominant": "劫财", "secondary": "伤官", "latent": "正印"},
    ensure_ascii=False,
)
_CORE_LOOP_JSON = json.dumps(
    {"from": "劫财", "to": "伤官", "flow": "劫→伤"}, ensure_ascii=False,
)
_INNATE_JSON = json.dumps(
    [{"name": "决断力", "behavior": "快速决策", "energy": "gain"}],
    ensure_ascii=False,
)
_DEFENSIVE_JSON = json.dumps(
    [{"name": "过度负责", "looks_like": "总揽全局", "actual_cost": "耗能"}],
    ensure_ascii=False,
)
_THRESHOLD_JSON = json.dumps(
    {"environment": {"enables": "自主权"}, "belief": {"limiting_belief": "我不够好"}},
    ensure_ascii=False,
)
_IDEAL_LIFE_JSON = json.dumps(
    {"time": "弹性", "collaboration": "低密度"}, ensure_ascii=False,
)
_ONE_LEVERAGE_JSON = json.dumps({"name": "决断力"}, ensure_ascii=False)
_SWITCH_ACTIONS_JSON = json.dumps(["早睡", "运动"], ensure_ascii=False)
_ENV_CHECKLIST_JSON = json.dumps(["q1", "q2", "q3"], ensure_ascii=False)
_LEVERAGE_JSON = json.dumps({"point": "结构层"}, ensure_ascii=False)

# 各 module 完整 context(必填字段全填)
_M0_CONTEXT = {"chart": CHART_JSON}
_M1_CONTEXT = {
    "chart": CHART_JSON,
    "structure_fingerprint": "劫财驱动型,行动先于思考",
    "main_axis": _MAIN_AXIS_JSON,
    "core_loop": _CORE_LOOP_JSON,
}
_M2_CONTEXT = {
    "chart": CHART_JSON,
    "structure_fingerprint": "fp",
    "innate": _INNATE_JSON,
    "defensive": _DEFENSIVE_JSON,
}
_M3_CONTEXT = {
    "chart": CHART_JSON,
    "structure_fingerprint": "fp",
}
_M4_CONTEXT = {
    "chart": CHART_JSON,
    "structure_fingerprint": "fp",
    "age": "30",
    "current_concern": "睡眠差",
}
_M5_CONTEXT = {
    "chart": CHART_JSON,
    "structure_fingerprint": "fp",
    "innate": _INNATE_JSON,
    "ideal_life_structure": _IDEAL_LIFE_JSON,
    "assets_summary": "年收入 30 万,无负债",
    "preference": "平衡",
}
_M6_CONTEXT = {
    "chart": CHART_JSON,
    "structure_fingerprint": "fp",
    "core_loop": _CORE_LOOP_JSON,
    "innate": _INNATE_JSON,
    "defensive": _DEFENSIVE_JSON,
    "threshold": _THRESHOLD_JSON,
}
_M7_CONTEXT = {
    "one_leverage": _ONE_LEVERAGE_JSON,
    "switch_actions": _SWITCH_ACTIONS_JSON,
    "environment_checklist": _ENV_CHECKLIST_JSON,
    "leverage": _LEVERAGE_JSON,
}

_V1_CONTEXTS = {
    "m0_structure": _M0_CONTEXT,
    "m1_talent": _M1_CONTEXT,
    "m2_high_low": _M2_CONTEXT,
    "m3_system": _M3_CONTEXT,
    "m4_health": _M4_CONTEXT,
    "m5_wealth": _M5_CONTEXT,
    "m6_dynamics": _M6_CONTEXT,
    "m7_manual": _M7_CONTEXT,
}

_V1_MODULES = sorted(_V1_CONTEXTS.keys())


# ===== 1. M0-M7 render 基本路径 =====

@pytest.mark.parametrize("module", _V1_MODULES)
def test_v1_module_render_returns_non_empty_string(module: str):
    """每个 v1 module 用完整 context 渲染,返回非空字符串。"""
    prompt = render_prompt(module, _V1_CONTEXTS[module])
    assert isinstance(prompt, str)
    assert len(prompt) > 500, f"{module} prompt 太短: {len(prompt)}"


@pytest.mark.parametrize("module", _V1_MODULES)
def test_v1_module_render_no_unfilled_placeholders(module: str):
    """渲染后无 {xxx} 残留占位符(说明 format_map 全部填上了)。"""
    prompt = render_prompt(module, _V1_CONTEXTS[module])
    # JSON schema 的大括号已转义为单 { } 输出,所以单 { 是合法的(JSON 结构)
    # 但 {xxx} 形式(单词占位符)不应该残留
    import re
    leftover = re.findall(r"\{[a-z_]+\}", prompt)
    assert not leftover, f"{module} 残留未填充占位符: {leftover}"


# ===== 2. 必填字段缺失 =====

@pytest.mark.parametrize("module", _V1_MODULES)
def test_v1_module_missing_field_raises(module: str):
    """删第一个必填字段 → InvalidInputError。"""
    required = REQUIRED_FIELDS[module]
    assert required, f"{module} 无必填字段(异常)"
    first_field = required[0]
    ctx = deepcopy(_V1_CONTEXTS[module])
    del ctx[first_field]
    with pytest.raises(InvalidInputError) as exc_info:
        render_prompt(module, ctx)
    assert first_field in str(exc_info.value)


def test_v1_module_unknown_raises():
    """未注册 module → ValueError(代码 bug,非用户错误)。"""
    with pytest.raises(ValueError, match="未知 module"):
        render_prompt("m8_unknown", {"chart": "{}"})


# ===== 3. _V1_SYSTEM_PROMPT 前缀拼接 =====

@pytest.mark.parametrize("module", _V1_MODULES)
def test_v1_module_starts_with_system_prompt(module: str):
    """所有 v1 模块渲染后都以全局 System Prompt 开头。"""
    prompt = render_prompt(module, _V1_CONTEXTS[module])
    assert prompt.startswith("你是一位命理结构分析师"), (
        f"{module} 未以全局 System Prompt 开头")


# ===== 4. chart 字段是 JSON 字符串 =====

def test_v1_chart_field_is_injected_as_json_string():
    """M0 context['chart'] 是 JSON 字符串,渲染后 chart 内容出现在 prompt 里。"""
    prompt = render_prompt("m0_structure", _M0_CONTEXT)
    # chart JSON 内的中文字段会被注入 prompt(ensure_ascii=False)
    assert "惊蛴后" or "惊蛰后" in prompt
    assert "甲" in prompt  # day_master.stem


def test_v1_chart_field_must_be_string_type():
    """chart 字段传 dict(非标量)→ InvalidInputError(防止 json 污染 prompt)。"""
    ctx = {"chart": _CHART_DICT}  # dict 不是 str
    with pytest.raises(InvalidInputError, match="类型非法"):
        render_prompt("m0_structure", ctx)


# ===== 5. 链式注入字段是 JSON 字符串 =====

def test_v1_chain_injection_fields_render_correctly():
    """M1 的 structure_fingerprint + main_axis + core_loop 被注入 prompt。"""
    prompt = render_prompt("m1_talent", _M1_CONTEXT)
    assert "劫财驱动型" in prompt  # structure_fingerprint 文本
    # main_axis / core_loop 是 JSON 字符串整体注入
    assert "劫财" in prompt  # main_axis 的 dominant 值


def test_v7_does_not_require_chart():
    """M7 不传 chart(基于 M1-M6 结论的总结),正常渲染。"""
    prompt = render_prompt("m7_manual", _M7_CONTEXT)
    assert "===== 模块 M7" in prompt
    # 注入字段值出现在 prompt 里
    assert "决断力" in prompt  # one_leverage JSON 内文本


# ===== 6. PROMPT_VERSIONS 完整性 =====

def test_v1_prompt_versions_all_registered_as_1():
    """8 个 v1 module 在 PROMPT_VERSIONS 注册,值都是 1(首次引入)。"""
    v1_modules = {
        "m0_structure", "m1_talent", "m2_high_low", "m3_system",
        "m4_health", "m5_wealth", "m6_dynamics", "m7_manual",
    }
    for module in v1_modules:
        assert module in PROMPT_VERSIONS, f"{module} 未注册 PROMPT_VERSIONS"
        assert PROMPT_VERSIONS[module] == 1, (
            f"{module} 期望版本 1,实际 {PROMPT_VERSIONS[module]}")


def test_v1_modules_all_registered_in_templates_and_required_fields():
    """8 个 v1 module 同时在 _TEMPLATES / REQUIRED_FIELDS / PROMPT_VERSIONS 注册。"""
    from app.ai.prompts import _TEMPLATES
    for module in _V1_MODULES:
        assert module in _TEMPLATES, f"{module} 未注册 _TEMPLATES"
        assert module in REQUIRED_FIELDS, f"{module} 未注册 REQUIRED_FIELDS"
        assert module in PROMPT_VERSIONS, f"{module} 未注册 PROMPT_VERSIONS"


# ===== 7. 篇幅约束(用户决策 2026-08-11: M1/M2/M3/M5/M7 加长至 1500-2500 字) =====

_LONG_MODULES = ["m1_talent", "m2_high_low", "m3_system", "m5_wealth", "m7_manual"]
_SHORT_MODULES = ["m0_structure", "m4_health", "m6_dynamics"]


@pytest.mark.parametrize("module", _LONG_MODULES)
def test_v1_long_modules_have_length_hint(module: str):
    """M1/M2/M3/M5/M7 模板含'1500-2500 字'篇幅约束。"""
    tpl = {
        "m1_talent": M1_TALENT_TEMPLATE, "m2_high_low": M2_HIGH_LOW_TEMPLATE,
        "m3_system": M3_SYSTEM_TEMPLATE, "m5_wealth": M5_WEALTH_TEMPLATE,
        "m7_manual": M7_MANUAL_TEMPLATE,
    }[module]
    assert "1500-2500 字" in tpl, f"{module} 模板缺篇幅约束"


@pytest.mark.parametrize("module", _SHORT_MODULES)
def test_v1_short_modules_no_length_hint(module: str):
    """M0/M4/M6 模板不含'1500-2500 字'约束(保持精简)。"""
    tpl = {
        "m0_structure": M0_STRUCTURE_TEMPLATE, "m4_health": M4_HEALTH_TEMPLATE,
        "m6_dynamics": M6_DYNAMICS_TEMPLATE,
    }[module]
    assert "1500-2500 字" not in tpl, (
        f"{module} 不应有篇幅约束(M0/M4/M6 保持精简)")


# ===== 8. chart_builder 测试 =====

# 模拟 BaziEngine.calculate() 返回值的完整 snapshot
def _make_snapshot(strength: str = "weak") -> dict:
    return {
        "meta": _CHART_DICT["meta"],
        "pillars": {
            "year":  {"gan_zhi": "庚午", "gan": "庚", "zhi": "午",
                      "gan_element": "metal", "zhi_element": "fire",
                      "hide_gan": ["丁", "己"], "shishen_gan": "七杀",
                      "shishen_zhi": ["正官", "正财"], "nayin": "路旁土",
                      "dishi": "死", "xunkong": "戌亥"},
            "month": {"gan_zhi": "己卯", "gan": "己", "zhi": "卯",
                      "gan_element": "earth", "zhi_element": "wood",
                      "hide_gan": ["乙"], "shishen_gan": "正财",
                      "shishen_zhi": ["劫财"], "nayin": "城头土",
                      "dishi": "病", "xunkong": "申酉"},
            "day":   {"gan_zhi": "甲子", "gan": "甲", "zhi": "子",
                      "gan_element": "wood", "zhi_element": "water",
                      "hide_gan": ["癸"], "shishen_gan": "日主",
                      "shishen_zhi": ["正印"], "nayin": "海中金",
                      "dishi": "沐浴", "xunkong": "戌亥"},
            "hour":  {"gan_zhi": "丁卯", "gan": "丁", "zhi": "卯",
                      "gan_element": "fire", "zhi_element": "wood",
                      "hide_gan": ["乙"], "shishen_gan": "伤官",
                      "shishen_zhi": ["劫财"], "nayin": "炉中火",
                      "dishi": "病", "xunkong": "申酉"},
        },
        "element_balance": {"wood": 2, "fire": 2, "earth": 1, "metal": 1, "water": 2},
        "day_master_strength": strength,
        "useful_god_candidates": ["火", "土"],
        "ten_god_weights": {"比肩": 0, "劫财": 3, "食神": 0, "伤官": 5,
                            "正财": 5, "偏财": 0, "正官": 3, "七杀": 5,
                            "正印": 4, "偏印": 0},
        "luck_pillars": [
            {"gan_zhi": "戊寅", "start_year": 1997, "end_year": 2006,
             "start_age": 7, "end_age": 16},
            {"gan_zhi": "丙子", "start_year": 2017, "end_year": 2026,
             "start_age": 27, "end_age": 36},
        ],
        "current_luck_pillar": {"gan_zhi": "丙子", "start_year": 2017,
                                "end_year": 2026},
        "current_year_pillar": "丙午",
    }


def test_chart_builder_returns_all_v1_schema_keys():
    """build_v1_chart 输出含设计文档 §1 全部 10 个顶层 keys。"""
    chart = build_v1_chart(_make_snapshot())
    expected_keys = {
        "meta", "pillars", "day_master", "ten_gods", "ten_god_weights",
        "five_elements", "useful_god_candidates", "luck_pillars",
        "current_luck", "current_year",
    }
    assert set(chart.keys()) == expected_keys


def test_chart_builder_day_master_aggregates_stem_element_label():
    """day_master 含 stem(日柱天干) + element(中文五行) + strength_label(中文)。"""
    chart = build_v1_chart(_make_snapshot(strength="weak"))
    dm = chart["day_master"]
    assert dm["stem"] == "甲"
    assert dm["element"] == "木"
    assert dm["strength_label"] == "偏弱"
    assert dm["strength_score"] is None  # BaziEngine 未透传 xiji.score


def test_chart_builder_ten_gods_aggregates_stems_and_hidden():
    """ten_gods 含 year/month/hour stem + 各柱 hidden 十神 list。"""
    chart = build_v1_chart(_make_snapshot())
    tg = chart["ten_gods"]
    assert tg["year_stem"] == "七杀"
    assert tg["month_stem"] == "正财"
    assert tg["hour_stem"] == "伤官"
    # hidden.* 是 shishen_zhi 的十神 list
    assert tg["hidden"]["year_branch"] == ["正官", "正财"]
    assert tg["hidden"]["day_branch"] == ["正印"]


def test_chart_builder_five_elements_translated_to_chinese():
    """five_elements 用中文 key(木/火/土/金/水),值来自 ElementBalance。"""
    chart = build_v1_chart(_make_snapshot())
    fe = chart["five_elements"]
    assert fe == {"木": 2, "火": 2, "土": 1, "金": 1, "水": 2}


def test_chart_builder_luck_pillars_split_gan_zhi():
    """luck_pillars 把 gan_zhi '戊寅' 拆为 stem '戊' + branch '寅'。"""
    chart = build_v1_chart(_make_snapshot())
    lp0 = chart["luck_pillars"][0]
    assert lp0["start_age"] == 7
    assert lp0["stem"] == "戊"
    assert lp0["branch"] == "寅"


def test_chart_builder_current_luck_split_and_lookup_start_age():
    """current_luck 拆 gan_zhi + 反查 luck_pillars 拿 start_age。"""
    chart = build_v1_chart(_make_snapshot())
    cl = chart["current_luck"]
    assert cl["stem"] == "丙"
    assert cl["branch"] == "子"
    assert cl["start_age"] == 27  # 反查 luck_pillars[1].start_age
    assert cl["ten_god"] is None  # 留空让 LLM 自推


def test_chart_builder_current_year_split_string():
    """current_year 把 '丙午' 字符串拆为 stem '丙' + branch '午'。"""
    chart = build_v1_chart(_make_snapshot())
    cy = chart["current_year"]
    assert cy["stem"] == "丙"
    assert cy["branch"] == "午"
    assert cy["ten_god"] is None


def test_chart_builder_special_pattern_clears_useful_god_candidates():
    """从格命中(special_pattern)→ useful_god_candidates=[] + label='从格特征'。"""
    snapshot = _make_snapshot(strength="special_pattern")
    chart = build_v1_chart(snapshot)
    assert chart["useful_god_candidates"] == []
    assert chart["day_master"]["strength_label"] == "从格特征"


def test_chart_builder_normal_strength_keeps_useful_god_candidates():
    """普通盘(weak/strong/balanced)useful_god_candidates 保留。"""
    for strength in ("weak", "strong", "balanced"):
        chart = build_v1_chart(_make_snapshot(strength=strength))
        assert chart["useful_god_candidates"] == ["火", "土"]
        assert chart["day_master"]["strength_label"] != "从格特征"


def test_chart_builder_missing_key_raises_key_error():
    """snapshot 缺关键字段 → KeyError(不静默填空)。"""
    bad_snapshot = _make_snapshot()
    del bad_snapshot["pillars"]
    with pytest.raises(KeyError):
        build_v1_chart(bad_snapshot)


def test_chart_builder_invalid_gan_zhi_length_raises_value_error():
    """gan_zhi 长度 ≠ 2 → ValueError(显式暴露数据不一致)。"""
    snapshot = _make_snapshot()
    snapshot["luck_pillars"][0]["gan_zhi"] = "戊"  # 长度 1,异常
    with pytest.raises(ValueError, match="长度异常"):
        build_v1_chart(snapshot)


# ===== 9. 端到端:chart_builder 输出 → M0 render =====

def test_e2e_chart_builder_to_m0_render():
    """chart_builder 输出 json.dumps 后塞进 M0 context,render 成功。"""
    snapshot = _make_snapshot()
    chart = build_v1_chart(snapshot)
    chart_json = json.dumps(chart, ensure_ascii=False, indent=2)
    prompt = render_prompt("m0_structure", {"chart": chart_json})

    # 全局 System Prompt 开头
    assert prompt.startswith("你是一位命理结构分析师")
    # chart 内容注入
    assert "甲" in prompt  # day_master.stem
    assert "偏弱" in prompt  # day_master.strength_label
    # M0 模块 header
    assert "===== 模块 M0" in prompt
    # JSON 输出 schema
    assert "structure_fingerprint" in prompt
