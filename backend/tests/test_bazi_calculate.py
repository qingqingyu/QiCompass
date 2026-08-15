"""POST /api/bazi/calculate 测试 + 验收标准。

S02 契约(docs/城市搜索设计决策.md Q4/Q5):裸钟面 birth_datetime + IANA timezone
+ 物理真值 longitude/latitude/place_name/geoname_id;后端城市表已删。

覆盖:
- 文档示例完整响应
- content_hash 一致性(同输入;place_name/geoname_id 不参与 hash)
- 不同经度不同 hash
- 喜忌/神煞已填充(决策 1 + 决策 2 规则引擎输出)
- 大运第一个非空(已跳 index=0)
- calc_rule_snapshot 确定性(无 calculated_at)+ birth_timezone
- boundary_warning 非空(跨时辰 + 夏令时边角)
- 历史夏令时:1988-07-01 中国夏令时按 +09:00 解释
- 错误:缺 longitude → 422;birth 带 offset → 422;非法时区名 → 422;
  旧 city 字段残留 → 422(零兼容垫片);longitude/latitude 越界 → 422
- 错误响应结构(error.code / message / request_id)
"""

from __future__ import annotations

from datetime import datetime

import pytest
from httpx import ASGITransport, AsyncClient

import app.engine.bazi_engine as bazi_engine
from app.main import app
from tests.fixtures.tz_dst import find_dst_fold_minute

DOC_EXAMPLE = {
    "birth_datetime": "1990-03-15T14:30:00",  # 裸钟面(S02 契约)
    "timezone": "Asia/Shanghai",
    "gender": "male",
    "longitude": 116.4074,
    "latitude": 39.9042,
    "place_name": "北京",
    "geoname_id": 1816670,
    "zi_hour_rule": "zi_next_day",
}


async def _post(payload: dict) -> tuple[int, dict, dict]:
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        resp = await ac.post("/api/bazi/calculate", json=payload)
    return resp.status_code, resp.json(), dict(resp.headers)


# ===== 正常路径 =====


async def test_calculate_doc_example_full_response():
    code, body, _ = await _post(DOC_EXAMPLE)
    assert code == 200, body
    # 核心字段完整
    assert body["content_hash"]
    assert "true_solar_time" in body
    assert isinstance(body["true_solar_offset_minutes"], float)
    for key in ("year", "month", "day", "hour"):
        p = body["pillars"][key]
        assert p["gan_zhi"] and len(p["gan_zhi"]) == 2
        assert p["gan"] and p["zhi"]
        assert p["gan_element"] in ("metal", "wood", "water", "fire", "earth")
        assert p["zhi_element"] in ("metal", "wood", "water", "fire", "earth")
        assert isinstance(p["hide_gan"], list)
        assert p["shishen_gan"]
        assert isinstance(p["shishen_zhi"], list)
        assert p["nayin"]
        assert p["dishi"]
        assert p["xunkong"]
    # 命宫/身宫/胎元
    for g in ("ming_gong", "shen_gong", "tai_yuan"):
        assert body[g]["gan_zhi"] and body[g]["nayin"]
    # 五行统计和 = 8
    eb = body["element_balance"]
    assert sum(eb.values()) == 8


async def test_calculate_xiji_shensha_filled():
    """喜忌/神煞已由规则引擎填充(不再是占位空值)。

    DOC_EXAMPLE:1990-03-15 14:30 北京,男,庚午己卯己卯辛未,日干己土 weak。
    """
    _, body, _ = await _post(DOC_EXAMPLE)
    # 喜忌:普通盘非空 + 合法枚举
    assert body["day_master_strength"] in ("strong", "weak", "balanced", "special_pattern")
    assert body["xiji_method"] is not None
    assert "扶抑+调候" in body["xiji_method"]
    if body["day_master_strength"] != "special_pattern":
        assert body["favorable_elements"], "普通盘喜用不应为空"
        assert body["unfavorable_elements"], "普通盘忌讳不应为空"
        valid = {"木", "火", "土", "金", "水"}
        assert all(e in valid for e in body["favorable_elements"])
        assert all(e in valid for e in body["unfavorable_elements"])
        assert body["pattern_hint"] is None
    else:
        assert body["favorable_elements"] == []
        assert body["unfavorable_elements"] == []
        assert body["pattern_hint"] in ("zhuanwang", "cong")
    # 神煞:至少有结构化字段(可能为空列表,但必须是 list[ShenshaItem])
    assert isinstance(body["shensha"], list)
    for s in body["shensha"]:
        assert s["name"], "神煞 name 不应为空"
        assert s["position"] in ("年柱", "月柱", "时柱", "日柱")
        assert s["source"] == "三命通会"


