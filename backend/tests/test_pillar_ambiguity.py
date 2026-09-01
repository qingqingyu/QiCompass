"""节气边界柱歧义测试(S02/D10,docs/时辰未知-slices/S02 修订版)。

对盘事实(全部经 00:00/23:59 双探针 + lunar_python 1.4.8 实证):
- 1990-02-04(立春日):年柱 己巳→庚午 / 月柱 丁丑→戊寅(双歧义);正午
  占位落在立春后(庚午/戊寅);次日 02-05 无歧义
- 1990-03-06(惊蛰):月柱 戊寅→己卯(单歧义),年柱 庚午 两侧一致
- 1990-03-15(普通日):无任何歧义(与 S01 基础态一致)
- 1990-03-15 @ Asia/Shanghai + 75.99°E(喀什,offset ≈ −185.7):年/月探针
  两侧一致(庚午/己卯);日柱:D3 区间测试 否→歧义 / 是→确定(同日 己卯,
  占位 23:30 → 真太阳时 20:24)
- 日柱判据 = D3 三步区间测试(true_solar_time.day_pillar_ambiguous,单一
  事实源,2026-09-01 修订):西偏答「是」确定 / 东偏答「否」歧义等场景
  由区间是否横跨换日点自然得出,不再用 offset < −60 单边规则,也不走
  00:00/23:59 探针比日柱(那会让所有无时辰用户 day unknown,退化)
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from functools import partial
from zoneinfo import ZoneInfo

import pytest

import app.api.bazi as bazi_api
from app.core.content_hash import compute_content_hash
from app.core.true_solar_time import day_pillar_ambiguous
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
KASHGAR_LON = 75.99    # 喀什(Asia/Shanghai 时区下 1990-03-15 offset ≈ −185.7)
SHANGHAI_LON = 121.5   # 上海东偏(1990-12-25 offset ≈ +5.5;冬至后非节气界)
CHENGDU_LON = 104.1    # 成都西偏(1990-12-25 offset ≈ −64.1)
FUYUAN_LON = 134.3     # 抚远东偏(1990-03-15 offset ≈ +47.6)
DEC_NORMAL = {"birth_datetime": "1990-12-25T12:00:00"}  # 12 月普通日(非中国夏令时)


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


async def test_east8_standard_longitude_day_determined(fixed_now,
                                                        monkeypatch):
    """防退化回归:东八区中部普通日(1990-03-15 offset ≈ −24)+ 否 → 日柱
    确定(误用 00:00/23:59 探针比日柱会让所有无时辰用户日柱 unknown,
    与 Parent D3 冲突;offset > 0 的东偏日才歧义,见下节四象限)。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _unknown(NORMAL)
    assert body["pillar_ambiguity"]["day"] is False
    assert body["pillars"]["day"] is not None
    # 墙钟 00:00-23:59 的日柱探针本就分叉(晚子时换日)——证明判据没有
    # 走「比对探针日柱」的错误路径
    assert body["pillars"]["day"]["gan_zhi"] == "己卯"


# ===== 4. 日柱歧义:D3 区间测试四象限(场景表全部行,对盘验证) =====


