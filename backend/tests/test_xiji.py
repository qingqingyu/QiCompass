"""喜忌引擎单元测试 + 50 盘验收(决策 1)。

覆盖:
- 普通身强/身弱/balanced 边界
- 子/丑月调候喜火,午/未月调候喜水
- 调候与扶抑冲突时取调候
- 专旺 ≥6/8 命中
- 从格(日主孤立 + 某行 ≥5)命中
- special_pattern 时喜忌为空、xiji_method 正确
- 50 盘验收:90% 普通 + 10% special_pattern
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from lunar_python import Solar

from app.engine.bazi_engine import BaziEngine
from app.engine.pillars import build_pillars, compute_element_balance
from app.engine.xiji import (
    EN2ZH,
    STRONG_THRESHOLD,
    WEAK_THRESHOLD,
    compute_xiji,
)
from tests.fixtures.xiji_cases import XIJI_CASES

TZ8 = timezone(timedelta(hours=8))
SECT = 1

_VALID_ELEMENTS = set(EN2ZH.values())  # {"木","火","土","金","水"}


def _build_pillars_from_birth(birth_str: str):
    """用 lon=120.0 排盘(消除经度时差,只留 EoT),返回 (pillars, element_balance)。"""
    birth = datetime.fromisoformat(birth_str)
    ec = Solar.fromDate(birth.replace(tzinfo=None)).getLunar().getEightChar()
    ec.setSect(SECT)
    pillars = build_pillars(ec)
    eb = compute_element_balance(pillars)
    return pillars, eb


# ===== 单元场景 =====


def test_normal_strong_pan():
    """普通身强盘:1985-01-10 丑月,日干丙火,应有 strong + 非空喜忌。"""
    pillars, eb = _build_pillars_from_birth("1985-01-10T10:30:00+08:00")
    result = compute_xiji(pillars, eb)
    assert result.day_master_strength == "strong"
    assert result.favorable_elements, "身强盘喜用不应为空"
    assert result.unfavorable_elements, "身强盘忌讳不应为空"
    assert all(e in _VALID_ELEMENTS for e in result.favorable_elements)
    assert all(e in _VALID_ELEMENTS for e in result.unfavorable_elements)
    assert result.pattern_hint is None
    assert result.xiji_method == "扶抑+调候"


def test_normal_weak_pan():
    """普通身弱盘:1985-03-10 卯月,应有 weak + 非空喜忌。"""
    pillars, eb = _build_pillars_from_birth("1985-03-10T10:30:00+08:00")
    result = compute_xiji(pillars, eb)
    assert result.day_master_strength == "weak"
    assert result.favorable_elements, "身弱盘喜用不应为空"
    assert result.unfavorable_elements, "身弱盘忌讳不应为空"
    assert all(e in _VALID_ELEMENTS for e in result.favorable_elements)
    assert result.pattern_hint is None


def test_balanced_pan_boundary():
    """balanced 盘:1985-02-10,score 在 4-5 之间,标注中和。"""
    pillars, eb = _build_pillars_from_birth("1985-02-10T10:30:00+08:00")
    result = compute_xiji(pillars, eb)
    assert result.day_master_strength == "balanced"
    assert WEAK_THRESHOLD < result.score < STRONG_THRESHOLD
    assert "中和" in result.xiji_method
    assert result.favorable_elements, "balanced 盘应有倾斜方向的喜用"
    assert result.pattern_hint is None


def test_tiaoshou_winter_months_fire():
    """子/丑月调候喜火:1985-12-10(子月)应触发调候,火在 favorable。"""
    pillars, eb = _build_pillars_from_birth("1985-12-10T10:30:00+08:00")
    result = compute_xiji(pillars, eb)
    month_zhi = pillars.month.zhi
    assert month_zhi in ("子", "丑"), f"预期子/丑月,实得 {month_zhi}"
    assert result.tiaoshou_applied is True
    assert "火" in result.favorable_elements, "冬月调候应喜火"


def test_tiaoshou_summer_months_water():
    """午/未月调候喜水:1985-06-10(午月)应触发调候,水在 favorable。"""
    pillars, eb = _build_pillars_from_birth("1985-06-10T10:30:00+08:00")
    result = compute_xiji(pillars, eb)
    month_zhi = pillars.month.zhi
    assert month_zhi in ("午", "未"), f"预期午/未月,实得 {month_zhi}"
    assert result.tiaoshou_applied is True
    assert "水" in result.favorable_elements, "夏月调候应喜水"


def test_tiaoshou_overrides_fuyi_conflict():
    """调候与扶抑冲突时取调候:调候用神从 unfavorable 移除。

    构造场景:身强日主在未月,身强忌官杀/食伤/财。
    若调候水(官杀/财/食伤之一)在 unfavorable → 应被移除。
    """
    # 1985-07-10 未月,日主身强(fixture 确认 strong),调候水应从 unfavorable 移除
    pillars, eb = _build_pillars_from_birth("1985-07-10T10:30:00+08:00")
    result = compute_xiji(pillars, eb)
    assert result.day_master_strength == "strong", "此盘应为身强( fixture 确认)"
    assert result.tiaoshou_applied is True, "未月应触发调候"
    # 调候用神水不应出现在 unfavorable
    assert "水" not in result.unfavorable_elements, "调候用神不应在忌神列表"
    assert "水" in result.favorable_elements


def test_zhuanwang_detection():
    """专旺盘:1903-12-01 癸卯癸亥癸亥壬子,water=7>=6 → zhuanwang。"""
    pillars, eb = _build_pillars_from_birth("1903-12-01T00:30:00+08:00")
    result = compute_xiji(pillars, eb)
    assert result.day_master_strength == "special_pattern"
    assert result.pattern_hint == "zhuanwang"
    assert result.favorable_elements == [], "special_pattern 喜忌应为空"
    assert result.unfavorable_elements == [], "special_pattern 喜忌应为空"
    assert result.tiaoshou_applied is False
    assert "从格特征检测命中" in result.xiji_method


def test_cong_detection():
    """从格盘:1912-03-01 壬子壬寅丙子戊子,日主丙火孤立,water=5>=5 → cong。"""
    pillars, eb = _build_pillars_from_birth("1912-03-01T00:30:00+08:00")
    result = compute_xiji(pillars, eb)
    assert result.day_master_strength == "special_pattern"
    assert result.pattern_hint == "cong"
    assert result.favorable_elements == []
    assert result.unfavorable_elements == []
    assert "从格特征检测命中" in result.xiji_method


def test_cong_requires_isolated_day_master():
    """从格需日主孤立(年/月/时干无印比劫)。非孤立不命中从格。"""
    # 1906-07-01 丙午甲午丙午甲午 fire=6 → 专旺(不是从格)
    pillars, eb = _build_pillars_from_birth("1906-07-01T12:30:00+08:00")
    result = compute_xiji(pillars, eb)
    assert result.pattern_hint == "zhuanwang", "fire>=6 应命中专旺而非从格"


def test_special_pattern_score_not_used():
    """special_pattern 时 score 为 -1(未计算)。"""
    pillars, eb = _build_pillars_from_birth("1903-12-01T00:30:00+08:00")
    result = compute_xiji(pillars, eb)
    assert result.day_master_strength == "special_pattern"
    assert result.score == -1


def test_fuyi_score_components():
    """扶抑打分:得令(月支主气)+ 得地(日支藏干)+ 得势(年/月/时干)。

    1985-01-10 丑月,日干己土:
    - 得令: 月支丑(土,比劫) → +5
    - 得地: 日支酉藏干[辛(金)] 不生扶 → +0
    - 得势: 月干丁(火,印)+1, 时干己(土,比劫)+1, 年干甲(木)不生扶 → +2
    - 总分 = 5 + 0 + 2 = 7 → strong
    """
    pillars, eb = _build_pillars_from_birth("1985-01-10T10:30:00+08:00")
    result = compute_xiji(pillars, eb)
    assert result.score == 7, f"预期 score=7(得令5+得地0+得势2),实得 {result.score}"
    assert result.day_master_strength == "strong"


# ===== 50 盘验收 =====


@pytest.mark.parametrize(
    "case", XIJI_CASES,
    ids=[f"{i:02d}_{c['expected']['strength']}" for i, c in enumerate(XIJI_CASES)],
)
def test_xiji_50_cases(case, fixed_now):
    """50 盘验收:90% 普通 + 10% special_pattern。

    每盘断言 day_master_strength 匹配 expected;
    普通盘额外断言喜忌非空且五行合法;
    special_pattern 盘断言喜忌为空。
    """
    birth = datetime.fromisoformat(case["birth_datetime"])
    engine = BaziEngine(now=fixed_now)
    result = engine.calculate(
        birth=birth, gender=case["gender"],
        longitude=case["longitude"], zi_hour_rule=case["zi_hour_rule"],
    )

    expected = case["expected"]
    actual_strength = result["day_master_strength"]
    actual_pattern = result["pattern_hint"]

    assert actual_strength == expected["strength"], (
        f"命盘 {case['birth_datetime']} {case['gender']} "
        f"四柱:{result['pillars']['year']['gan_zhi']}"
        f"{result['pillars']['month']['gan_zhi']}"
        f"{result['pillars']['day']['gan_zhi']}"
        f"{result['pillars']['hour']['gan_zhi']} "
        f"五行:{result['element_balance']} "
        f"期望 strength={expected['strength']},实得={actual_strength}"
    )

    if expected["strength"] == "special_pattern":
        assert actual_pattern == expected["pattern_hint"], (
            f"special_pattern 盘 pattern_hint 期望 {expected['pattern_hint']},"
            f"实得 {actual_pattern}"
        )
        assert result["favorable_elements"] == [], "special_pattern 喜忌应为空"
        assert result["unfavorable_elements"] == [], "special_pattern 喜忌应为空"
        assert "从格特征检测命中" in result["xiji_method"]
    else:
        assert result["favorable_elements"], "普通盘喜用不应为空"
        assert result["unfavorable_elements"], "普通盘忌讳不应为空"
        assert all(e in _VALID_ELEMENTS for e in result["favorable_elements"])
        assert all(e in _VALID_ELEMENTS for e in result["unfavorable_elements"])
        assert result["pattern_hint"] is None
        assert "扶抑+调候" in result["xiji_method"]


def test_xiji_90_10_distribution():
    """50 盘分布:special_pattern 占 ~10%(5 个),普通占 ~90%(45 个)。"""
    from collections import Counter

    strengths = [c["expected"]["strength"] for c in XIJI_CASES]
    dist = Counter(strengths)
    total = len(XIJI_CASES)
    special_count = dist.get("special_pattern", 0)
    normal_count = total - special_count

    assert total == 50, f"应有 50 盘,实得 {total}"
    assert special_count == 5, f"special_pattern 应 5 个,实得 {special_count}"
    assert normal_count == 45, f"普通盘应 45 个,实得 {normal_count}"
    # 90/10 比例
    assert abs(special_count / total - 0.10) < 0.01
