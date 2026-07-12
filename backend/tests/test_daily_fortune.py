"""POST /api/bazi/daily-fortune 测试 + 引擎单测。

覆盖(最终方案 §2.5):
- 流日柱 == lunar_python `EightChar.getDay()` (sect=1)
- 12 时辰条数 + 十神七值集合
- 时辰冲 == lunar_python `Lunar.getTimeChong()`
- 流日冲 chong_targets 命中四柱地支逻辑
- 黄历宜/忌非空(除特殊节气,样本避开)
- 明日预告三字段齐且 == target_date+1 重排
- current_hour_index 永远 None(服务端不替客户端决策)
- 农历日期格式形如「六月廿八」
- FastAPI 路由注册存在
- 引擎异常显式传播(未知天干 → ValueError → 422)
"""

from __future__ import annotations

from datetime import date, timezone, timedelta

import pytest
from httpx import ASGITransport, AsyncClient
from lunar_python import Solar

from app.engine.daily_fortune import compute_daily_fortune
from app.main import app
from app.models.daily_fortune import ChartPayload, PillarRef

TZ8 = timezone(timedelta(hours=8))

# 1990-03-15 14:30 北京 男 命盘:庚午 / 己卯 / 己卯 / 辛未,日主己土 weak
DOC_CHART = ChartPayload(
    day_master="己",
    day_master_element="earth",
    day_master_strength="weak",
    favorable_elements=["火", "土"],
    unfavorable_elements=["水", "金"],
    four_pillars={
        "year": PillarRef(gan="庚", zhi="午"),
        "month": PillarRef(gan="己", zhi="卯"),
        "day": PillarRef(gan="己", zhi="卯"),
        "hour": PillarRef(gan="辛", zhi="未"),
    },
)


async def _post(payload: dict) -> tuple[int, dict, dict]:
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        resp = await ac.post("/api/bazi/daily-fortune", json=payload)
    return resp.status_code, resp.json(), dict(resp.headers)


def _make_request(target: date, chart: ChartPayload = DOC_CHART) -> dict:
    return {
        "chart_hash": "test_hash_doc_001",
        "target_date": target.isoformat(),
        "chart_payload": chart.model_dump(),
    }


# ===== 引擎单测 =====

def test_day_pillar_matches_lunar_test_suite():
    """固定 target_date → day_pillar == lunar_python EightChar.getDay(sect=1)。"""
    target = date(2026, 7, 12)
    expected = (
        Solar.fromYmdHms(2026, 7, 12, 12, 0, 0)
        .getLunar().getEightChar()
    )
    expected.setSect(1)

    resp = compute_daily_fortune(
        chart_hash="t1", target_date=target, chart_payload=DOC_CHART,
    )
    assert resp.day_pillar == expected.getDay()
    assert resp.day_pillar == "丁亥"


def test_12_hour_pillars_count_and_relations():
    """12 条 + 十神 ∈ {比肩/劫财/食神/伤官/偏财/正财/七杀/正官/偏印/正印}。"""
    resp = compute_daily_fortune(
        chart_hash="t2", target_date=date(2026, 7, 12),
        chart_payload=DOC_CHART,
    )
    assert len(resp.hour_pillars) == 12
    valid_relations = {
        "比肩", "劫财", "食神", "伤官",
        "偏财", "正财", "七杀", "正官",
        "偏印", "正印",
    }
    for hp in resp.hour_pillars:
        assert hp.hour, "hour 字段不应为空"
        assert hp.time_range, "time_range 字段不应为空"
        assert len(hp.pillar) == 2, f"pillar 应为 2 字干支,实际={hp.pillar!r}"
        assert hp.relation in valid_relations, (
            f"非法十神:{hp.relation!r}")


def test_hour_chong_consistency():
    """封装层 chong == lunar_python `Lunar.getTimeChong()`。"""
    target = date(2026, 7, 12)
    resp = compute_daily_fortune(
        chart_hash="t3", target_date=target, chart_payload=DOC_CHART,
    )
    # 12 时辰的中点时间表(与引擎 HOUR_TABLE 一致)
    mid_minutes = [(0, 30), (2, 0), (4, 0), (6, 0), (8, 0), (10, 0),
                    (12, 0), (14, 0), (16, 0), (18, 0), (20, 0), (22, 0)]
    for hp, (h, m) in zip(resp.hour_pillars, mid_minutes):
        lunar = Solar.fromYmdHms(2026, 7, 12, h, m, 0).getLunar()
        expected = lunar.getTimeChong()
        assert hp.chong == (expected or None), (
            f"时辰 {hp.hour} chong 不一致:封装={hp.chong!r} 库={expected!r}")


def test_day_chong_targets_hit_four_pillars():
    """流日冲命中四柱地支时 chong_targets 非空,未命中时空。

    2026-07-12 → 丁亥日,亥冲巳;DOC_CHART 四柱(午卯卯未)无巳 → 空列表。
    构造一个含「巳」的 chart_payload 验证命中。
    """
    # 用例 1:无命中
    resp1 = compute_daily_fortune(
        chart_hash="t4a", target_date=date(2026, 7, 12),
        chart_payload=DOC_CHART,
    )
    # 2026-07-12 丁亥日,亥冲巳
    assert resp1.day_chong == "巳"
    assert resp1.day_chong_targets == [], (
        f"DOC_CHART 四柱无巳,应空,实际={resp1.day_chong_targets}")

    # 用例 2:命中(构造含 巳 的 chart_payload)
    chart_with_si = ChartPayload(
        day_master="己", day_master_element="earth",
        day_master_strength="weak",
        favorable_elements=["火", "土"], unfavorable_elements=["水", "金"],
        four_pillars={
            "year": PillarRef(gan="庚", zhi="午"),
            "month": PillarRef(gan="己", zhi="卯"),
            "day": PillarRef(gan="己", zhi="巳"),  # 改为巳
            "hour": PillarRef(gan="辛", zhi="未"),
        },
    )
    resp2 = compute_daily_fortune(
        chart_hash="t4b", target_date=date(2026, 7, 12),
        chart_payload=chart_with_si,
    )
    assert resp2.day_chong == "巳"
    assert resp2.day_chong_targets == ["日支巳"], (
        f"应命中日支巳,实际={resp2.day_chong_targets}")


