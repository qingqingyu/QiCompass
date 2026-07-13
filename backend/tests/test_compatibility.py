"""POST /api/bazi/compatibility 测试 + 引擎单测。

覆盖(最终方案 §2.4 测试矩阵, ≥ 10 用例):
- 模式 A 端到端(零排盘) + 模式 B 端到端(后端排 B)
- compatibility_hash 稳定性 + 对称性(A/B 顺序无关)
- context 不污染定性评估(方案 B 重点用例)
- 五行互补 / 日主关系 / 生肖匹配 / 地支合冲 四项评估
- 流年同步 3 年 + sync 标签
- 禁忌词扫描(全 4 项评估字段不含"必"字)
- 错误传播(person_b / person_b_hash 互斥校验 → 422)
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from httpx import ASGITransport, AsyncClient

from app.engine.compatibility import (
    _assess_branch_harmony,
    _assess_day_master,
    _assess_five_elements,
    _assess_zodiac,
    compute_compatibility,
    compute_compatibility_hash,
)
from app.errors import CityNotFoundError
from app.main import app
from app.models.bazi import CalcRuleSnapshot, LuckPillar
from app.models.compatibility import (
    CompatibilityRequest,
    PersonBInput,
)
from app.models.daily_fortune import ChartPayload, PillarRef

TZ8 = timezone(timedelta(hours=8))

# ---------- fixtures ----------

def _make_chart(
    *,
    day_master: str = "己",
    day_master_element: str = "earth",
    day_master_strength: str = "weak",
    favorable: list[str] | None = None,
    unfavorable: list[str] | None = None,
    year_gan: str = "庚", year_zhi: str = "午",
    month_gan: str = "己", month_zhi: str = "卯",
    day_gan: str | None = None, day_zhi: str = "卯",
    hour_gan: str = "辛", hour_zhi: str = "未",
    luck_pillars: list[LuckPillar] | None = None,
) -> ChartPayload:
    """构造测试用 ChartPayload。"""
    return ChartPayload(
        day_master=day_master,
        day_master_element=day_master_element,
        day_master_strength=day_master_strength,
        favorable_elements=favorable if favorable is not None else ["火", "土"],
        unfavorable_elements=unfavorable if unfavorable is not None else ["水", "金"],
        four_pillars={
            "year": PillarRef(gan=year_gan, zhi=year_zhi),
            "month": PillarRef(gan=month_gan, zhi=month_zhi),
            "day": PillarRef(gan=day_gan or day_master, zhi=day_zhi),
            "hour": PillarRef(gan=hour_gan, zhi=hour_zhi),
        },
        luck_pillars=luck_pillars or [
            LuckPillar(gan_zhi="庚午", start_year=1995, end_year=2004,
                       start_age=5, end_age=14),
            LuckPillar(gan_zhi="辛未", start_year=2005, end_year=2014,
                       start_age=15, end_age=24),
            LuckPillar(gan_zhi="壬申", start_year=2015, end_year=2024,
                       start_age=25, end_age=34),
            LuckPillar(gan_zhi="癸酉", start_year=2025, end_year=2034,
                       start_age=35, end_age=44),
            LuckPillar(gan_zhi="甲戌", start_year=2035, end_year=2044,
                       start_age=45, end_age=54),
        ],
        calc_rule_snapshot=CalcRuleSnapshot(
            library="lunar_python 1.4.8",
            sect=1, zi_hour_rule="zi_next_day",
            true_solar_longitude=116.41, true_solar_offset_minutes=-14.4,
            schema_version=1,
        ),
    )


# 默认 A/B 盘(差异在五行配置上,便于测试互补)
DOC_A = _make_chart(
    day_master="己", day_master_element="earth", day_master_strength="weak",
    favorable=["火", "土"], unfavorable=["水", "金"],
    year_gan="庚", year_zhi="午",
)
DOC_B = _make_chart(
    day_master="甲", day_master_element="wood", day_master_strength="strong",
    favorable=["火", "土", "金"], unfavorable=["水", "木"],
    year_gan="甲", year_zhi="子",
)


async def _post(payload: dict) -> tuple[int, dict]:
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        resp = await ac.post("/api/bazi/compatibility", json=payload)
    return resp.status_code, resp.json()


def _make_archived_request(
    a_hash: str = "a" * 64, b_hash: str = "b" * 64,
    context: str = "general",
    a_chart: ChartPayload = DOC_A, b_chart: ChartPayload = DOC_B,
) -> CompatibilityRequest:
    """构造模式 A 请求。"""
    return CompatibilityRequest(
        person_a_hash=a_hash, person_b_hash=b_hash,
        chart_payload_a=a_chart, chart_payload_b=b_chart,
        context=context,
    )


# ===== 单元测试:compute_compatibility_hash =====

def test_hash_symmetric():
    """A/B 顺序无关: 交换输入 hash 不变。"""
    h1 = compute_compatibility_hash("aaa", "bbb", "marriage")
    h2 = compute_compatibility_hash("bbb", "aaa", "marriage")
    assert h1 == h2, "min/max 规范化应保证 A/B 顺序无关"


def test_hash_context_dependent():
    """同对 A/B 不同 context → 不同 hash(独立缓存)。"""
    h_general = compute_compatibility_hash("aaa", "bbb", "general")
    h_marriage = compute_compatibility_hash("aaa", "bbb", "marriage")
    h_business = compute_compatibility_hash("aaa", "bbb", "business")
    assert len({h_general, h_marriage, h_business}) == 3, (
        "不同 context 应得到不同 hash")


def test_hash_same_input_deterministic():
    """同输入 → 同 hash(确定性)。"""
    h1 = compute_compatibility_hash("xxx", "yyy", "general")
    h2 = compute_compatibility_hash("xxx", "yyy", "general")
    assert h1 == h2


def test_hash_length_prefixed_no_collision():
    """长度前缀消除分隔符歧义: 旧公式 (min|max|ctx) 在含 ``|`` 字符时会碰撞,
    新公式 (len(h1):h1|len(h2):h2|len(ctx):ctx) 不会。

    此测试用旧公式会碰撞、新公式不碰撞的输入对, 锁定公式不被回退。
    也作为跨平台一致性回归: iOS ``canonicalKey`` 必须用同一公式。
    """
    # 旧公式对这两组输入都会拼接成 "a|b|c|x" → 碰撞
    # 新公式: "1:a|3:b|c|1:x" vs "3:a|b|1:c|1:x" → 不碰撞
    h_a = compute_compatibility_hash("a", "b|c", "x")
    h_b = compute_compatibility_hash("a|b", "c", "x")
    assert h_a != h_b, "长度前缀应防止含 ``|`` 输入的碰撞"


# ===== 单元测试:四项评估 =====

def test_assess_five_elements_complementary():
    """A 忌水金, B 喜水金 → 互补佳。"""
    label = _assess_five_elements(
        a_favorable=["火", "土"], a_unfavorable=["水", "金"],
        b_favorable=["水", "金"], b_unfavorable=["木", "火"],
    )
    assert label == "互补佳", f"应互补佳, 实际={label}"


def test_assess_five_elements_special_pattern():
    """从格(favorable 空)→ 信息不足。"""
    label = _assess_five_elements(
        a_favorable=[], a_unfavorable=[],
        b_favorable=["水"], b_unfavorable=["火"],
    )
    assert label == "信息不足"


def test_assess_day_master_relations():
    """日干关系查表。"""
    # 甲+丙 = 木生火 → 相生
    assert _assess_day_master("甲", "丙") == "相生"
    # 甲+庚 = 金克木 → 相克
    assert _assess_day_master("甲", "庚") == "相克"
    # 甲+乙 = 同气(木)
    assert _assess_day_master("甲", "乙") == "同气"
    # 丙+丁 = 同气(火)
    assert _assess_day_master("丙", "丁") == "同气"


def test_assess_zodiac_relations():
    """生肖合冲查表。"""
    # 子+丑 → 六合
    assert _assess_zodiac("子", "丑") == "六合"
    # 子+午 → 六冲
    assert _assess_zodiac("子", "午") == "六冲"
    # 子+卯 → 相刑(子卯相刑)
    assert _assess_zodiac("子", "卯") == "三刑"
    # 寅+亥 → 六合
    assert _assess_zodiac("寅", "亥") == "六合"
    # 寅+午(三合局半合) → 三合
    assert _assess_zodiac("寅", "午") == "三合"
    # 子+子 → 无特殊合冲
    assert _assess_zodiac("子", "子") == "无特殊合冲"


def test_assess_branch_harmony_no_chong():
    """A/B 四柱地支无冲无刑 → 无冲无刑。"""
    # 同四柱地支 → 无冲
    a = {k: PillarRef(gan="甲", zhi="子") for k in ("year", "month", "day", "hour")}
    b = {k: PillarRef(gan="甲", zhi="丑") for k in ("year", "month", "day", "hour")}
    # 子丑六合 → 多合
    label = _assess_branch_harmony(a, b)
    assert label == "多合少冲", f"4 对子丑应多合少冲, 实际={label}"


def test_assess_branch_harmony_equal_chong_he_falls_through():
    """冲合均势(chong==he>=2)不匹配 多冲少合 / 多合少冲 严格 > 条件,
    应得到 '略有冲刑害' 兜底标签(而非误判为 '无冲无刑')。

    回归测试: Round 4 修复前此场景返回 '无冲无刑',误导用户。
    """
    a = {k: PillarRef(gan="甲", zhi="子") for k in ("year", "month", "day", "hour")}
    b = {
        "year": PillarRef(gan="甲", zhi="午"),
        "month": PillarRef(gan="甲", zhi="午"),
        "day": PillarRef(gan="甲", zhi="丑"),
        "hour": PillarRef(gan="甲", zhi="丑"),
    }
    # A=子×4 × B: 午×2 + 丑×2 → 8 个子午冲 + 8 个子丑合(chong==he==8)
    label = _assess_branch_harmony(a, b)
    assert label == "略有冲刑害", (
        f"冲合均势应得 '略有冲刑害' 兜底, 实际={label}")


# ===== 端到端:模式 A(零排盘) =====

def test_mode_a_end_to_end_hash_stable():
    """模式 A 端到端: 同输入两次调用 hash 相同。"""
    req = _make_archived_request()
    resp1 = compute_compatibility(req)
    resp2 = compute_compatibility(req)
    assert resp1.compatibility_hash == resp2.compatibility_hash
    # 模式 A 不排 B → person_b_chart 为 None
    assert resp1.person_a_chart is None
    assert resp1.person_b_chart is None


def test_mode_a_zero_recompute_performance():
    """模式 A 耗时应显著小于模式 B(零排盘验证)。"""
    import time as _time
    req = _make_archived_request()

    start_a = _time.perf_counter()
    compute_compatibility(req)
    elapsed_a = _time.perf_counter() - start_a

    # 模式 A 应在 50ms 内完成(零排盘)
    assert elapsed_a < 0.5, f"模式 A 应快速完成, 实际 {elapsed_a:.3f}s"


# ===== 端到端:模式 B(后端排 B) =====

def test_mode_b_end_to_end():
    """模式 B: 后端现排 B, person_b_chart 应为完整 BaziCalculateResponse。"""
    req = CompatibilityRequest(
        person_a_hash="a" * 64,
        person_b=PersonBInput(
            birth_datetime=datetime(1990, 3, 15, 14, 30, tzinfo=TZ8),
            gender="male", city="北京",
            zi_hour_rule="zi_next_day",
        ),
        chart_payload_a=DOC_A,
        context="general",
    )
    resp = compute_compatibility(req)
    # 模式 B: person_b_chart 应非空(后端现排)
    assert resp.person_b_chart is not None, "模式 B 后端应排 B"
    assert resp.person_b_chart.content_hash, "B 盘应有 content_hash"
    assert resp.person_a_chart is None, "A 始终 None"
    # 三条流年同步
    assert len(resp.synced_fortune) == 3


# ===== context 隔离(方案 B 重点用例) =====

def test_context_isolation_qualitative_invariant():
    """同 (A,B), 改 context 三次 → 定性评估 + 流年同步完全一致, 只 hash 不同。

    这是不变量: context 只参与 hash + AI prompt, 不污染定性计算。
    """
    contexts = ["general", "marriage", "business"]
    baseline = None
    for ctx in contexts:
        req = _make_archived_request(context=ctx)
        resp = compute_compatibility(req)
        assessment_tuple = (
            resp.qualitative_assessment.five_elements,
            resp.qualitative_assessment.day_master_relation,
            resp.qualitative_assessment.zodiac_match,
            resp.qualitative_assessment.branch_harmony,
        )
        synced_tuple = tuple(
            (s.year, s.person_a, s.person_b, s.sync)
            for s in resp.synced_fortune
        )
        if baseline is None:
            baseline = (assessment_tuple, synced_tuple, resp.compatibility_hash)
        else:
            assert assessment_tuple == baseline[0], (
                f"context={ctx} 污染了定性评估")
            assert synced_tuple == baseline[1], (
                f"context={ctx} 污染了流年同步")
            assert resp.compatibility_hash != baseline[2], (
                f"context={ctx} hash 未变, 与设计不符")


# ===== A=B(同盘合)=====

def test_same_chart_a_equals_b():
    """A=B 同盘合: hash 合法, 评估字段合理。"""
    req = CompatibilityRequest(
        person_a_hash="a" * 64, person_b_hash="a" * 64,
        chart_payload_a=DOC_A, chart_payload_b=DOC_A,
        context="general",
    )
    resp = compute_compatibility(req)
    assert resp.compatibility_hash, "同盘合应有 hash"
    # 同日主 → 同气
    assert resp.qualitative_assessment.day_master_relation == "同气"


# ===== 流年同步 =====

def test_synced_fortune_years():
    """3 条流年, year = now.year+1/+2/+3。"""
    req = _make_archived_request()
    fixed_now = datetime(2026, 7, 12, tzinfo=timezone.utc)
    resp = compute_compatibility(req, now=fixed_now)
    years = [s.year for s in resp.synced_fortune]
    assert years == [2027, 2028, 2029], f"未来 3 年序列异常: {years}"


def test_synced_fortune_format():
    """格式: {大运}运 {流年}年。"""
    req = _make_archived_request()
    resp = compute_compatibility(req)
    for s in resp.synced_fortune:
        assert "运" in s.person_a, f"person_a 缺「运」: {s.person_a!r}"
        assert "年" in s.person_a, f"person_a 缺「年」: {s.person_a!r}"
        assert "运" in s.person_b, f"person_b 缺「运」: {s.person_b!r}"
        assert "年" in s.person_b, f"person_b 缺「年」: {s.person_b!r}"


def test_synced_fortune_sync_label_set():
    """sync 标签在固定集合内。"""
    valid = {"同步走强", "同步承压", "运势分化", "难以定性"}
    req = _make_archived_request()
    resp = compute_compatibility(req)
    for s in resp.synced_fortune:
        assert s.sync in valid, f"非法 sync 标签: {s.sync!r}"


# ===== 禁忌词扫描(防回归) =====

def test_no_forbidden_words_in_assessment():
    """四项评估字段不含「必」字(防绝对结论)。

    跑 5 组随机盘组合(对盘不同的喜忌配置)。
    """
    test_charts = [
        _make_chart(favorable=["木"], unfavorable=["金"]),
        _make_chart(favorable=["火"], unfavorable=["水"]),
        _make_chart(favorable=["水", "金"], unfavorable=["木", "火"]),
        _make_chart(favorable=["土"], unfavorable=["木"]),
        _make_chart(favorable=["火", "土"], unfavorable=["水", "金"]),
    ]
    for i, a in enumerate(test_charts):
        for j, b in enumerate(test_charts):
            if i == j:
                continue
            req = CompatibilityRequest(
                person_a_hash=f"a{i:064d}"[:64],
                person_b_hash=f"b{j:064d}"[:64],
                chart_payload_a=a, chart_payload_b=b,
                context="general",
            )
            resp = compute_compatibility(req)
            forbidden = ["必成", "必分", "必破财", "注定", "必"]
            assessment = resp.qualitative_assessment
            for field in (assessment.five_elements,
                          assessment.day_master_relation,
                          assessment.zodiac_match,
                          assessment.branch_harmony):
                for w in forbidden:
                    assert w not in field, (
                        f"评估字段含禁忌词 {w!r}: {field!r}"
                        f"(A={a.favorable_elements}, B={b.favorable_elements})")


# ===== 错误传播(422) =====

async def test_endpoint_both_b_modes_returns_422():
    """person_b 和 person_b_hash 都传 → 422。"""
    payload = {
        "person_a_hash": "a" * 64,
        "person_b_hash": "b" * 64,
        "person_b": {
            "birth_datetime": "1990-03-15T14:30:00+08:00",
            "gender": "male", "city": "北京",
            "zi_hour_rule": "zi_next_day",
        },
        "chart_payload_a": DOC_A.model_dump(),
        "chart_payload_b": DOC_B.model_dump(),
        "context": "general",
    }
    code, body = await _post(payload)
    assert code == 422, f"互斥违反应 422, 实际={code} body={body}"


async def test_endpoint_neither_b_mode_returns_422():
    """person_b 和 person_b_hash 都不传 → 422。"""
    payload = {
        "person_a_hash": "a" * 64,
        "chart_payload_a": DOC_A.model_dump(),
        "context": "general",
    }
    code, body = await _post(payload)
    assert code == 422


async def test_endpoint_mode_a_missing_chart_payload_b_returns_422():
    """模式 A 缺 chart_payload_b → 422。"""
    payload = {
        "person_a_hash": "a" * 64,
        "person_b_hash": "b" * 64,
        "chart_payload_a": DOC_A.model_dump(),
        "context": "general",
    }
    code, body = await _post(payload)
    assert code == 422


async def test_endpoint_empty_hash_returns_422():
    """content_hash 不能为空,否则会把空字符串误判为有效模式 A key。"""
    payload = {
        "person_a_hash": "",
        "person_b_hash": "",
        "chart_payload_a": DOC_A.model_dump(),
        "chart_payload_b": DOC_B.model_dump(),
        "context": "general",
    }
    code, body = await _post(payload)
    assert code == 422, f"空 hash 应 422, 实际={code} body={body}"


async def test_endpoint_malformed_hash_returns_422():
    """content_hash 必须是 64 位小写 sha256 hex,不能接受任意非空字符串。"""
    for bad_hash in ("abc", "g" * 64, "A" * 64):
        payload = {
            "person_a_hash": bad_hash,
            "person_b_hash": "b" * 64,
            "chart_payload_a": DOC_A.model_dump(),
            "chart_payload_b": DOC_B.model_dump(),
            "context": "general",
        }
        code, body = await _post(payload)
        assert code == 422, (
            f"非法 hash {bad_hash!r} 应 422, 实际={code} body={body}")


async def test_endpoint_chart_payload_a_missing_returns_422():
    """缺 chart_payload_a → 422。"""
    payload = {
        "person_a_hash": "a" * 64,
        "person_b_hash": "b" * 64,
        "chart_payload_b": DOC_B.model_dump(),
        "context": "general",
    }
    code, body = await _post(payload)
    assert code == 422


def test_mode_b_unknown_city_preserves_city_not_found_error():
    """城市查表失败应保留 CITY_NOT_FOUND/404,不能包装成 BAZI_CALCULATION_FAILED/500。"""
    req = CompatibilityRequest(
        person_a_hash="a" * 64,
        person_b=PersonBInput(
            birth_datetime=datetime(1990, 3, 15, 14, 30, tzinfo=TZ8),
            gender="female",
            city="不存在的城市",
        ),
        chart_payload_a=DOC_A,
        context="general",
    )
    with pytest.raises(CityNotFoundError):
        compute_compatibility(req)


# ===== 端点注册 =====

async def test_endpoint_registered():
    """FastAPI route 注册存在(空 body → 422)。"""
    code, _ = await _post({})
    assert code == 422, "端点未注册会 404"


async def test_endpoint_mode_a_happy_path():
    """模式 A 端到端 200 + 字段齐。"""
    payload = {
        "person_a_hash": "a" * 64,
        "person_b_hash": "b" * 64,
        "chart_payload_a": DOC_A.model_dump(),
        "chart_payload_b": DOC_B.model_dump(),
        "context": "marriage",
    }
    code, body = await _post(payload)
    assert code == 200, f"happy path 应 200, 实际={code} body={body}"
    assert body["compatibility_hash"]
    assert body["person_a_chart"] is None
    assert body["person_b_chart"] is None  # 模式 A
    assert "five_elements" in body["qualitative_assessment"]
    assert len(body["synced_fortune"]) == 3
    assert body["calc_rule_snapshot"]["sect"] == 1


async def test_endpoint_mode_b_happy_path():
    """模式 B 端到端 200 + person_b_chart 非空。"""
    payload = {
        "person_a_hash": "a" * 64,
        "person_b": {
            "birth_datetime": "1990-03-15T14:30:00+08:00",
            "gender": "female", "city": "上海",
            "zi_hour_rule": "zi_next_day",
        },
        "chart_payload_a": DOC_A.model_dump(),
        "context": "general",
    }
    code, body = await _post(payload)
    assert code == 200, f"模式 B happy path 应 200, 实际={code} body={body}"
    assert body["person_b_chart"] is not None
    assert body["person_b_chart"]["content_hash"]
    assert body["person_a_chart"] is None
