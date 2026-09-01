"""时辰未知(hour_known=false)契约测试(S01,docs/时辰未知-slices/S01)。

覆盖 slice Acceptance 可自动验证项:
- 老客户端不传 hour_known/late_night → 与显式 hour_known=true 逐字段一致(回归对拍)
- hour_known=false + late_night=false → 三柱盘:hour null / 年月日柱正常 /
  unknown_hour / 喜忌空 / 神煞无时支条目 + shensha_incomplete / 大运照给 /
  五行统计和 = 6
- late_night=true 与 null(含缺省)→ 日柱 null + 日主派生输出置空(anchor/喜忌)
  (本文件对盘经度 116.4074°E 属东八区**西侧**,offset < 0,三态下「是/不确定」
  按 D3 区间测试仍歧义;东侧(如上海 121.5°E)「是」→ 确定次日日柱,归
  test_pillar_ambiguity.py 四象限,勿在此混入)
- 占位一致性:06:13 与 23:40 全响应一致(候选区间中点占位生效,占位不漏到响应)
- content_hash 分叉:true ≠ false;late_night 三态三个不同 hash
- calc_rule_snapshot 含 hour_known
- 「否占位 11:30 恰不跨换日边界」:正午已知盘 vs 无时辰同日,年月日柱相同
  (对盘样例取东八区中部经度 116°E;西偏经度日柱歧义场景归 S02,勿混入)

辅助单测:占位中点选取 / xiji unknown_hour 分支 / content_hash 时辰桶不参与。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from functools import partial
from zoneinfo import ZoneInfo

import pytest
from lunar_python import Solar
from pydantic import ValidationError

import app.api.bazi as bazi_api
from app.core.content_hash import compute_content_hash
from app.engine.bazi_engine import BaziEngine, hour_unknown_placeholder
from app.engine.pillars import build_pillars, compute_element_balance
from app.engine.xiji import compute_xiji
from app.main import app
from app.models.bazi import BaziCalculateRequest

TZ8 = timezone(timedelta(hours=8))
# 东八区中部经度(116°E):真太阳时偏移 ≈ −24 分钟(1990-03-15),
# 正午占位远离开日/换时辰边界 —— slice 指定的对盘经度
BASE = {
    "birth_datetime": "1990-03-15T12:00:00",
    "timezone": "Asia/Shanghai",
    "gender": "male",
    "longitude": 116.4074,
    "zi_hour_rule": "zi_next_day",
}

async def _post(payload: dict) -> dict:
    from httpx import ASGITransport, AsyncClient
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        resp = await ac.post("/api/bazi/calculate", json=payload)
    assert resp.status_code == 200, resp.json()
    return resp.json()


# ===== 1. 老客户端零破坏(回归对拍)=====


def test_request_model_defaults():
    """缺省 hour_known=True / late_night=None(老客户端不 422 的前提)。"""
    req = BaziCalculateRequest(**BASE)
    assert req.hour_known is True
    assert req.late_night is None


def test_request_model_rejects_non_bool_hour_known():
    # 注:pydantic lax 模式对 bool 接受 "yes"/"no"/"true" 等字符串强转,
    # 非 bool 词表外的值才拒绝(既有全局行为,不在本 slice 改)
    with pytest.raises(ValidationError):
        BaziCalculateRequest(**{**BASE, "hour_known": "maybe"})


async def test_legacy_client_response_matches_explicit_known_hour():
    """不传新字段 → 与显式 hour_known=true + late_night=null 逐字段一致。"""
    legacy = await _post(dict(BASE))
    explicit = await _post({**BASE, "hour_known": True, "late_night": None})
    assert legacy == explicit
    # 已知时辰路径形状未被新字段污染
    assert legacy["pillars"]["hour"] is not None
    assert legacy["pillars"]["day"] is not None
    assert legacy["shensha_incomplete"] is False
    assert legacy["calc_rule_snapshot"]["hour_known"] is True
    assert legacy["true_solar_time"] is not None
    assert legacy["meta"] is not None


# ===== 2. hour_known=false + late_night=false:三柱盘 =====


async def test_unknown_hour_late_night_false_three_pillars(fixed_now, monkeypatch):
    """late_night=false → 日柱确定,时柱 null,喜忌 unknown_hour,神煞/大运降级不降量。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    known = await _post({**BASE, "hour_known": True})   # 同日正午已知盘(对盘基准)
    body = await _post({**BASE, "hour_known": False, "late_night": False})

    # 时柱显式 null;年/月/日柱照常,且与正午已知盘逐字一致
    # (占位 12:00 恰不跨换日边界:23:40 输入也不会把日柱推到次日,见下个用例)
    assert body["pillars"]["hour"] is None
    for pos in ("year", "month", "day"):
        assert body["pillars"][pos]["gan_zhi"] == known["pillars"][pos]["gan_zhi"], (
            f"三柱部分应与正午已知盘一致:{pos}"
        )
    assert known["pillars"]["hour"]["gan_zhi"]  # 基准盘确实有时柱

    # 五行统计按三柱 6 字(各值之和 = 6,无标注字段)
    assert sum(body["element_balance"].values()) == 6
    assert sum(known["element_balance"].values()) == 8

    # 喜忌:D4 unknown_hour,与从格 special_pattern 同构的诚实降级
    assert body["day_master_strength"] == "unknown_hour"
    assert body["favorable_elements"] == []
    assert body["unfavorable_elements"] == []
    assert body["useful_god_candidates"] == []
    assert body["ten_god_weights"] == {}
    assert body["pattern_hint"] is None
    assert body["tiaoshou_applied"] is False
    assert "时辰未知" in body["xiji_method"]

    # anchor:日主半句保留 + 时辰未知降级(日主在,旺衰/喜忌不编)
    assert body["anchor_sentence"] is not None
    assert "出生时辰未知" in body["anchor_sentence"]
    assert body["anchor_sentence"].startswith("你的日主是")

    # 神煞:无时支条目 + 完整性标注(不静默);恰为已知盘去掉时柱条目
    positions = {s["position"] for s in body["shensha"]}
    assert "时柱" not in positions
    assert positions <= {"年柱", "月柱", "日柱"}
    assert body["shensha_incomplete"] is True
    expected_subset = [s for s in known["shensha"] if s["position"] != "时柱"]
    assert body["shensha"] == expected_subset

    # 大运照给(弱依赖误差 v1 接受):干支序列与已知盘完全一致
    assert body["luck_pillars"]
    assert [lp["gan_zhi"] for lp in body["luck_pillars"]] == \
        [lp["gan_zhi"] for lp in known["luck_pillars"]]

    # 生肖不受时柱影响(年柱照常)
    assert body["year_branch_zodiac"] == known["year_branch_zodiac"] == "Horse"

    # 契约:含时辰信息的字段不漏占位假精度
    assert body["true_solar_time"] is None
    assert body["meta"] is None
    assert body["calc_rule_snapshot"]["hour_known"] is False