async def test_calculate_luck_pillars_skip_index0():
    """大运第一个 gan_zhi 非空(已跳 index=0 童限)。"""
    _, body, _ = await _post(DOC_EXAMPLE)
    luck = body["luck_pillars"]
    assert len(luck) > 0
    for lp in luck:
        assert lp["gan_zhi"] != "", "大运出现空 gan_zhi(index=0 童限未跳)"
        assert lp["start_year"] and lp["end_year"]
        assert lp["start_age"] and lp["end_age"]


async def test_calculate_year_branch_zodiac_normal():
    """生肖字段已暴露(后端按立春算):1990-03-15 立春后 → 庚午马年。"""
    _, body, _ = await _post(DOC_EXAMPLE)
    assert body["year_branch_zodiac"] == "Horse"
    assert body["pillars"]["year"]["gan_zhi"] == "庚午"


async def test_calculate_year_branch_zodiac_lichun_boundary():
    """立春边界回归:1985-02-03(立春前)应归 1984 甲子鼠年,不是 1985 乙丑牛年。

    lunar_python 按节气立春算年柱(不是公历 1 月 1 日)。这是 wire up 的核心回归点:
    客户端公历年推算会错,后端 lunar_python 不会。
    """
    payload = {
        "birth_datetime": "1985-02-03T12:00:00",
        "timezone": "Asia/Shanghai",
        "gender": "male",
        "longitude": 116.4074,
        "zi_hour_rule": "zi_next_day",
    }
    code, body, _ = await _post(payload)
    assert code == 200, body
    assert body["year_branch_zodiac"] == "Rat", "立春前应归上一年生肖"
    assert body["pillars"]["year"]["gan_zhi"] == "甲子", "立春前年柱应为甲子"


# 12 生肖 → 年柱干支(公历年份,出生日取 05-01 安全落在立春后)
# 事实源:branch_relations.py 六合/三合/六冲 + pillars.py ZODIAC_NAME
_ZODIAC_SWEEP = [
    ("Rat",     1984, ["Ox", "Dragon", "Monkey"],  "Horse"),
    ("Ox",      1985, ["Rat", "Snake", "Rooster"], "Goat"),
    ("Tiger",   1986, ["Pig", "Horse", "Dog"],     "Monkey"),
    ("Rabbit",  1987, ["Dog", "Goat", "Pig"],      "Rooster"),
    ("Dragon",  1988, ["Rooster", "Rat", "Monkey"], "Dog"),
    ("Snake",   1989, ["Monkey", "Ox", "Rooster"], "Pig"),
    ("Horse",   1990, ["Goat", "Tiger", "Dog"],    "Rat"),
    ("Goat",    1991, ["Horse", "Rabbit", "Pig"],  "Ox"),
    ("Monkey",  1992, ["Snake", "Rat", "Dragon"],  "Tiger"),
    ("Rooster", 1993, ["Dragon", "Ox", "Snake"],   "Rabbit"),
    ("Dog",     1994, ["Rabbit", "Tiger", "Horse"], "Dragon"),
    ("Pig",     1995, ["Tiger", "Rabbit", "Goat"], "Snake"),
]


