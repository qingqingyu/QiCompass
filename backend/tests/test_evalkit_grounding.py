"""evalkit L2 接地校验层单测(S03)。

全部手写正反例,零 API 调用。核心立场:宁可漏报不可误报——
反例必须命中,正例(含易误报文本)必须全过。
"""

from __future__ import annotations

import pytest

from evalkit.checks.grounding import (
    check_chain_consistency,
    check_grounding,
    check_no_hard_geju,
    check_shensha_bounded,
    check_special_pattern_honesty,
    check_xiji_consistency,
)


def _engine(**overrides):
    base = {
        "favorable_elements": ["metal", "water"],
        "unfavorable_elements": ["fire", "earth"],
        "day_master_strength": "weak",
        "shensha": [
            {"name": "文昌", "position": "日柱", "source": "三命通会"},
            {"name": "驿马", "position": "年柱", "source": "三命通会"},
        ],
        "pattern_hint": None,
    }
    base.update(overrides)
    return base


def _special_engine():
    return _engine(
        favorable_elements=[], unfavorable_elements=[],
        day_master_strength="special_pattern", pattern_hint="cong_fire",
    )


# ===== 1. 喜忌一致性 =====


def test_xiji_recommending_favorable_passes():
    out = {"summary": "金有利,宜多用金水来增强专注。"}
    assert check_xiji_consistency("m1_talent", out, _engine()) == []


def test_xiji_recommending_unfavorable_fails():
    out = {"summary": "宜多用火,提升行动力。"}  # fire 在 unfavorable
    failures = check_xiji_consistency("m1_talent", out, _engine())
    assert any("喜忌矛盾" in f and "火" in f for f in failures)
    # failure 自带证据:命中片段 + ground truth
    assert any("「宜多用火」" in f and "unfavorable" in f for f in failures)


def test_xiji_avoiding_favorable_fails():
    out = {"summary": "忌金,少接触金属性环境。"}  # metal 在 favorable
    failures = check_xiji_consistency("m1_talent", out, _engine())
    assert any("喜忌矛盾" in f and "金" in f and "favorable" in f
               for f in failures)


def test_xiji_element_after_signal_passes():
    """信号在后:「水对你有利」(water favorable)→ 通过。"""
    out = {"summary": "多靠近北方,水对你有利。"}
    assert check_xiji_consistency("m1_talent", out, _engine()) == []


def test_xiji_ambiguous_sentence_skipped():
    """歧义句(同时含推荐与规避信号)不判:宁可漏报。"""
    out = {"summary": "身强宜用金,忌火但需辩证看。"}
    assert check_xiji_consistency("m1_talent", out, _engine()) == []


def test_xiji_money_word_not_element():
    """误报防御:「适合积累资金」的金在信号 2 字窗口外,不判为推荐金。"""
    out = {"summary": "适合积累资金,三年攒出安全垫。"}
    assert check_xiji_consistency("m5_wealth", out, _engine()) == []


def test_xiji_special_pattern_skips():
    """favorable 为空(special 盘)→ 本项跳过。"""
    out = {"summary": "宜多用火。"}
    assert check_xiji_consistency("m1_talent", out, _special_engine()) == []


def test_xiji_missing_keys_raise():
    with pytest.raises(KeyError):
        check_xiji_consistency("m1_talent", {"s": "x"}, {})


# ===== 2. 神煞不超界 =====


def test_shensha_hit_passes():
    out = {"note": "文昌入日柱,学习能力强。"}
    assert check_shensha_bounded("m1_talent", out, _engine()) == []


def test_shensha_out_of_list_fails():
    out = {"note": "天医星入命,适合医疗行业。"}
    failures = check_shensha_bounded("m1_talent", out, _engine())
    assert any("神煞越界" in f and "天医" in f for f in failures)


def test_shensha_in_list_not_hit_fails():
    out = {"note": "华盖坐命,适合独立钻研。"}  # 华盖在 20 清单但本盘未命中
    failures = check_shensha_bounded("m1_talent", out, _engine())
    assert any("神煞未命中" in f and "华盖" in f for f in failures)


def test_shensha_missing_key_raises():
    engine = _engine()
    del engine["shensha"]
    with pytest.raises(KeyError):
        check_shensha_bounded("m1_talent", {"n": "x"}, engine)


# ===== 3. 格局红线 =====


def test_geju_fuzzy_narrative_passes():
    out = {"note": "命局呈现偏印倾向,思维纵深。"}
    assert check_no_hard_geju("m1_talent", out, _engine()) == []


def test_geju_neutral_word_allowed():
    """单独"格局"二字是允许的中性表述。"""
    out = {"note": "整体格局偏流动,不追求稳定。"}
    assert check_no_hard_geju("m1_talent", out, _engine()) == []


def test_geju_hard_classification_fails():
    out = {"note": "此为偏印格,宜文职。"}
    failures = check_no_hard_geju("m1_talent", out, _engine())
    assert any("硬性格局" in f and "偏印格" in f for f in failures)


# ===== 4. special_pattern 诚实 =====