def test_day_pillar_ambiguous_d3_interval_unit():
    """D3 区间测试判据单元验证(单一事实源,无 −60 魔数):场景表全部行 +
    边界语义。候选区间:否 [0,1380) / 是 [1380,1440) / 不确定 [0,1440);
    歧义 ⟺ 真太阳时区间**内部严格**包含一个 1380+1440k 换日点。"""
    # ---- 场景表(docs/时辰未知设计决策.md D3,offset = 真太阳时−墙钟)----
    assert day_pillar_ambiguous(True, -176.0) is False  # 喀什×是:确定(20:04-21:04 同日)
    assert day_pillar_ambiguous(False, -176.0) is True  # 喀什×否:歧义
    assert day_pillar_ambiguous(True, -63.0) is False   # 成都×是:确定
    assert day_pillar_ambiguous(False, 6.0) is True     # 上海×否:歧义(22:54-23:00 落次日)
    assert day_pillar_ambiguous(False, 57.0) is True    # 抚远×否:歧义(22:00-23:00 落次日)
    # 东八区中部普通日(EoT<0 日期,offset ≈ −24)× 否 → 不命中
    assert day_pillar_ambiguous(False, -24.02) is False
    # 「是」× 东偏 → 确定(区间整体落换日窗 → 次日日柱,占位 23:30 推出)
    assert day_pillar_ambiguous(True, 6.0) is False

    # 「不确定」恒歧义:任何 24h 真太阳时区间内部必含一个换日点
    # (offset 恰 −60 的测度零退化除外,见下)——区间测试自然结论,无独立分支
    for off in (-185.69, -64.09, -59.99, -24.02, 0.0, 5.51, 47.55):
        assert day_pillar_ambiguous(None, off) is True, off

    # ---- 边界:换日点恰贴区间端点不算内部(整段区间仍属同一日柱)----
    # offset −60:否 → 真太阳时 [−60, 1320),换日点 −60/1380 均贴端点 → 确定
    assert day_pillar_ambiguous(False, -60.0) is False
    # 是 → [1320, 1380):1380 贴右端 → 确定(当日最后一段,整体同日)
    assert day_pillar_ambiguous(True, -60.0) is False
    # 不确定 → [−60, 1380):两端恰是换日点 → 测度零退化,真太阳日与墙钟日
    # 完全对齐,日柱确定(浮点 offset 实际不会精确命中,语义上确定是对的)
    assert day_pillar_ambiguous(None, -60.0) is False
    # 是 × offset ∈ (−60, 0):区间内部含 1380 → 歧义(如 −59 → [1321,1381))
    assert day_pillar_ambiguous(True, -59.0) is True
    # offset 0:是 → [1380,1440) 1380 贴左端 → 确定(整个区间是次日子时盘)
    assert day_pillar_ambiguous(True, 0.0) is False


async def test_west_offset_late_night_no_ambiguous_kashgar(fixed_now,
                                                           monkeypatch):
    """Asia/Shanghai + 喀什经度 + late_night=False → 真太阳时候选区间
    [前日20:54, 当日19:54) 横跨前日 23:00 换日点(墙钟 00:00-02:06 为前一日
    日柱)→ 日柱 unknown(区间测试命中)。"""
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

    # 日柱歧义终态:日主系派生置空(S09 每日运势全拦的契约前提)
    assert body["day_master_strength"] == "unknown_hour"
    assert body["anchor_sentence"] is None
    assert sum(body["element_balance"].values()) == 4

    # hash 分叉:同日同经度,仅 late_night 否/是 不同 → 歧义状态不同 → 不同 hash
    body_yes = await _post({**BASE, **NORMAL, "hour_known": False,
                            "late_night": True, "longitude": KASHGAR_LON})
    assert body["content_hash"] != body_yes["content_hash"]


async def test_west_offset_late_night_yes_determined_kashgar(fixed_now,
                                                             monkeypatch):
    """喀什 + late_night=True → **日柱确定,同日**(场景表「过度降级」修正行)。

    offset ≈ −185.7 → 真太阳时候选区间 [23:00,24:00)−185.7 = [20:04,21:04),
    不含 23:00 换日点 → 同日;占位 23:30 → 真太阳时 20:24 → 当日日柱,
    与正午已知盘对盘一致。防旧「答是即 unknown」过度降级回归(S01 遗留判据)。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _post({**BASE, **NORMAL, "hour_known": False,
                        "late_night": True, "longitude": KASHGAR_LON})
    known = await _post({**BASE, **NORMAL, "hour_known": True,
                         "longitude": KASHGAR_LON})  # 正午已知盘(对盘基准)

    assert body["pillar_ambiguity"] == NO_AMB
    assert body["pillars"]["hour"] is None
    assert body["pillars"]["day"] is not None
    assert body["pillars"]["day"]["gan_zhi"] == \
        known["pillars"]["day"]["gan_zhi"] == "己卯"

    # 日柱在 → 日主系输出恢复:anchor 有日主半句(喜忌仍 unknown_hour,时柱缺)
    assert body["anchor_sentence"] is not None
    assert "出生时辰未知" in body["anchor_sentence"]
    assert body["day_master_strength"] == "unknown_hour"
    assert sum(body["element_balance"].values()) == 6  # 三柱 6 字
    assert body["year_branch_zodiac"] == "Horse"


async def test_west_offset_late_night_yes_determined_chengdu(fixed_now,
                                                             monkeypatch):
    """成都 104.1°E(1990-12-25 offset ≈ −64)+ 是 → 日柱确定(场景表行)。

    真太阳时候选区间 [21:56,22:56) 不含 23:00 → 同日;占位 23:30 →
    真太阳时 22:26 → 当日日柱甲子,与正午已知盘对盘一致。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _post({**BASE, **DEC_NORMAL, "hour_known": False,
                        "late_night": True, "longitude": CHENGDU_LON})
    known = await _post({**BASE, **DEC_NORMAL, "hour_known": True,
                         "longitude": CHENGDU_LON})

    assert body["pillar_ambiguity"] == NO_AMB
    assert body["pillars"]["day"]["gan_zhi"] == \
        known["pillars"]["day"]["gan_zhi"] == "甲子"
    assert body["pillars"]["year"]["gan_zhi"] == "庚午"
    assert body["pillars"]["month"]["gan_zhi"] == "戊子"
    assert body["anchor_sentence"] is not None
    assert body["luck_pillars"], "月柱无歧义,大运照给"


