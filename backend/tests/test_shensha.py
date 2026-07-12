"""神煞查表单元测试 + 6 盘验收(决策 2)。

覆盖:
- 20 个神煞清单完整性(顺序、名称、吉凶分类)
- 每类查法(A 日干/B 年支日支/C 月支/D 年支)至少一个命中
- 多柱命中排序稳定(20 清单顺序 × 年月日时顺序)
- 未命中返回空列表(不报成功假数据)
- source 恒为"三命通会"
- 6 盘验收:与 expected_shensha 完全一致
- 确定性:同输入跑 2 次完全一致
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from lunar_python import Solar

from app.engine.bazi_engine import BaziEngine
from app.engine.pillars import build_pillars
from app.engine.shensha import (
    AUSPICIOUS,
    INAUSPICIOUS,
    SHENSHA_NAMES,
    SHENSHA_RULES,
    compute_shensha,
)
from tests.fixtures.shensha_cases import SHENSHA_CASES

TZ8 = timezone(timedelta(hours=8))
SECT = 1


def _build_pillars_from_birth(birth_str: str):
    birth = datetime.fromisoformat(birth_str)
    ec = Solar.fromDate(birth.replace(tzinfo=None)).getLunar().getEightChar()
    ec.setSect(SECT)
    return build_pillars(ec)


# ===== 20 清单完整性 =====


def test_shensha_list_count_20():
    """20 个神煞(吉神 11 + 凶煞 9)。"""
    assert len(SHENSHA_NAMES) == 20
    assert len(AUSPICIOUS) == 11
    assert len(INAUSPICIOUS) == 9


def test_shensha_list_order_fixed():
    """清单顺序固定:吉神 11 在前,凶煞 9 在后。"""
    expected = (
        "天乙贵人", "太极贵人", "文昌", "天德", "月德",
        "驿马", "桃花", "将星", "华盖", "金舆", "禄神",
        "羊刃", "劫煞", "亡神", "孤辰", "寡宿",
        "元辰", "灾煞", "天罗地网", "红艳",
    )
    assert SHENSHA_NAMES == expected


def test_shensha_rules_match_names():
    """SHENSHA_RULES 顺序与 SHENSHA_NAMES 一致。"""
    assert len(SHENSHA_RULES) == 20
    for rule, name in zip(SHENSHA_RULES, SHENSHA_NAMES, strict=True):
        assert rule.name == name


def test_shensha_auspicious_inauspicious_disjoint():
    """吉凶分类互斥且覆盖全清单。"""
    assert AUSPICIOUS.isdisjoint(INAUSPICIOUS)
    assert AUSPICIOUS | INAUSPICIOUS == set(SHENSHA_NAMES)


def test_shensha_source_always_sanningtonghui():
    """每条神煞 source 恒为'三命通会'。"""
    pillars = _build_pillars_from_birth("1990-03-15T14:30:00+08:00")
    items = compute_shensha(pillars, "male")
    for item in items:
        assert item.source == "三命通会"


# ===== 每类查法命中测试 =====


def test_class_a_day_gan_lookup():
    """A 类(日干查地支):天乙贵人/禄神/羊刃等。

    1990-03-15 庚午己卯己卯辛未,日干己 → 天乙贵人查子申。
    本盘无子申,天乙贵人不命中;但禄神(己→午)在年柱命中。
    """
    pillars = _build_pillars_from_birth("1990-03-15T14:30:00+08:00")
    items = compute_shensha(pillars, "male")
    names_positions = [(i.name, i.position) for i in items]
    # 禄神(己→午)年支午命中
    assert ("禄神", "年柱") in names_positions
    # 羊刃(己→未)时支未命中
    assert ("羊刃", "时柱") in names_positions


def test_class_b_year_day_zhi_dual_lookup():
    """B 类(年支/日支双查):驿马/桃花/将星/华盖等。

    1990-03-15 庚午己卯己卯辛未:
    - 年支午(寅午戌组)→ 桃花查卯,月支卯+日支卯命中
    - 日支卯(亥卯未组)→ 将星查卯,月支卯+日支卯命中
    同柱去重:桃花月柱+日柱(年支基准),将星月柱+日柱(日支基准)
    """
    pillars = _build_pillars_from_birth("1990-03-15T14:30:00+08:00")
    items = compute_shensha(pillars, "male")
    names_positions = [(i.name, i.position) for i in items]
    # 桃花月柱+日柱(年支午基准查到月支卯、日支卯)
    assert ("桃花", "月柱") in names_positions
    assert ("桃花", "日柱") in names_positions
    # 将星(年支午基准→午,年柱;日支卯基准→卯,月柱+日柱)
    assert ("将星", "年柱") in names_positions


def test_class_c_month_zhi_lookup():
    """C 类(月支查天干/地支):天德/月德。

    2005-12-23 乙酉戊子辛巳壬辰,月支子:
    - 天德(子→巳)时干壬?不,查巳。日支巳命中 → 天德日柱
    - 月德(子→壬,申子辰组)时干壬命中 → 月德时柱
    """
    pillars = _build_pillars_from_birth("2005-12-23T08:37:00+08:00")
    items = compute_shensha(pillars, "male")
    names_positions = [(i.name, i.position) for i in items]
    assert ("天德", "日柱") in names_positions, "天德应命中日柱(日支巳)"
    assert ("月德", "时柱") in names_positions, "月德应命中时柱(时干壬)"


def test_class_d_year_zhi_lookup():
    """D 类(年支查地支):孤辰/寡宿/天罗地网等。

    1988-02-15 戊辰甲寅辛丑戊子,年支辰:
    - 天罗地网:四柱含辰(年柱)→ 天罗地网年柱
    - 寡宿(辰→丑,寅卯辰组)日支丑命中 → 寡宿日柱
    """
    pillars = _build_pillars_from_birth("1988-02-15T23:30:00+08:00")
    items = compute_shensha(pillars, "male")
    names_positions = [(i.name, i.position) for i in items]
    assert ("天罗地网", "年柱") in names_positions, "年支辰应命中天罗地网"
    assert ("寡宿", "日柱") in names_positions, "年支辰组寡宿查丑,日支丑应命中"


def test_yuanchen_gender_direction():
    """元辰按性别+年干阴阳查表:阳男阴女顺,阴男阳女逆。

    2005-12-23 乙酉(阴年干)男 → 阴男阳女逆行。
    年支酉,逆行 YUANCHEN_BACKWARD[酉]=子。月支子命中 → 元辰月柱。
    """
    pillars = _build_pillars_from_birth("2005-12-23T08:37:00+08:00")
    items = compute_shensha(pillars, "male")
    names_positions = [(i.name, i.position) for i in items]
    assert ("元辰", "月柱") in names_positions, "乙酉年男(阴男)逆行,酉→子,月支子应命中元辰"


def test_yuanchen_gender_forward():
    """元辰顺行(阳男阴女):辛未(阴年干)女 → forward。

    辛(阴干) + female → 阴女顺行。
    年支未,顺行 YUANCHEN_FORWARD[未]=子。日支子命中 → 元辰日柱。
    """
    pillars = _build_pillars_from_birth("1991-05-18T03:37:00+08:00")
    items = compute_shensha(pillars, "female")
    names_positions = [(i.name, i.position) for i in items]
    assert ("元辰", "日柱") in names_positions, "辛未年女(阴女)顺行,未→子,日支子应命中元辰"


# ===== 排序与去重 =====


def test_output_order_stable():
    """输出顺序固定:20 清单顺序 × 年月日时柱顺序。"""
    pillars = _build_pillars_from_birth("2022-08-28T01:50:00+08:00")
    items = compute_shensha(pillars, "male")
    # 验证顺序:按 SHENSHA_NAMES 的索引升序
    name_order = {name: i for i, name in enumerate(SHENSHA_NAMES)}
    last_idx = -1
    for item in items:
        idx = name_order[item.name]
        assert idx >= last_idx, (
            f"神煞顺序错乱:{item.name}(清单索引{idx})出现在前一项(索引{last_idx})之后"
        )
        last_idx = idx


def test_same_pillar_dedup():
    """B 类双查同柱去重:年支基准和日支基准查到同一柱只算一条。"""
    # 1990-03-15 将星:年支午基准查午(年柱),日支卯基准查卯(月柱+日柱)
    # 年柱只出现一次(不会因双查重复)
    pillars = _build_pillars_from_birth("1990-03-15T14:30:00+08:00")
    items = compute_shensha(pillars, "male")
    jiangxing_positions = [i.position for i in items if i.name == "将星"]
    # 将星年柱、月柱、日柱各一条(无重复)
    assert len(jiangxing_positions) == len(set(jiangxing_positions)), "同柱不应重复"


def test_empty_when_no_hit():
    """单条规则未命中时返回空列表(不报成功假数据)。

    1990-03-15 庚午己卯己卯辛未,日干己 → 天乙贵人查子申。
    四柱地支 午/卯/卯/未,无子/申 → 天乙贵人 matcher 应返回空列表。
    """
    pillars = _build_pillars_from_birth("1990-03-15T14:30:00+08:00")
    # 天乙贵人 = SHENSHA_RULES[0]
    tianyi_rule = SHENSHA_RULES[0]
    assert tianyi_rule.name == "天乙贵人"
    hits = tianyi_rule.matcher(pillars, "male")
    assert hits == [], f"天乙贵人在无子/申的盘上应返回空列表,实得 {hits}"


# ===== 6 盘验收 =====


@pytest.mark.parametrize(
    "case", SHENSHA_CASES,
    ids=[f"{i:02d}_{c['note'][:20]}" for i, c in enumerate(SHENSHA_CASES)],
)
def test_shensha_6_cases(case, fixed_now):
    """6 盘验收:与 expected_shensha 完全一致(确定性快照)。

    expected 由本项目规则引擎生成,待问真八字 App 抽样对齐(方案 9.3)。
    """
    birth = datetime.fromisoformat(case["birth_datetime"])
    engine = BaziEngine(now=fixed_now)
    result = engine.calculate(
        birth=birth, gender=case["gender"],
        longitude=case["longitude"], zi_hour_rule=case["zi_hour_rule"],
    )
    actual = [(s["name"], s["position"]) for s in result["shensha"]]
    expected = case["expected_shensha"]
    assert actual == expected, (
        f"命盘 {case['birth_datetime']} {case['note']}\n"
        f"四柱:{result['pillars']['year']['gan_zhi']}"
        f"{result['pillars']['month']['gan_zhi']}"
        f"{result['pillars']['day']['gan_zhi']}"
        f"{result['pillars']['hour']['gan_zhi']}\n"
        f"期望:{expected}\n实得:{actual}"
    )


# ===== 确定性 =====


def test_shensha_deterministic():
    """同输入跑 2 次,神煞结果完全一致。"""
    pillars = _build_pillars_from_birth("1990-03-15T14:30:00+08:00")
    r1 = compute_shensha(pillars, "male")
    r2 = compute_shensha(pillars, "male")
    assert r1 == r2


def test_shensha_invalid_gender_raises():
    """非法 gender 抛 ValueError(不静默吞)。"""
    pillars = _build_pillars_from_birth("1990-03-15T14:30:00+08:00")
    with pytest.raises(ValueError, match="非法 gender"):
        compute_shensha(pillars, "unknown")


def test_shensha_unknown_gan_raises():
    """未知天干必须显式报错,不能在元辰顺逆里被当作阴干。"""
    pillars = _build_pillars_from_birth("1990-03-15T14:30:00+08:00")
    bad_year = pillars.year.model_copy(update={"gan": "?"})
    bad_pillars = pillars.model_copy(update={"year": bad_year})

    with pytest.raises(ValueError, match="未知天干"):
        compute_shensha(bad_pillars, "male")
