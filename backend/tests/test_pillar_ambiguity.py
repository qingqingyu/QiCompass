"""节气边界柱歧义测试(S02/D10,docs/时辰未知-slices/S02)。

对盘事实(全部经 00:00/23:59 双探针 + lunar_python 1.4.8 实证):
- 1990-02-04(立春日):年柱 己巳→庚午 / 月柱 丁丑→戊寅(双歧义);正午
  占位落在立春后(庚午/戊寅);次日 02-05 无歧义
- 1990-03-06(惊蛰):月柱 戊寅→己卯(单歧义),年柱 庚午 两侧一致
- 1990-03-15(普通日):无任何歧义(与 S01 基础态一致)
- 1990-03-15 @ Asia/Shanghai + 75.99°E(喀什):offset ≈ −185.7min < −60,
  墙钟 [00:00, ~02:06) 日柱=戊寅(前一真太阳日),其后=己卯 → 日柱网命中;
  年/月探针两侧一致(庚午/己卯)无节气歧义
- 东八区标准经度(120°E ± EoT∈[−15,+17])offset 恒 > −60 → 日柱网恒不
  命中(防「误用 00:00/23:59 探针比日柱 → 所有普通日 day unknown」退化)
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from functools import partial
from zoneinfo import ZoneInfo

import pytest

import app.api.bazi as bazi_api
from app.core.content_hash import compute_content_hash
from app.core.true_solar_time import wall_day_start_before_changeover
from app.engine.bazi_engine import BaziEngine
from app.main import app
from app.models.bazi import BaziCalculateResponse

TZ8 = timezone(timedelta(hours=8))
NO_AMB = {"year": False, "month": False, "day": False}

# 东八区中部经度(S01 对盘同款)
BASE = {
    "timezone": "Asia/Shanghai",
    "gender": "male",
    "longitude": 116.4074,
    "zi_hour_rule": "zi_next_day",
}
LICHUN = {"birth_datetime": "1990-02-04T12:00:00"}   # 立春日(年+月双歧义)
JIE = {"birth_datetime": "1990-03-06T12:00:00"}      # 惊蛰(月柱歧义)
NORMAL = {"birth_datetime": "1990-03-15T12:00:00"}   # 普通日
KASHGAR_LON = 75.99  # 喀什经度(Asia/Shanghai 时区下 offset ≈ −185.7min)


async def _post(payload: dict) -> dict:
    from httpx import ASGITransport, AsyncClient
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        resp = await ac.post("/api/bazi/calculate", json=payload)
    assert resp.status_code == 200, resp.json()
    return resp.json()


async def _unknown(payload: dict, **overrides) -> dict:
    body = await _post({
        **BASE, **payload,
        "hour_known": False, "late_night": False, **overrides,
    })
    # 响应能过契约模型(Optional 化字段可解码,S05/S08 消费前提)
    BaziCalculateResponse(**body)
    return body


# ===== 1. 立春日:年柱 + 月柱双歧义,生肖 null =====


async def test_lichun_year_month_unknown_zodiac_null(fixed_now, monkeypatch):
    """立春日 + 时辰未知 → 年/月柱 null + 生肖系全 null + 大运置 unknown。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _unknown(LICHUN)

    # 歧义标记:年 + 月命中;late_night=False → 日柱确定
    assert body["pillar_ambiguity"] == {"year": True, "month": True,
                                        "day": False}
    assert body["pillars"]["year"] is None, "立春日年柱跨己巳/庚午,禁取任一侧"
    assert body["pillars"]["month"] is None, "立春日同时是节界,月柱丁丑/戊寅"
    assert body["pillars"]["hour"] is None
    assert body["pillars"]["day"] is not None  # 日柱与子时无关,照常(庚子)

    # 年支系派生全 null(生肖屏降级依赖,S08)
    assert body["year_branch_zodiac"] is None
    assert body["year_branch_friends"] is None
    assert body["year_branch_clash"] is None

    # 月柱歧义级联:大运从月柱起排 → 干支序列置 unknown(空列表,不猜)
    assert body["luck_pillars"] == []
    assert body["current_luck_pillar"] is None

    # 五行按已知柱(仅日柱)计数:和 = 2
    assert sum(body["element_balance"].values()) == 2

    # 喜忌 unknown_hour(时柱本就缺;月柱歧义下调候/得令亦无输入)
    assert body["day_master_strength"] == "unknown_hour"
    assert body["favorable_elements"] == []
    # 日柱在 → anchor 保留日主半句
    assert body["anchor_sentence"] is not None

    # 神煞只剩日支系条目;完整性标注
    positions = {s["position"] for s in body["shensha"]}
    assert positions <= {"日柱"}
    assert body["shensha_incomplete"] is True

    # 快照与响应同源
    assert body["calc_rule_snapshot"]["pillar_ambiguity"] == {
        "year": True, "month": True, "day": False,
    }

    # 确定性:同请求两次输出完全一致
    assert await _unknown(LICHUN) == body