# ===== 3. late_night=true / null:日柱歧义 =====


@pytest.mark.parametrize("late_night_payload", [
    {"late_night": True},
    {"late_night": None},
    {},  # 缺省 = 不确定,同 None
], ids=["true", "null", "omitted"])
async def test_unknown_hour_day_pillar_unknown(late_night_payload, fixed_now,
                                               monkeypatch):
    """late_night != False → 日柱也置 null,日主系派生输出一并置空(不猜)。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    body = await _post({**BASE, "hour_known": False, **late_night_payload})

    assert body["pillars"]["hour"] is None
    assert body["pillars"]["day"] is None, (
        "日柱歧义必须显式 null,禁止取中点/默认时辰"
    )
    for pos in ("year", "month"):
        assert body["pillars"][pos]["gan_zhi"]

    # 五行按已知柱(年+月)计数:和 = 4
    assert sum(body["element_balance"].values()) == 4

    # 日主系派生输出置空
    assert body["day_master_strength"] == "unknown_hour"
    assert body["favorable_elements"] == []
    assert body["unfavorable_elements"] == []
    assert body["anchor_sentence"] is None  # anchor 是日主句,无日主则整体无

    # 神煞:日干系(A 类 7 条)无基准不出,三合双查退化为仅年支基准;
    # 命中只可能在年柱/月柱
    positions = {s["position"] for s in body["shensha"]}
    assert positions <= {"年柱", "月柱"}
    assert body["shensha_incomplete"] is True

    # 确定性:同请求两次输出完全一致
    body2 = await _post({**BASE, "hour_known": False, **late_night_payload})
    assert body == body2


# ===== 4. 占位一致性:时辰部分无论传什么都一样 =====


async def test_placeholder_noon_same_output_any_input_time(fixed_now, monkeypatch):
    """06:13 与 23:40(hour_known=false)→ 全响应逐字段一致(含 content_hash)。

    23:40 已过 23:00 墙钟换日边界,若占位未生效会把日柱/时辰桶推到次日;
    「否」中点 11:30 占位下两请求输出完全相同 → 占位生效且占位值未漏到响应。
    """
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    early = await _post({**BASE, "birth_datetime": "1990-03-15T06:13:00",
                         "hour_known": False, "late_night": False})
    late = await _post({**BASE, "birth_datetime": "1990-03-15T23:40:00",
                        "hour_known": False, "late_night": False})
    assert early == late
    # 占位不漏到响应:唯二含时刻的字段均为 null
    assert early["true_solar_time"] is None
    assert early["meta"] is None

    # 对照:已知时辰路径 23:40 的日柱确实换日(setSect(1) 晚子时归次日),
    # 证明无时辰盘的日柱来自 11:30 占位而非透传输入时刻
    known_late = await _post({**BASE, "birth_datetime": "1990-03-15T23:40:00",
                              "hour_known": True})
    known_noon = await _post({**BASE, "birth_datetime": "1990-03-15T12:00:00",
                              "hour_known": True})
    assert known_late["pillars"]["day"]["gan_zhi"] != \
        known_noon["pillars"]["day"]["gan_zhi"], (
        "对拍前提失效:23:40 与 12:00 已知盘日柱应不同(晚子时换日)"
    )
    assert early["pillars"]["day"]["gan_zhi"] == \
        known_noon["pillars"]["day"]["gan_zhi"]


def test_engine_level_placeholder_normalization(fixed_now):
    """直调引擎同样占位归一(不依赖 API 层):同日期任意时辰 → 同输出。"""
    tz = ZoneInfo("Asia/Shanghai")
    engine = BaziEngine(now=fixed_now)
    kwargs = dict(gender="male", longitude=116.4074,
                  zi_hour_rule="zi_next_day", hour_known=False,
                  late_night=False)
    r1 = engine.calculate(
        birth=datetime(1990, 3, 15, 23, 40, tzinfo=tz), **kwargs)
    r2 = engine.calculate(
        birth=datetime(1990, 3, 15, 6, 13, tzinfo=tz), **kwargs)
    assert r1 == r2


async def test_unknown_hour_dst_gap_input_normalized(fixed_now, monkeypatch):
    """时辰未知 + 钟面落在夏令时跳过段 → 按 12:00 归一解释,与时辰噪声零关联。

    未知时辰下「钟面是否在跳过/回拨段」无从谈起:API 层先归一再解释时区,
    输出与同日正午请求完全一致,且不出时制告警(对比已知时辰路径会告警)。
    """
    from tests.fixtures.tz_dst import find_dst_fold_minute
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    gap = find_dst_fold_minute("Asia/Shanghai", datetime(1988, 4, 15, 0, 30), 96)
    payload_common = {
        "timezone": "Asia/Shanghai", "gender": "male",
        "longitude": 116.4074, "zi_hour_rule": "zi_next_day",
        "hour_known": False, "late_night": False,
    }
    body_gap = await _post({**payload_common, "birth_datetime": gap.isoformat()})
    body_noon = await _post({
        **payload_common,
        "birth_datetime": f"{gap.year:04d}-{gap.month:02d}-{gap.day:02d}T12:00:00",
    })
    assert body_gap == body_noon
    assert "不存在" not in (body_gap["boundary_warning"] or "")
    assert "请核对" not in (body_gap["boundary_warning"] or "")


# ===== 5. content_hash 分叉 =====


async def test_content_hash_forks_by_hour_known_and_late_night(fixed_now,
                                                               monkeypatch):
    """同出生信息:hour_known true≠false;false 下 late_night 三态三个 hash。"""
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    h_known = (await _post(dict(BASE)))["content_hash"]
    h_known_explicit = (await _post({**BASE, "hour_known": True}))["content_hash"]
    h_false_t = (await _post({**BASE, "hour_known": False,
                              "late_night": True}))["content_hash"]
    h_false_f = (await _post({**BASE, "hour_known": False,
                              "late_night": False}))["content_hash"]
    h_false_n = (await _post({**BASE, "hour_known": False}))["content_hash"]
    h_false_n_explicit = (await _post({**BASE, "hour_known": False,
                                       "late_night": None}))["content_hash"]

    assert h_known == h_known_explicit  # 显式 true 与缺省同 hash(公式不变)
    assert h_known != h_false_f          # 补时辰 → 视为新命盘,hash 必须变
    assert len({h_false_t, h_false_f, h_false_n}) == 3, (
        "late_night 决定日柱歧义状态,三态必须三个不同 hash(缓存碰撞防护)"
    )
    assert h_false_n == h_false_n_explicit  # 缺省 = None

    # 时辰桶不参与:同日期不同时辰,unknown 盘 hash 相同
    h_0613 = (await _post({**BASE, "birth_datetime": "1990-03-15T06:13:00",
                           "hour_known": False, "late_night": False})
              )["content_hash"]
    h_2340 = (await _post({**BASE, "birth_datetime": "1990-03-15T23:40:00",
                           "hour_known": False, "late_night": False})
              )["content_hash"]
    assert h_0613 == h_2340 == h_false_f


def test_compute_content_hash_unit():
    """hash 函数单测:true 路径公式不变(时辰桶参与);false 路径日期参与。"""
    b_0613 = datetime(1990, 3, 15, 6, 13, tzinfo=TZ8)
    b_2340 = datetime(1990, 3, 15, 23, 40, tzinfo=TZ8)
    # 普通日无歧义终态标记(1990-03-15@116.4074 探针无年月分叉,
    # day 随 late_night:!= False → True)
    no_amb = {"year": False, "month": False, "day": False}

    # true:不同时辰桶 → 不同 hash(既有语义回归)
    assert compute_content_hash(b_0613, "male", 116.4074, "zi_next_day") != \
        compute_content_hash(b_2340, "male", 116.4074, "zi_next_day")
    # false:时辰桶不参与 → 同日期同 hash
    assert compute_content_hash(b_0613, "male", 116.4074, "zi_next_day",
                                hour_known=False, late_night=False,
                                pillar_ambiguity=no_amb) == \
        compute_content_hash(b_2340, "male", 116.4074, "zi_next_day",
                             hour_known=False, late_night=False,
                             pillar_ambiguity=no_amb)
    # false:跨日期 → 不同 hash
    assert compute_content_hash(b_0613, "male", 116.4074, "zi_next_day",
                                hour_known=False, late_night=False,
                                pillar_ambiguity=no_amb) != \
        compute_content_hash(datetime(1990, 3, 16, 6, 13, tzinfo=TZ8),
                             "male", 116.4074, "zi_next_day",
                             hour_known=False, late_night=False,
                             pillar_ambiguity=no_amb)
    # false:late_night 三态分叉
    hashes = {
        compute_content_hash(
            b_0613, "male", 116.4074, "zi_next_day", hour_known=False,
            late_night=v,
            pillar_ambiguity={"year": False, "month": False,
                              "day": v is not False},
        )
        for v in (True, False, None)
    }
    assert len(hashes) == 3


# ===== 6. 喜忌引擎 unknown_hour 分支(单元)=====


def _pillars_at_noon(birth_naive: datetime):
    ec = Solar.fromDate(birth_naive).getLunar().getEightChar()
    ec.setSect(1)
    return build_pillars(ec)


def test_xiji_unknown_hour_unit():
    """时柱 None 或日柱 None → unknown_hour + 空喜忌(镜像从格降级)。"""
    pillars = _pillars_at_noon(datetime(1990, 3, 15, 12, 0))

    full = compute_xiji(pillars, compute_element_balance(pillars))
    assert full.day_master_strength != "unknown_hour"  # 普通盘对照组

    pillars.hour = None
    r = compute_xiji(pillars, compute_element_balance(pillars))
    assert r.day_master_strength == "unknown_hour"
    assert r.favorable_elements == []
    assert r.unfavorable_elements == []
    assert r.useful_god_candidates == []
    assert r.ten_god_weights == {}
    assert r.pattern_hint is None

    pillars.day = None  # 日柱也歧义(小时柱有无均应降级)
    r2 = compute_xiji(pillars, compute_element_balance(pillars))
    assert r2.day_master_strength == "unknown_hour"

    pillars2 = _pillars_at_noon(datetime(1990, 3, 15, 12, 0))
    pillars2.day = None  # 仅日柱歧义(时柱在)
    r3 = compute_xiji(pillars2, compute_element_balance(pillars2))
    assert r3.day_master_strength == "unknown_hour"


def test_element_balance_counts_known_pillars_only():
    pillars = _pillars_at_noon(datetime(1990, 3, 15, 12, 0))
    assert sum(compute_element_balance(pillars).model_dump().values()) == 8
    pillars.hour = None
    assert sum(compute_element_balance(pillars).model_dump().values()) == 6
    pillars.day = None
    assert sum(compute_element_balance(pillars).model_dump().values()) == 4


# ===== 7. 占位中点(D3 修订):候选区间中点选取 =====


def test_hour_unknown_placeholder_midpoint():
    """占位 = 候选区间中点(D3 2026-09-01 修订):
    否 [00:00,23:00) → 11:30 / 是 [23:00,24:00) → 23:30 / 不确定 → 12:00。

    「是」取 23:30 是关键行为:日柱经区间测试判「确定」时,中点保证落在
    该确定日柱的区间内(东偏 → 换日窗 → 次日;西偏 ≤ −60 → 同日)。
    """
    b = datetime(1990, 3, 15, 6, 13)
    assert hour_unknown_placeholder(b, False) == datetime(1990, 3, 15, 11, 30)
    assert hour_unknown_placeholder(b, True) == datetime(1990, 3, 15, 23, 30)
    assert hour_unknown_placeholder(b, None) == datetime(1990, 3, 15, 12, 0)
    # 幂等:已是占位值的输入再归一不变
    assert hour_unknown_placeholder(
        hour_unknown_placeholder(b, True), True,
    ) == datetime(1990, 3, 15, 23, 30)
    # 保墙钟日期与时区
    tz = timezone(timedelta(hours=8))
    b2 = datetime(1990, 3, 15, 23, 40, tzinfo=tz)
    assert hour_unknown_placeholder(b2, True) == \
        datetime(1990, 3, 15, 23, 30, tzinfo=tz)


async def test_day_pillar_unknown_logged(fixed_now, monkeypatch, caplog):
    """日柱置 null 时审计日志留痕(D3 区间测试命中输入,错误显式传播)。"""
    import logging
    monkeypatch.setattr(bazi_api, "BaziEngine",
                        partial(BaziEngine, now=fixed_now))
    with caplog.at_level(logging.INFO, logger="app.engine.bazi_engine"):
        await _post({**BASE, "hour_known": False, "late_night": True})
    assert any("bazi.day_pillar_unknown" in rec.message for rec in caplog.records)
