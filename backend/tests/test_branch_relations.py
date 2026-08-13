"""branch_relations.compute_friends_and_clash 单元测试。

2026-08-13 onboarding 三屏重构:反馈屏「好朋友(六合1+三合2)/ 需磨合(六冲1)」。
覆盖:
- 12 地支全量:好朋友 = [六合, 三合×2(按地支顺序)],需磨合 = 六冲
- 展示序稳定:六合排第一,三合按子→亥顺序
- 未知地支 → ValueError(错误显式传播)
"""

from __future__ import annotations

import pytest

from app.engine.branch_relations import compute_friends_and_clash


# 12 地支 → (好朋友地支 [六合, 三合按序], 需磨合地支)
# 关系表事实源:branch_relations.py LIUHE / SANHE / LIUCHONG
CASES: dict[str, tuple[list[str], str]] = {
    "子": (["丑", "辰", "申"], "午"),
    "丑": (["子", "巳", "酉"], "未"),
    "寅": (["亥", "午", "戌"], "申"),
    "卯": (["戌", "未", "亥"], "酉"),
    "辰": (["酉", "子", "申"], "戌"),
    "巳": (["申", "丑", "酉"], "亥"),
    "午": (["未", "寅", "戌"], "子"),
    "未": (["午", "卯", "亥"], "丑"),
    "申": (["巳", "子", "辰"], "寅"),
    "酉": (["辰", "丑", "巳"], "卯"),
    "戌": (["卯", "寅", "午"], "辰"),
    "亥": (["寅", "卯", "未"], "巳"),
}


@pytest.mark.parametrize("zhi", list(CASES))
def test_friends_and_clash_all_12(zhi: str):
    friends_zhi, clash_zhi = compute_friends_and_clash(zhi)
    expected_friends, expected_clash = CASES[zhi]
    assert friends_zhi == expected_friends, (
        f"{zhi} 好朋友应为 {expected_friends},实得 {friends_zhi}"
    )
    assert clash_zhi == expected_clash, (
        f"{zhi} 需磨合应为 {expected_clash},实得 {clash_zhi}"
    )


def test_friends_and_clash_structure():
    """结构约束:好朋友恒 3 支且不含自身,六合排第一。"""
    for zhi in CASES:
        friends, clash = compute_friends_and_clash(zhi)
        assert len(friends) == 3
        assert zhi not in friends, "好朋友不应包含自身"
        assert clash != zhi, "需磨合不应是自身"
        # 六合在第一位(展示序:六合最强排最前)
        liuhe_pairs = [("子", "丑"), ("寅", "亥"), ("卯", "戌"),
                       ("辰", "酉"), ("巳", "申"), ("午", "未")]
        for a, b in liuhe_pairs:
            if zhi in (a, b):
                assert friends[0] == (b if zhi == a else a), (
                    f"{zhi} 的六合应排第一位"
                )
                break


def test_unknown_zhi_raises():
    """未知地支 → ValueError(错误显式传播,不静默吞)。"""
    with pytest.raises(ValueError):
        compute_friends_and_clash("猫")