async def test_lichun_all_pillars_null_when_late_night_unknown(fixed_now,
                                                               monkeypatch):
    """立春日 + 半夜不确定 → 四柱全 null 的诚实表达(极端终态)。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _post({**BASE, **LICHUN, "hour_known": False,
                        "late_night": None})

    assert body["pillar_ambiguity"] == {"year": True, "month": True,
                                        "day": True}
    for pos in ("year", "month", "day", "hour"):
        assert body["pillars"][pos] is None
    assert body["year_branch_zodiac"] is None
    assert body["luck_pillars"] == []
    assert sum(body["element_balance"].values()) == 0
    assert body["anchor_sentence"] is None
    assert body["shensha"] == []
    assert body["shensha_incomplete"] is True


# ===== 2. 节交界日:月柱歧义 → 大运 unknown =====


async def test_jie_boundary_month_unknown_luck_unknown(fixed_now, monkeypatch):
    """惊蛰日 + 时辰未知 → 月柱 null + 大运序列置 unknown,年柱/生肖照常。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _unknown(JIE)

    assert body["pillar_ambiguity"] == {"year": False, "month": True,
                                        "day": False}
    assert body["pillars"]["month"] is None, "惊蛰日月柱跨戊寅/己卯,不猜"
    assert body["pillars"]["year"]["gan_zhi"] == "庚午"  # 年柱不受节界影响
    assert body["pillars"]["day"] is not None

    # 年柱在 → 生肖系照常(供生肖屏对照:非立春日不降级)
    assert body["year_branch_zodiac"] == "Horse"
    assert body["year_branch_friends"] == ["Goat", "Tiger", "Dog"]
    assert body["year_branch_clash"] == "Rat"

    # 月柱歧义级联:大运置 unknown
    assert body["luck_pillars"] == []
    assert body["current_luck_pillar"] is None

    # 五行:年 + 日 = 4 字
    assert sum(body["element_balance"].values()) == 4
    assert body["day_master_strength"] == "unknown_hour"
    assert body["shensha_incomplete"] is True
    # 月支系神煞(天德/月德)无基准不出,其余照查
    assert "天德" not in {s["name"] for s in body["shensha"]}
    assert "月德" not in {s["name"] for s in body["shensha"]}


async def test_jie_boundary_known_hour_unaffected(fixed_now, monkeypatch):
    """同日已知时辰 → 永不触发比对:月柱确定(正午占位侧己卯),零歧义标记。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _post({**BASE, **JIE, "hour_known": True})
    assert body["pillars"]["month"]["gan_zhi"] == "己卯"
    assert body["pillar_ambiguity"] is None
    assert body["calc_rule_snapshot"]["pillar_ambiguity"] is None
    assert body["year_branch_zodiac"] == "Horse"
    assert body["luck_pillars"], "已知时辰大运照常"


# ===== 3. 普通日:无歧义,与 S01 基础态一致 =====


async def test_normal_day_no_ambiguity_matches_s01_baseline(fixed_now,
                                                            monkeypatch):
    """普通日 → 零歧义标记(全 False),年月日柱/大运与 S01 基础态一致。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _unknown(NORMAL)
    known = await _post({**BASE, **NORMAL, "hour_known": True})

    assert body["pillar_ambiguity"] == NO_AMB
    for pos in ("year", "month", "day"):
        assert body["pillars"][pos]["gan_zhi"] == known["pillars"][pos]["gan_zhi"]
    assert body["year_branch_zodiac"] == known["year_branch_zodiac"] == "Horse"
    assert [lp["gan_zhi"] for lp in body["luck_pillars"]] == \
        [lp["gan_zhi"] for lp in known["luck_pillars"]]
    assert body["calc_rule_snapshot"]["pillar_ambiguity"] == NO_AMB
    assert sum(body["element_balance"].values()) == 6  # 三柱 6 字