def test_huangli_yi_ji_nonempty():
    """宜/忌均非空(2026-07-12 已实测非空)。"""
    resp = compute_daily_fortune(
        chart_hash="t5", target_date=date(2026, 7, 12),
        chart_payload=DOC_CHART,
    )
    assert resp.huangli_yi, "黄历宜不应为空"
    assert resp.huangli_ji, "黄历忌不应为空"
    assert all(isinstance(x, str) for x in resp.huangli_yi)
    assert all(isinstance(x, str) for x in resp.huangli_ji)


def test_tomorrow_preview_correct():
    """明日三字段齐且 == target_date+1 重排结果。"""
    target = date(2026, 7, 12)
    resp = compute_daily_fortune(
        chart_hash="t6", target_date=target, chart_payload=DOC_CHART,
    )
    tomorrow = target + timedelta(days=1)
    tm_ec = (
        Solar.fromYmdHms(tomorrow.year, tomorrow.month, tomorrow.day, 12, 0, 0)
        .getLunar().getEightChar()
    )
    tm_ec.setSect(1)
    tm_lunar = Solar.fromYmdHms(
        tomorrow.year, tomorrow.month, tomorrow.day, 12, 0, 0,
    ).getLunar()

    assert resp.tomorrow_preview.day_pillar == tm_ec.getDay()
    # 明日戊子,戊对日主己 = 劫财
    assert resp.tomorrow_preview.day_relation == "劫财"
    assert resp.tomorrow_preview.day_chong == (tm_lunar.getDayChong() or None)


def test_current_hour_index_always_null():
    """服务端不替客户端决策,固定 None。"""
    resp = compute_daily_fortune(
        chart_hash="t7", target_date=date(2026, 7, 12),
        chart_payload=DOC_CHART,
    )
    assert resp.current_hour_index is None


def test_lunar_date_format():
    """农历日期形如「六月廿八」。"""
    resp = compute_daily_fortune(
        chart_hash="t8", target_date=date(2026, 7, 12),
        chart_payload=DOC_CHART,
    )
    # 2026-07-12 → 农历 五月廿八(2026 闰月情况已实测)
    assert resp.lunar_date == "五月廿八", (
        f"农历日期异常:{resp.lunar_date}(期望「五月廿八」)")


# ===== 路由层测试 =====

async def test_endpoint_registration():
    """FastAPI route 注册存在(实际访问端点验证,而非反射 app.routes)。

    新版 FastAPI include_router 后 app.routes 含 `_IncludedRouter` 节点,不展平 path,
    反射断言不稳定。直接访问端点 + 看响应 status_code / 422 即可证明注册成功。
    """
    code, _, _ = await _post({})  # 空 body → 422(注册存在),404(未注册)
    assert code == 422, f"端点未注册或行为异常:status={code}"


async def test_endpoint_happy_path():
    """端点 200 + 字段齐。"""
    code, body, _ = await _post(_make_request(date(2026, 7, 12)))
    assert code == 200, body
    assert body["day_pillar"] == "丁亥"
    assert body["lunar_date"] == "五月廿八"
    assert len(body["hour_pillars"]) == 12
    assert body["current_hour_index"] is None
    assert body["tomorrow_preview"]["day_pillar"]


async def test_endpoint_chart_payload_invalid_returns_422():
    """chart_payload 字段非法(未知天干) → ValueError → API 层 InvalidInputError → 422。"""
    bad_req = _make_request(date(2026, 7, 12))
    bad_req["chart_payload"]["day_master"] = "X"  # 非法天干
    code, body, _ = await _post(bad_req)
    assert code == 422, f"非法天干应走 ValueError→InvalidInputError→422,实际={code} body={body}"
    # 走全局 handler,ErrorBody 结构
    assert "error" in body


async def test_engine_exception_propagates():
    """chart_payload 未知天干 → ValueError → API 层 → 422(全局 handler)。"""
    bad_chart = ChartPayload(
        day_master="X",  # 非法
        day_master_element="earth",
        day_master_strength="weak",
        favorable_elements=["火"],
        unfavorable_elements=["水"],
        four_pillars={
            "year": PillarRef(gan="庚", zhi="午"),
            "month": PillarRef(gan="己", zhi="卯"),
            "day": PillarRef(gan="己", zhi="卯"),
            "hour": PillarRef(gan="辛", zhi="未"),
        },
    )
    # 引擎直接调用应抛 ValueError(十神查表失败)
    with pytest.raises(ValueError):
        compute_daily_fortune(
            chart_hash="t_exc", target_date=date(2026, 7, 12),
            chart_payload=bad_chart,
        )


async def test_endpoint_missing_required_field_returns_422():
    """缺 chart_hash 字段 → FastAPI 校验 422。"""
    bad_req = _make_request(date(2026, 7, 12))
    del bad_req["chart_hash"]
    code, body, _ = await _post(bad_req)
    assert code == 422
    assert body["error"]["code"] == "INVALID_INPUT"


async def test_endpoint_missing_target_date_returns_422():
    """module=daily_fortune 缺 target_date → 422。"""
    bad_req = _make_request(date(2026, 7, 12))
    del bad_req["target_date"]
    code, body, _ = await _post(bad_req)
    assert code == 422
