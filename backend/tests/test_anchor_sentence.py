"""_build_anchor_sentence 单元测试(决策 #13 chart anchor sentence)。

覆盖:
- normal: strong/weak/balanced 三种普通盘模板拼接正确
- special_pattern: 从格诚实降级,不下硬性喜忌
- empty: favorable/unfavorable 任一为空时防御性拼接
- 未知 strength(含 None): fallback "旺衰未判定"
- markdown ** 加粗 + 中文标点 字面正确
"""

from __future__ import annotations

import pytest

from app.engine.bazi_engine import _STRENGTH_LABEL, _build_anchor_sentence


class TestBuildAnchorSentenceNormal:
    """普通盘(strong/weak/balanced)模板拼接。"""

    def test_strong_full_template(self):
        s = _build_anchor_sentence(
            day_gan="庚",
            day_gan_element="金",
            day_master_strength="strong",
            favorable=["火", "土"],
            unfavorable=["水", "金"],
        )
        # 模板(用户 Q2 拍板 A 完整版):
        # "你的日主是 **庚**（金），命局整体 **偏旺**，**喜** 火/土、**忌** 水/金。"
        assert s == "你的日主是 **庚**（金），命局整体 **偏旺**，**喜** 火/土、**忌** 水/金。"

    def test_weak_full_template(self):
        s = _build_anchor_sentence(
            day_gan="乙",
            day_gan_element="木",
            day_master_strength="weak",
            favorable=["水", "木"],
            unfavorable=["金", "土"],
        )
        assert s == "你的日主是 **乙**（木），命局整体 **偏弱**，**喜** 水/木、**忌** 金/土。"

    def test_balanced_full_template(self):
        s = _build_anchor_sentence(
            day_gan="戊",
            day_gan_element="土",
            day_master_strength="balanced",
            favorable=["火", "土"],
            unfavorable=["水", "木"],
        )
        assert s == "你的日主是 **戊**（土），命局整体 **中和**，**喜** 火/土、**忌** 水/木。"

    def test_single_element_join(self):
        """单元素喜/忌不 join,直接输出。"""
        s = _build_anchor_sentence(
            day_gan="甲",
            day_gan_element="木",
            day_master_strength="strong",
            favorable=["木"],
            unfavorable=["金"],
        )
        assert s == "你的日主是 **甲**（木），命局整体 **偏旺**，**喜** 木、**忌** 金。"


class TestBuildAnchorSentenceSpecialPattern:
    """从格诚实降级(对齐 CLAUDE.md 'LLM 诚实告知')。"""

    def test_special_pattern_no_xiji(self):
        """special_pattern 只输出 label,不下硬性喜忌。"""
        s = _build_anchor_sentence(
            day_gan="壬",
            day_gan_element="水",
            day_master_strength="special_pattern",
            favorable=[],  # 从格 xiji 返回空 list
            unfavorable=[],
        )
        # base + "。" 不接喜忌
        assert s == "你的日主是 **壬**（水），命局整体 **呈现从格特征**。"
        # 关键:不出现"喜"/"忌"硬性结论
        assert "喜" not in s
        assert "忌" not in s

    def test_special_pattern_ignores_nonempty_favorable(self):
        """即使 favorable 误传非空,special_pattern 仍不下喜忌(防御)。"""
        s = _build_anchor_sentence(
            day_gan="壬",
            day_gan_element="水",
            day_master_strength="special_pattern",
            favorable=["火"],  # 误传
            unfavorable=["金"],
        )
        assert "喜" not in s
        assert "忌" not in s


class TestBuildAnchorSentenceEmpty:
    """favorable/unfavorable 为空的防御性拼接(理论上普通盘不应触发)。"""

    def test_both_empty_normal_strength(self):
        """normal strength 但喜忌都空 → 只输出 base。"""
        s = _build_anchor_sentence(
            day_gan="丙",
            day_gan_element="火",
            day_master_strength="strong",
            favorable=[],
            unfavorable=[],
        )
        assert s == "你的日主是 **丙**（火），命局整体 **偏旺**。"

    def test_only_favorable_empty(self):
        s = _build_anchor_sentence(
            day_gan="丙",
            day_gan_element="火",
            day_master_strength="weak",
            favorable=[],
            unfavorable=["金"],
        )
        # 只有忌
        assert s == "你的日主是 **丙**（火），命局整体 **偏弱**，**忌** 金。"

    def test_only_unfavorable_empty(self):
        s = _build_anchor_sentence(
            day_gan="丙",
            day_gan_element="火",
            day_master_strength="weak",
            favorable=["木"],
            unfavorable=[],
        )
        assert s == "你的日主是 **丙**（火），命局整体 **偏弱**，**喜** 木。"


class TestBuildAnchorSentenceUnknownStrength:
    """未知 / None day_master_strength fallback。"""

    def test_none_strength_fallback(self):
        s = _build_anchor_sentence(
            day_gan="丁",
            day_gan_element="火",
            day_master_strength=None,
            favorable=["木"],
            unfavorable=["水"],
        )
        # fallback "旺衰未判定"
        assert "旺衰未判定" in s

    def test_unknown_strength_string_fallback(self):
        s = _build_anchor_sentence(
            day_gan="丁",
            day_gan_element="火",
            day_master_strength="nonsense",
            favorable=[],
            unfavorable=[],
        )
        assert "旺衰未判定" in s


class TestStrengthLabelCoverage:
    """_STRENGTH_LABEL 覆盖所有 day_master_strength 取值。"""

    @pytest.mark.parametrize("key", ["strong", "weak", "balanced", "special_pattern"])
    def test_all_strength_keys_present(self, key):
        """xiji.compute_xiji 只返回这 4 个值,dict 必须全覆盖。"""
        assert key in _STRENGTH_LABEL