def test_special_honest_passes():
    out = {"note": "本盘不入常格,扶抑框架不适用,围绕从格特征做叙事。"}
    assert check_special_pattern_honesty("m1_talent", out, _special_engine()) == []


def test_special_fabricated_xiji_fails():
    out = {"note": "喜用火土,多补火。"}
    failures = check_special_pattern_honesty("m1_talent", out, _special_engine())
    assert any("编造喜忌" in f for f in failures)


def test_special_hidden_degradation_fails():
    out = {"note": "你的结构以行动力见长,执行力是核心。"}  # 只字未提降级
    failures = check_special_pattern_honesty("m1_talent", out, _special_engine())
    assert any("隐藏降级" in f for f in failures)


def test_special_check_skips_normal_chart():
    out = {"note": "执行力强。"}
    assert check_special_pattern_honesty("m1_talent", out, _engine()) == []


# ===== 5. 链式一致性 =====


def test_chain_verbatim_fingerprint_passes():
    chain = {"m0_structure": {"structure_fingerprint": "伤官生财循环驱动,外显创造力"}}
    out = {"note": "以「伤官生财循环驱动,外显创造力」为主线展开。"}
    assert check_chain_consistency(
        "m1_talent", out, _engine(), chain_context=chain) == []


def test_chain_mutated_fingerprint_fails():
    chain = {"m0_structure": {"structure_fingerprint": "伤官生财循环驱动,外显创造力"}}
    out = {"note": "以「伤官生财循环带动,外显创造力」为主线展开。"}  # 改了一字
    failures = check_chain_consistency(
        "m1_talent", out, _engine(), chain_context=chain)
    assert any("链式不一致" in f for f in failures)


def test_chain_no_reference_passes():
    """不引用 fingerprint 的输出不判(漏报可接受)。"""
    chain = {"m0_structure": {"structure_fingerprint": "伤官生财循环驱动,外显创造力"}}
    out = {"note": "你的核心能力来自快速迭代。"}
    assert check_chain_consistency(
        "m1_talent", out, _engine(), chain_context=chain) == []


def test_chain_none_context_skips():
    out = {"note": "随便说什么"}
    assert check_chain_consistency(
        "m1_talent", out, _engine(), chain_context=None) == []


def test_chain_m0_itself_skips():
    out = {"structure_fingerprint": "伤官生财循环驱动"}
    assert check_chain_consistency(
        "m0_structure", out, _engine(), chain_context={}) == []


# ===== 聚合 + 误报防御 =====


def test_aggregate_combines_all_checks():
    out = {
        "note": "此为偏印格。天医入命。",
    }
    failures = check_grounding("m1_talent", out, _engine())
    assert any("硬性格局" in f for f in failures)
    assert any("神煞越界" in f for f in failures)


def test_false_positive_defense_long_compliant_text():
    """一段完全合规的长文本跑全部五项 → 零 failure(防模式过宽)。"""
    out = {
        "innate": [
            {"name": "结构洞察", "behavior": "先搭框架再动手",
             "evidence": "偏印倾向(命局呈现偏印倾向,非硬分类)"},
        ],
        "defensive": [
            {"name": "过度准备", "looks_like": "迟迟不发布",
             "actual_cost": "错过反馈窗口"},
        ],
        "one_leverage": "结构洞察",
        "note": "金有利,宜多用金水。文昌入日柱,学习反馈快。"
                "资金安排上适合留出三个月缓冲,不追求重资产。"
                "整体格局偏轻,像水流一样绕过障碍。",
    }
    chain = {"m0_structure": {"structure_fingerprint": "印重身轻,以印化食"}}
    assert check_grounding(
        "m1_talent", out, _engine(), chain_context=chain) == []


def test_unknown_element_in_ground_truth_raises():
    engine = _engine(favorable_elements=["metal", "phlogiston"])
    out = {"s": "宜多用金。"}
    with pytest.raises(ValueError, match="未知五行"):
        check_xiji_consistency("m1_talent", out, engine)


def test_chinese_elements_in_ground_truth_accepted():
    """engine 实测输出中文五行('金'/'土'),直接可用(2026-08-18 实测校准)。"""
    engine = _engine(favorable_elements=["金", "土"],
                     unfavorable_elements=["水", "木", "火"])
    ok = {"s": "金有利,宜多用金。"}
    assert check_xiji_consistency("m1_talent", ok, engine) == []
    bad = {"s": "宜多用火,提升行动力。"}
    failures = check_xiji_consistency("m1_talent", bad, engine)
    assert any("喜忌矛盾" in f and "火" in f for f in failures)


def test_chain_m7_exempt_from_verbatim_check():
    """M7 不做逐字判(模板要求改写不复述):改写引用半个指纹也不 fail。"""
    chain = {"m0_structure": {"structure_fingerprint": "伤官生财循环驱动,外显创造力"}}
    out = {"note": "以「伤官生财循环驱动」为底色的落地手册,不复述分析。"}
    assert check_chain_consistency(
        "m7_manual", out, _engine(), chain_context=chain) == []