async def test_east8_standard_longitude_day_net_never_hits(fixed_now,
                                                           monkeypatch):
    """防退化回归:东八区普通日不得命中日柱网(误用 00:00/23:59 探针比日柱
    会让所有无时辰用户日柱 unknown,与 Parent D3 冲突)。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _unknown(NORMAL)
    assert body["pillar_ambiguity"]["day"] is False
    assert body["pillars"]["day"] is not None
    # 墙钟 00:00-23:59 的日柱探针本就分叉(晚子时换日)——证明判据没有
    # 走「比对探针日柱」的错误路径
    assert body["pillars"]["day"]["gan_zhi"] == "己卯"


# ===== 4. 西偏经度日柱网(与 late_night 同终态的两种来源) =====


async def test_west_offset_day_pillar_net_kashgar(fixed_now, monkeypatch):
    """Asia/Shanghai + 喀什经度 + late_night=False → 墙钟日凌晨段落入前一
    真太阳日,当日主体区间横跨两日柱 → 日柱 unknown(网命中,非 late_night)。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _post({**BASE, **NORMAL, "hour_known": False,
                        "late_night": False, "longitude": KASHGAR_LON})

    assert body["pillar_ambiguity"] == {"year": False, "month": False,
                                        "day": True}
    assert body["pillars"]["day"] is None
    # 年/月柱不受影响(探针两侧一致,庚午/己卯)
    assert body["pillars"]["year"]["gan_zhi"] == "庚午"
    assert body["pillars"]["month"]["gan_zhi"] == "己卯"
    assert body["year_branch_zodiac"] == "Horse"
    assert body["luck_pillars"], "月柱无歧义,大运照给"

    # 与 late_night=是 同终态:日主系派生置空(S09 每日运势全拦的契约前提)
    assert body["day_master_strength"] == "unknown_hour"
    assert body["anchor_sentence"] is None
    assert sum(body["element_balance"].values()) == 4

    # 对照:同经度 late_night=True(另一来源)同为 day unknown
    body_ln = await _post({**BASE, **NORMAL, "hour_known": False,
                           "late_night": True, "longitude": KASHGAR_LON})
    assert body_ln["pillar_ambiguity"]["day"] is True
    assert body_ln["pillars"]["day"] is None


def test_wall_day_start_before_changeover_unit():
    """日柱网判据:offset < −60(墙钟 00:00 调整后早于前一日 23:00)。"""
    assert wall_day_start_before_changeover(-185.69) is True   # 喀什
    assert wall_day_start_before_changeover(-60.01) is True
    # 恰为 −60:墙钟 00:00 调整后 = 前一日 23:00 整(换日点本身),
    # 已属次日子时盘,日起点不早于换日点 → 不命中
    assert wall_day_start_before_changeover(-60.0) is False
    assert wall_day_start_before_changeover(-59.9) is False
    assert wall_day_start_before_changeover(0.0) is False
    assert wall_day_start_before_changeover(16.5) is False      # EoT 上界
    assert wall_day_start_before_changeover(-28.46) is False    # 东八区中部


# ===== 5. hash 与快照 =====