@pytest.mark.parametrize(
    "zodiac, year, friends, clash",
    _ZODIAC_SWEEP,
    ids=[z for z, *_ in _ZODIAC_SWEEP],
)
async def test_calculate_year_branch_friends_clash_sweep(
    zodiac, year, friends, clash,
):
    """12 生肖全量:year_branch_friends / year_branch_clash 英文名正确。

    2026-08-13 onboarding 反馈屏「好朋友 / 需磨合」契约:
    - friends = [六合, 三合×2(按地支顺序)] 英文生肖名
    - clash = 六冲 英文生肖名
    """
    payload = {
        "birth_datetime": f"{year}-05-01T12:00:00",
        "timezone": "Asia/Shanghai",
        "gender": "male",
        "longitude": 116.4074,
        "zi_hour_rule": "zi_next_day",
    }
    code, body, _ = await _post(payload)
    assert code == 200, body
    assert body["year_branch_zodiac"] == zodiac
    assert body["year_branch_friends"] == friends, (
        f"{zodiac} 好朋友应为 {friends},实得 {body['year_branch_friends']}"
    )
    assert body["year_branch_clash"] == clash, (
        f"{zodiac} 需磨合应为 {clash},实得 {body['year_branch_clash']}"
    )


async def test_calculate_content_hash_deterministic():
    """相同输入两次调用 content_hash 一致。"""
    _, b1, _ = await _post(DOC_EXAMPLE)
    _, b2, _ = await _post(DOC_EXAMPLE)
    assert b1["content_hash"] == b2["content_hash"]


async def test_calculate_true_solar_time_no_microseconds():
    """true_solar_time 序列化不含微秒(iOS .iso8601 dateDecodingStrategy 不支持小数秒)。"""
    _, body, _ = await _post(DOC_EXAMPLE)
    tst = body["true_solar_time"]
    assert "." not in tst, f"true_solar_time 含微秒(iOS 解码会失败): {tst}"


async def test_calculate_xiji_shensha_deterministic():
    """相同输入两次调用,喜忌/神煞结果完全一致(确定性)。"""
    _, b1, _ = await _post(DOC_EXAMPLE)
    _, b2, _ = await _post(DOC_EXAMPLE)
    assert b1["favorable_elements"] == b2["favorable_elements"]
    assert b1["unfavorable_elements"] == b2["unfavorable_elements"]
    assert b1["day_master_strength"] == b2["day_master_strength"]
    assert b1["xiji_method"] == b2["xiji_method"]
    assert b1["pattern_hint"] == b2["pattern_hint"]
    assert b1["shensha"] == b2["shensha"]


async def test_calculate_calc_rule_snapshot_deterministic_no_calculated_at():
    """calc_rule_snapshot 完全一致且不含 calculated_at;含 birth_timezone(S02)。"""
    _, b1, _ = await _post(DOC_EXAMPLE)
    _, b2, _ = await _post(DOC_EXAMPLE)
    assert b1["calc_rule_snapshot"] == b2["calc_rule_snapshot"]
    assert "calculated_at" not in b1["calc_rule_snapshot"]
    snap = b1["calc_rule_snapshot"]
    assert snap["library"] == "lunar_python 1.4.8"
    assert snap["sect"] == 1
    assert snap["zi_hour_rule"] == "zi_next_day"
    assert snap["birth_timezone"] == "Asia/Shanghai"
    assert "schema_version" in snap


async def test_calculate_place_metadata_not_in_hash():
    """Q4:place_name / geoname_id / latitude 是存档展示元数据,不参与 content_hash。"""
    _, b1, _ = await _post(DOC_EXAMPLE)
    _, b2, _ = await _post({
        **DOC_EXAMPLE,
        "place_name": "Beijing",
        "geoname_id": 99999999,
        "latitude": 0.0,
    })
    assert b1["content_hash"] == b2["content_hash"], (
        "place_name/geoname_id/latitude 变化不应换 hash(决策 Q4)"
    )


# ===== v1 prompt 系统:meta + ten_god_weights + useful_god_candidates =====


_TEN_GOD_NAMES = {
    "比肩", "劫财", "食神", "伤官", "偏财",
    "正财", "七杀", "正官", "偏印", "正印",
}


