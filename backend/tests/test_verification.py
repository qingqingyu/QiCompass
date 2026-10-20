"""生肖屏节点句引擎测试(docs/生肖屏节点句设计决策.md §7,2026-10-19 拍板)。

纯函数用例(直调 pick_past_node,日/月支与大运 start_year 构造可控)+
全链路接线用例(BaziEngine.calculate → BaziCalculateResponse)。

固定 last_complete_year=2025(断言与 wall clock 解耦;「今年不算」语义由
用例显式覆盖:2026 候选不取)。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.engine.bazi_engine import BaziEngine
from app.engine.pillars import year_pillar_ganzhi
from app.engine.verification import pick_past_node
from app.models.bazi import BaziCalculateResponse, LuckPillar

LAST = 2025


def _lp(start_year: int, end_year: int = 2035) -> LuckPillar:
    """构造仅 start_year 有意义的大运(其余字段与选点无关)。"""
    return LuckPillar(gan_zhi="辛巳", start_year=start_year,
                      end_year=end_year, start_age=0, end_age=99)


# ===== rank 0:天克地冲日柱 =====


def test_rank0_year_gan_overcomes_day_gan():
    """2016 丙申 vs 庚寅日:丙克庚 + 申冲寅 → chong_day_pillar(流年克日主向)。"""
    node = pick_past_node(birth_year=2000, day_gan="庚", day_zhi="寅",
                          month_zhi="子", luck_pillars=[],
                          last_complete_year=LAST)
    assert node is not None
    assert node.model_dump() == {"kind": "chong_day_pillar",
                                 "year": 2016, "age": 16}


def test_rank0_reverse_direction_day_gan_overcomes():
    """2016 丙申 vs 壬寅日:壬克丙(反向)+ 申冲寅 → 仍算天克地冲(任一方向)。"""
    node = pick_past_node(birth_year=2000, day_gan="壬", day_zhi="寅",
                          month_zhi=None, luck_pillars=[],
                          last_complete_year=LAST)
    assert node is not None
    assert node.kind == "chong_day_pillar"
    assert node.year == 2016


# ===== rank 1:冲日支 =====


def test_rank1_chong_day_zhi_without_gan_overcoming():
    """2016 丙申 vs 甲寅日:申冲寅但丙/甲无克 → 只算冲日支。"""
    node = pick_past_node(birth_year=2000, day_gan="甲", day_zhi="寅",
                          month_zhi=None, luck_pillars=[],
                          last_complete_year=LAST)
    assert node is not None
    assert node.model_dump() == {"kind": "chong_day_zhi",
                                 "year": 2016, "age": 16}


def test_rank_beats_recency():
    """rank0(2016)压过更近的 rank2(2024 冲月支)——跨强度取更强(D1/D3)。"""
    node = pick_past_node(birth_year=2000, day_gan="庚", day_zhi="寅",
                          month_zhi="戌", luck_pillars=[],
                          last_complete_year=LAST)
    assert node is not None
    assert node.kind == "chong_day_pillar"
    assert node.year == 2016


# ===== rank 2:冲月支(日柱歧义降级路径) =====


def test_rank2_chong_month_zhi_when_day_unknown():
    """日柱歧义(双 None)→ rank0/1 缺席不猜;2024 甲辰 vs 月支戌 → 冲月支。"""
    node = pick_past_node(birth_year=2000, day_gan=None, day_zhi=None,
                          month_zhi="戌", luck_pillars=[],
                          last_complete_year=LAST)
    assert node is not None
    assert node.model_dump() == {"kind": "chong_month_zhi",
                                 "year": 2024, "age": 24}


def test_same_year_higher_rank_wins():
    """同年冲月支 + 换大运 → 只记最强一档(冲月支,§2.1)。"""
    node = pick_past_node(birth_year=2000, day_gan=None, day_zhi=None,
                          month_zhi="戌", luck_pillars=[_lp(2024)],
                          last_complete_year=LAST)
    assert node is not None
    assert node.kind == "chong_month_zhi"
    assert node.year == 2024


# ===== rank 3:换大运 =====


def test_rank3_luck_transition():
    node = pick_past_node(birth_year=2000, day_gan=None, day_zhi=None,
                          month_zhi=None, luck_pillars=[_lp(2025)],
                          last_complete_year=LAST)
    assert node is not None
    assert node.model_dump() == {"kind": "luck_transition",
                                 "year": 2025, "age": 25}


# ===== 同分取最近(D3) =====


def test_tie_break_picks_most_recent():
    """1980 生丙午日:1996 丙子与 2008 戊子同为冲日支(干均无克)→ 取 2008。"""
    node = pick_past_node(birth_year=1980, day_gan="丙", day_zhi="午",
                          month_zhi=None, luck_pillars=[],
                          last_complete_year=LAST)
    assert node is not None
    assert node.model_dump() == {"kind": "chong_day_zhi",
                                 "year": 2008, "age": 28}


# ===== 排除窗(D2)/时间窗(D4)/空池 =====


def test_exclusion_window_eats_all_candidates():
    """2000 生酉日酉月:窗口幸存年(2016 申/2024 辰/2025 巳)无一冲酉,
    卯年(2017 十七岁/2023 廿三岁)全被排除窗吃掉 → None,不放宽。"""
    node = pick_past_node(birth_year=2000, day_gan="甲", day_zhi="酉",
                          month_zhi="酉", luck_pillars=[],
                          last_complete_year=LAST)
    assert node is None


def test_age_below_floor_empty_pool():
    """2010 生:窗口起点 2026 > 2025 → 空池 None(16 岁下限,D4)。"""
    node = pick_past_node(birth_year=2010, day_gan="甲", day_zhi="寅",
                          month_zhi="戌", luck_pillars=[],
                          last_complete_year=LAST)
    assert node is None


def test_luck_start_below_age_floor_not_taken():
    """大运 start 2015(2000 生 = 5 岁)不取:下限之前的候选一律不看。"""
    node = pick_past_node(birth_year=2000, day_gan=None, day_zhi=None,
                          month_zhi=None, luck_pillars=[_lp(2015)],
                          last_complete_year=LAST)
    assert node is None


def test_future_and_current_incomplete_year_not_taken():
    """大运 start 2026 = last_complete_year+1(当年/未来)→ 不取,D4 只回望。"""
    node = pick_past_node(birth_year=2000, day_gan=None, day_zhi=None,
                          month_zhi=None, luck_pillars=[_lp(2026)],
                          last_complete_year=LAST)
    assert node is None


# ===== 参数校验(错误显式传播) =====


def test_half_day_pillar_raises():
    """日柱参数半截(一 None 一非 None)→ ValueError,不静默猜。"""
    with pytest.raises(ValueError, match="成对"):
        pick_past_node(birth_year=2000, day_gan="甲", day_zhi=None,
                       month_zhi=None, luck_pillars=[],
                       last_complete_year=LAST)


# ===== 流年干支配锁(year_pillar_ganzhi 泛化回归) =====


@pytest.mark.parametrize("year,gz", [
    (1990, "庚午"), (2016, "丙申"), (2024, "甲辰"), (2025, "乙巳"),
])
def test_year_pillar_ganzhi_known_values(year: int, gz: str):
    """立春口径流年干支已知值(选点判定的地基,锁死口径漂移)。"""
    assert year_pillar_ganzhi(year) == gz


# ===== 全链路接线(BaziEngine → BaziCalculateResponse) =====

_TZ = timezone(timedelta(hours=8))


def _calculate(birth: datetime, **kwargs):
    eng = BaziEngine(now=datetime(2026, 10, 20, tzinfo=_TZ))
    body = eng.calculate(birth=birth, gender="male", longitude=116.4074,
                         zi_hour_rule="zi_next_day", **kwargs)
    return BaziCalculateResponse(**body), body


def test_engine_wires_past_node():
    """1990-03-15 己卯日:酉年冲卯,窗口内仅 2017(27 岁,非排除窗)幸存
    (丁/己无克 → 非天克地冲);月支同为卯、大运 2017 交接同年被 rank1 遮蔽。"""
    resp, body = _calculate(datetime(1990, 3, 15, 14, 30, tzinfo=_TZ))
    assert resp.past_node is not None
    assert resp.past_node.model_dump() == {"kind": "chong_day_zhi",
                                           "year": 2017, "age": 27}
    # 接线镜像:用响应自己的柱/大运独立重算,结果一致(引擎传参正确)
    mirror = pick_past_node(
        birth_year=1990,
        day_gan=resp.pillars.day.gan if resp.pillars.day else None,
        day_zhi=resp.pillars.day.zhi if resp.pillars.day else None,
        month_zhi=resp.pillars.month.zhi if resp.pillars.month else None,
        luck_pillars=resp.luck_pillars,
        last_complete_year=2025,
    )
    assert mirror == resp.past_node


def test_engine_deterministic_same_input():
    birth = datetime(1990, 3, 15, 14, 30, tzinfo=_TZ)
    _, body1 = _calculate(birth)
    _, body2 = _calculate(birth)
    assert body1["past_node"] == body2["past_node"]


def test_engine_hour_unknown_still_picks_node():
    """时辰未知 + 答「否」(D3 区间测试日柱确定):四规则均不依赖时柱,
    照常出节点。注:late_night=None(不确定)恒命中日柱歧义 → 日柱规则
    缺席、落冲月支的路径已由 test_rank2_chong_month_zhi_when_day_unknown
    纯函数覆盖。"""
    resp, _ = _calculate(datetime(1990, 3, 15, 14, 30, tzinfo=_TZ),
                         hour_known=False, late_night=False)
    assert resp.past_node is not None
    assert resp.past_node.kind == "chong_day_zhi"
    assert resp.past_node.year == 2017