async def test_east_offset_late_night_no_ambiguous_shanghai(fixed_now,
                                                            monkeypatch):
    """上海 121.5°E(1990-12-25 offset ≈ +5.5)+ 否 → 日柱歧义
    (场景表「静默给错日柱」修正行)。

    真太阳时候选区间 [00:06,23:06) 内部含 23:00 换日点 → 墙钟 22:54-23:00
    落次日。旧单边 offset<−60 规则会漏报为「确定」并静默给错日柱(S02 遗留)。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _post({**BASE, **DEC_NORMAL, "hour_known": False,
                        "late_night": False, "longitude": SHANGHAI_LON})

    assert body["pillar_ambiguity"] == {"year": False, "month": False,
                                        "day": True}
    assert body["pillars"]["day"] is None
    assert body["anchor_sentence"] is None
    # 年/月柱照常(12 月下旬非节气界,探针两侧庚午/戊子)
    assert body["pillars"]["year"]["gan_zhi"] == "庚午"
    assert body["pillars"]["month"]["gan_zhi"] == "戊子"
    assert body["year_branch_zodiac"] == "Horse"


async def test_east_offset_late_night_no_ambiguous_fuyuan(fixed_now,
                                                          monkeypatch):
    """抚远 134.3°E(1990-03-15 offset ≈ +47.6)+ 否 → 日柱歧义(场景表行)。

    真太阳时候选区间 [00:48,23:48) 内部含 23:00 → 墙钟 22:12-23:00 落次日。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _post({**BASE, **NORMAL, "hour_known": False,
                        "late_night": False, "longitude": FUYUAN_LON})

    assert body["pillar_ambiguity"] == {"year": False, "month": False,
                                        "day": True}
    assert body["pillars"]["day"] is None
    assert body["anchor_sentence"] is None
    assert body["year_branch_zodiac"] == "Horse"
    assert sum(body["element_balance"].values()) == 4


async def test_east_offset_late_night_yes_determined_next_day_shanghai(
        fixed_now, monkeypatch):
    """上海 121.5°E + 是 → 日柱确定且为**次日**(区间测试关键行为)。

    真太阳时候选区间 [23:06, 00:06) 不含 23:00 → 确定;占位取区间中点
    23:30,经 setSect(1) 落换日窗 → 次日日柱。对盘:与同日 23:40 已知盘
    (晚子时归次日)及次日正午已知盘一致,≠ 当日正午已知盘。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _post({**BASE, **DEC_NORMAL, "hour_known": False,
                        "late_night": True, "longitude": SHANGHAI_LON})
    known_late = await _post({**BASE,
                              "birth_datetime": "1990-12-25T23:40:00",
                              "hour_known": True,
                              "longitude": SHANGHAI_LON})
    known_noon = await _post({**BASE, **DEC_NORMAL, "hour_known": True,
                              "longitude": SHANGHAI_LON})
    known_next = await _post({**BASE,
                              "birth_datetime": "1990-12-26T12:00:00",
                              "hour_known": True,
                              "longitude": SHANGHAI_LON})

    assert body["pillar_ambiguity"] == NO_AMB
    day = body["pillars"]["day"]["gan_zhi"]
    assert day == known_late["pillars"]["day"]["gan_zhi"] == \
        known_next["pillars"]["day"]["gan_zhi"] == "乙丑"
    assert day != known_noon["pillars"]["day"]["gan_zhi"]  # 当日 = 甲子
    assert body["anchor_sentence"] is not None  # 日柱在,日主半句保留
    assert sum(body["element_balance"].values()) == 6


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
    """API 级:同日有/无歧义(经度致 D3 区间测试命中与否)→ 不同 hash;
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