async def test_calculate_meta_block_complete():
    """v1 prompt 系统:meta 块字段完整 + 确定性。

    DOC_EXAMPLE:1990-03-15 14:30 北京(116.4074 经度),男。
    """
    _, body, _ = await _post(DOC_EXAMPLE)
    meta = body["meta"]
    assert meta is not None, "meta 块不应为 None"
    # locale 固定
    assert meta["locale"] == "zh-CN"
    # gender 透传
    assert meta["gender"] == "male"
    # birth_local:ISO 8601 含时区(zoneinfo 解释后 +08:00,1990-03 非夏令时)
    assert "+08:00" in meta["birth_local"]
    # true_solar_time:ISO 8601 naive(无时区后缀)
    assert "+" not in meta["true_solar_time"]
    assert "Z" not in meta["true_solar_time"]
    # late_zishi_rule:zi_next_day → "day_change_at_23"
    assert meta["late_zishi_rule"] == "day_change_at_23"
    # solar_term_boundary:非空,以"后"结尾
    assert meta["solar_term_boundary"]
    assert meta["solar_term_boundary"].endswith("后"), (
        f"solar_term_boundary 应以'后'结尾,实得 {meta['solar_term_boundary']!r}"
    )


async def test_calculate_ten_god_weights_complete():
    """v1 prompt 系统:ten_god_weights 含完整 10 个十神 + 计数 ≥ 0。"""
    _, body, _ = await _post(DOC_EXAMPLE)
    weights = body["ten_god_weights"]
    assert isinstance(weights, dict)
    assert set(weights.keys()) == _TEN_GOD_NAMES, (
        f"缺十神 key: {_TEN_GOD_NAMES - set(weights.keys())}"
    )
    for name, count in weights.items():
        assert isinstance(count, int), f"{name} 计数应为 int"
        assert count >= 0, f"{name} 计数应 ≥ 0,实得 {count}"


async def test_calculate_useful_god_candidates_matches_favorable():
    """v1 prompt 系统:普通盘 useful_god_candidates = favorable_elements 拷贝。"""
    _, body, _ = await _post(DOC_EXAMPLE)
    # DOC_EXAMPLE 是普通盘(己土 weak),favorable 非空
    if body["day_master_strength"] != "special_pattern":
        assert body["useful_god_candidates"] == body["favorable_elements"], (
            "普通盘 useful_god_candidates 应等于 favorable_elements"
        )
    else:
        # 从格诚实降级:留空
        assert body["useful_god_candidates"] == []


async def test_calculate_meta_block_deterministic():
    """meta 块 + ten_god_weights 确定性(同输入同输出)。"""
    _, b1, _ = await _post(DOC_EXAMPLE)
    _, b2, _ = await _post(DOC_EXAMPLE)
    assert b1["meta"] == b2["meta"]
    assert b1["ten_god_weights"] == b2["ten_god_weights"]
    assert b1["useful_god_candidates"] == b2["useful_god_candidates"]


async def test_calculate_meta_solar_term_boundary_correct_for_known_date():
    """已知日期节气边界正确性:1990-03-15 在"惊蛰后"(惊蛰是 1990-03-06)。

    1990 年惊蛰:1990-03-06 05:14(UTC+8);3-15 显然在其后。
    前一个节气 = 惊蛰 → boundary = "惊蛰后"。
    """
    payload = {
        "birth_datetime": "1990-03-15T14:30:00",
        "timezone": "Asia/Shanghai",
        "gender": "male",
        "longitude": 116.4074,
        "zi_hour_rule": "zi_next_day",
    }
    _, body, _ = await _post(payload)
    assert body["meta"]["solar_term_boundary"] == "惊蛰后"


async def test_calculate_different_longitude_different_hash():
    """不同经度 content_hash 不同(北京 vs 上海)。"""
    _, b1, _ = await _post(DOC_EXAMPLE)
    payload2 = {**DOC_EXAMPLE, "longitude": 121.4737, "place_name": "上海"}
    _, b2, _ = await _post(payload2)
    assert b1["content_hash"] != b2["content_hash"]


async def test_calculate_boundary_warning_when_cross_bucket():
    """真太阳时跨时辰时 boundary_warning 非空(乌鲁木齐经度 87.62)。"""
    payload = {
        "birth_datetime": "1990-03-15T01:50:00",
        "timezone": "Asia/Shanghai",
        "gender": "male",
        "longitude": 87.62,  # 乌鲁木齐,偏移大 → 跨时辰+跨日
        "zi_hour_rule": "zi_next_day",
    }
    _, body, _ = await _post(payload)
    assert body["boundary_warning"] is not None
    assert "时辰" in body["boundary_warning"]