def test_content_hash_marker_participation_unit():
    """歧义标记参与 hash(隔离验证:其余输入全同,仅标记不同 → hash 不同)。"""
    b = datetime(1990, 2, 4, 12, 0, tzinfo=TZ8)
    h_no = compute_content_hash(b, "male", 116.4074, "zi_next_day",
                                hour_known=False, late_night=False,
                                pillar_ambiguity=NO_AMB)
    variants = [
        {"year": True, "month": False, "day": False},
        {"year": False, "month": True, "day": False},
        {"year": False, "month": False, "day": True},
    ]
    assert len({h_no, *(compute_content_hash(
        b, "male", 116.4074, "zi_next_day", hour_known=False,
        late_night=False, pillar_ambiguity=v) for v in variants)}) == 4
    # 标记相同 → hash 稳定(确定性)
    assert h_no == compute_content_hash(b, "male", 116.4074, "zi_next_day",
                                        hour_known=False, late_night=False,
                                        pillar_ambiguity=NO_AMB)


def test_content_hash_marker_contract_violations():
    """契约违反显式报错:false 缺标记 / true 传标记(不静默按无歧义处理)。"""
    b = datetime(1990, 2, 4, 12, 0, tzinfo=TZ8)
    with pytest.raises(ValueError, match="pillar_ambiguity"):
        compute_content_hash(b, "male", 116.4074, "zi_next_day",
                             hour_known=False, late_night=False)
    with pytest.raises(ValueError, match="hour_known=true"):
        compute_content_hash(b, "male", 116.4074, "zi_next_day",
                             hour_known=True, late_night=None,
                             pillar_ambiguity=NO_AMB)


async def test_ambiguity_forks_content_hash_api(fixed_now, monkeypatch):
    """API 级:同日有/无歧义(经度致日柱网命中与否)→ 不同 hash;
    快照歧义状态与响应一致。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    east = await _unknown(NORMAL)                     # 东八区:无歧义
    west = await _post({**BASE, **NORMAL, "hour_known": False,
                        "late_night": False, "longitude": KASHGAR_LON})
    assert east["pillar_ambiguity"] == NO_AMB
    assert west["pillar_ambiguity"]["day"] is True
    assert east["content_hash"] != west["content_hash"]
    assert east["calc_rule_snapshot"]["pillar_ambiguity"] == \
        east["pillar_ambiguity"]
    assert west["calc_rule_snapshot"]["pillar_ambiguity"] == \
        west["pillar_ambiguity"]


# ===== 6. 引擎级直调(不依赖 API 归一层)=====


def test_engine_level_detection_deterministic(fixed_now):
    """直调引擎:立春日/节界/普通日三态 + 同输入同输出。"""
    tz = ZoneInfo("Asia/Shanghai")
    engine = BaziEngine(now=fixed_now)
    kwargs = dict(gender="male", longitude=116.4074,
                  zi_hour_rule="zi_next_day", hour_known=False,
                  late_night=False)

    r_lichun = engine.calculate(
        birth=datetime(1990, 2, 4, 12, 0, tzinfo=tz), **kwargs)
    r_jie = engine.calculate(
        birth=datetime(1990, 3, 6, 12, 0, tzinfo=tz), **kwargs)
    r_normal = engine.calculate(
        birth=datetime(1990, 3, 15, 12, 0, tzinfo=tz), **kwargs)

    assert r_lichun["pillar_ambiguity"] == {"year": True, "month": True,
                                            "day": False}
    assert r_jie["pillar_ambiguity"] == {"year": False, "month": True,
                                         "day": False}
    assert r_normal["pillar_ambiguity"] == NO_AMB
    # 确定性
    assert engine.calculate(
        birth=datetime(1990, 2, 4, 12, 0, tzinfo=tz), **kwargs) == r_lichun


async def test_pillar_ambiguity_logged(fixed_now, monkeypatch, caplog):
    """歧义命中审计留痕(错误显式传播:不静默置 null)。"""
    import logging
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    with caplog.at_level(logging.INFO, logger="app.engine.bazi_engine"):
        await _unknown(JIE)
    assert any("bazi.pillar_ambiguity" in rec.message for rec in caplog.records)