# ===== 历史夏令时(zoneinfo,决策 Q5)=====


async def test_calculate_china_dst_1988_summer_interpreted_as_plus9():
    """1988-07-01 中国夏令时期:钟面 12:00 按 +09:00 解释(tzdb 历史规则)。

    对比固定偏移 Etc/GMT-8(按 +08:00 解释):同一钟面 → 不同绝对时刻 → 不同 hash。
    注:正午 12:00 经真太阳时 ≈ 11:42(EoT≈-3.6min + 经度差-14.4min),
    仍在午时(11-13)不跨桶 → boundary_warning 应为 None 或不含时制提示;
    盛夏远离切换点(4/17、9/11),任何情况下不应有「请核对」。
    """
    payload_dst = {
        "birth_datetime": "1988-07-01T12:00:00",
        "timezone": "Asia/Shanghai",
        "gender": "male",
        "longitude": 116.4074,
        "zi_hour_rule": "zi_next_day",
    }
    code, body, _ = await _post(payload_dst)
    assert code == 200, body
    assert "+09:00" in body["meta"]["birth_local"], (
        "1988-07-01 处于中国夏令时,应按 +09:00 解释"
    )
    # 盛夏远离切换点(4/17、9/11),不应触发时制提示
    assert "夏令时" not in (body["boundary_warning"] or "")
    assert "请核对" not in (body["boundary_warning"] or "")

    _, body_fixed, _ = await _post({**payload_dst, "timezone": "Etc/GMT-8"})
    assert "+08:00" in body_fixed["meta"]["birth_local"]
    assert body["content_hash"] != body_fixed["content_hash"], (
        "夏令时解释(+9)与固定偏移(+8)是不同物理时刻,hash 必须不同"
    )


async def test_calculate_china_dst_1988_gap_and_fallback_warned():
    """1988 年中国夏令时切换日:跳过段/重复段 → boundary_warning 提示核对(不静默)。

    切换钟面由共享 helper 程序化探测(tests/fixtures/tz_dst.py,不硬编码防 tzdb 漂移)。
    """
    gap = find_dst_fold_minute("Asia/Shanghai", datetime(1988, 4, 15, 0, 30), 96)
    fb = find_dst_fold_minute("Asia/Shanghai", datetime(1988, 9, 9, 0, 30), 96)

    payload_gap = {
        "birth_datetime": gap.isoformat(),
        "timezone": "Asia/Shanghai",
        "gender": "male",
        "longitude": 116.4074,
        "zi_hour_rule": "zi_next_day",
    }
    code, body_gap, _ = await _post(payload_gap)
    assert code == 200, body_gap
    assert body_gap["boundary_warning"] is not None, (
        f"跳过段钟面 {gap} 必须出时制提示(错误显式传播)"
    )
    assert "不存在" in body_gap["boundary_warning"]
    assert "请核对" in body_gap["boundary_warning"]

    _, body_fb, _ = await _post({**payload_gap, "birth_datetime": fb.isoformat()})
    assert body_fb["boundary_warning"] is not None
    assert "重复出现" in body_fb["boundary_warning"]


async def test_calculate_overseas_wall_time_in_birth_timezone():
    """Q1 修的核心 bug:洛杉矶出生 10:00 按洛杉矶时区解释,不再按请求方设备时区。"""
    payload = {
        "birth_datetime": "1990-03-15T10:00:00",
        "timezone": "America/Los_Angeles",
        "gender": "male",
        "longitude": -118.2437,
        "zi_hour_rule": "zi_next_day",
    }
    code, body, _ = await _post(payload)
    assert code == 200, body
    assert "-08:00" in body["meta"]["birth_local"], (
        "1990-03-15 洛杉矶处于 PST(-8),钟面 10:00 应按 -08:00 解释"
    )
    # 真太阳时 ≈ UTC 18:00 + (-118.24×4min) ≈ 10:07 太阳时,仍在 巳时(9-11)
    assert body["pillars"]["hour"]["gan_zhi"]


# ===== 错误路径 =====


async def test_error_missing_longitude_returns_422():
    code, body, _ = await _post({
        "birth_datetime": "1990-03-15T14:30:00",
        "timezone": "Asia/Shanghai",
        "gender": "male",
        "zi_hour_rule": "zi_next_day",
    })
    assert code == 422
    assert body["error"]["code"] == "INVALID_INPUT"


async def test_error_birth_with_offset_returns_422():
    """S02 契约反转:带 offset 的 birth_datetime 必须被拒(防双源时区)。"""
    code, body, _ = await _post({
        "birth_datetime": "1990-03-15T14:30:00+08:00",  # 带 offset → 拒
        "timezone": "Asia/Shanghai",
        "gender": "male",
        "longitude": 116.4074,
    })
    assert code == 422
    assert body["error"]["code"] == "INVALID_INPUT"


async def test_error_invalid_timezone_returns_422():
    """非法 IANA 时区名 → 422(替代已删除的 CITY_NOT_FOUND 路径)。"""
    code, body, _ = await _post({
        "birth_datetime": "1990-03-15T14:30:00",
        "timezone": "Mars/Olympus",
        "gender": "male",
        "longitude": 116.4074,
    })
    assert code == 422
    assert body["error"]["code"] == "INVALID_INPUT"


async def test_error_legacy_city_field_returns_422():
    """S02 零兼容垫片:旧格式 city 字段(即使其余字段全合法)→ 422 显式报错,
    不静默丢弃(extra="forbid",验收「旧格式请求不静默兼容」)。"""
    code, body, _ = await _post({
        **DOC_EXAMPLE,
        "city": "北京",  # 已删字段,不允许静默容忍
    })
    assert code == 422
    assert body["error"]["code"] == "INVALID_INPUT"
    assert "city" in body["error"]["message"], "报错需带原因(指明 city 字段)"


async def test_error_longitude_out_of_range_returns_422():
    code, body, _ = await _post({
        "birth_datetime": "1990-03-15T14:30:00",
        "timezone": "Asia/Shanghai",
        "gender": "male",
        "longitude": 999.0,
    })
    assert code == 422


async def test_error_latitude_out_of_range_returns_422():
    code, body, _ = await _post({
        "birth_datetime": "1990-03-15T14:30:00",
        "timezone": "Asia/Shanghai",
        "gender": "male",
        "longitude": 116.4074,
        "latitude": 95.0,
    })
    assert code == 422


async def test_error_invalid_gender_returns_422():
    code, body, _ = await _post({
        "birth_datetime": "1990-03-15T14:30:00",
        "timezone": "Asia/Shanghai",
        "gender": "unknown",
        "longitude": 116.4074,
    })
    assert code == 422


async def test_error_unsupported_zi_hour_rule_returns_422():
    """MVP 只实现 zi_next_day;不允许请求声明未实现的 zi_same_day。"""
    code, body, _ = await _post({**DOC_EXAMPLE, "zi_hour_rule": "zi_same_day"})
    assert code == 422
    assert body["error"]["code"] == "INVALID_INPUT"
    assert "zi_hour_rule" in body["error"]["message"]


async def test_error_rule_engine_failure_keeps_content_hash(monkeypatch):
    """规则引擎失败时仍把已计算的 content_hash 传到 UI 错误层。"""

    def fail_compute_xiji(_pillars, _element_balance):
        raise RuntimeError("forced xiji failure")

    monkeypatch.setattr(bazi_engine, "compute_xiji", fail_compute_xiji)

    code, body, _ = await _post(DOC_EXAMPLE)

    assert code == 500
    err = body["error"]
    assert err["code"] == "BAZI_CALCULATION_FAILED"
    assert err["content_hash"]
    assert "RuntimeError" in err["message"]


async def test_error_response_envelope_structure():
    """错误响应统一 { error: {code, message, request_id} } 结构。"""
    code, body, _ = await _post({
        "birth_datetime": "1990-03-15T14:30:00",
        "timezone": "Not/AZone",
        "gender": "male",
        "longitude": 116.4074,
    })
    assert code == 422
    assert "error" in body
    err = body["error"]
    for key in ("code", "message", "request_id"):
        assert key in err
    assert err["code"] == "INVALID_INPUT"
    assert isinstance(err["message"], str) and err["message"]
