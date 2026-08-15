"""tz_resolution 单元测试(决策 Q5:后端 zoneinfo 解释 + fold 策略显式化)。

覆盖矩阵:
- 普通时间:无 flags,offset 正确
- 历史夏令时:1986-91 中国 / 1945 伦敦 BDST / 2005 美国旧 DST 日期
- 歧义小时(秋令时回拨):fold=0 取较早的一次
- 不存在小时(春令时跳过):fold=0 按切换前偏移 → 绝对时刻落在跳变后
- 切换点附近:dst_transition flag
- 非法输入:aware datetime / 非法 IANA 名 → 显式 ValueError
- Etc/GMT-X 反符号语义钉死(IANA 坑:X 为正 = 东经)
"""

from __future__ import annotations

from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

from app.core.tz_resolution import (
    FLAG_AMBIGUOUS,
    FLAG_NEAR_TRANSITION,
    FLAG_NONEXISTENT,
    resolve_wall_time,
    validate_timezone,
)
from tests.fixtures.tz_dst import find_dst_fold_minute

SH = "Asia/Shanghai"


# ===== 普通 / 历史夏令时解释 =====


def test_normal_cn_time_plus8_no_flags():
    r = resolve_wall_time(datetime(1990, 3, 15, 14, 30), SH)
    assert r.aware.utcoffset() == timedelta(hours=8)
    assert r.dst_flags == frozenset()


def test_china_dst_1988_summer_plus9():
    """1986-91 中国夏令时:1988-07-01 钟面按 +09:00 解释(tzdb 历史规则自动套用)。"""
    r = resolve_wall_time(datetime(1988, 7, 1, 12, 0), SH)
    assert r.aware.utcoffset() == timedelta(hours=9)
    assert r.aware.isoformat() == "1988-07-01T12:00:00+09:00"
    assert FLAG_NEAR_TRANSITION not in r.dst_flags


def test_china_dst_utc_instant_shifts_one_hour_vs_fixed():
    """夏令时解释与固定 +8 是不同物理时刻(差 1 小时)——这是 hash 分叉的根基。"""
    dst = resolve_wall_time(datetime(1988, 7, 1, 12, 0), SH).aware
    fixed = resolve_wall_time(datetime(1988, 7, 1, 12, 0), "Etc/GMT-8").aware
    assert dst.astimezone(ZoneInfo("UTC")) == fixed.astimezone(ZoneInfo("UTC")) - timedelta(hours=1)


def test_london_1945_bdst_plus2():
    """二战双夏令时(BDST):1945-07-01 伦敦 = +02:00。"""
    r = resolve_wall_time(datetime(1945, 7, 1, 12, 0), "Europe/London")
    assert r.aware.utcoffset() == timedelta(hours=2)


def test_us_eastern_2005_old_dst_dates():
    """美国 2007 前 DST 日期(10 月最后一个周日回拨):2005-10-30 01:30 重复。"""
    r = resolve_wall_time(datetime(2005, 10, 30, 1, 30), "America/New_York")
    assert FLAG_AMBIGUOUS in r.dst_flags


def test_london_2023_fallback_ambiguous():
    r = resolve_wall_time(datetime(2023, 10, 29, 1, 30), "Europe/London")
    assert FLAG_AMBIGUOUS in r.dst_flags


# ===== fold 策略 =====


def test_gap_nonexistent_fold0_maps_after_gap():
    """春令时跳过段:钟面不存在,fold=0 按切换前偏移 → 绝对时刻落在跳变后。"""
    gap = find_dst_fold_minute(SH, datetime(1988, 4, 15, 0, 30), 96)
    r = resolve_wall_time(gap, SH)
    assert FLAG_NONEXISTENT in r.dst_flags
    # 绝对时刻 = 钟面 - 切换前偏移(+8);gap 是 naive,比对剥掉 tzinfo
    utc = r.aware.astimezone(ZoneInfo("UTC"))
    assert utc.replace(tzinfo=None) == gap - timedelta(hours=8)
    assert r.aware.utcoffset() == timedelta(hours=8)  # fold=0 = 切换前偏移


def test_fallback_ambiguous_fold0_is_earlier():
    """秋令时回拨段:同一钟面两次出现,fold=0 = 较早的一次(夏令时偏移)。"""
    fb = find_dst_fold_minute(SH, datetime(1988, 9, 9, 0, 30), 96)
    r = resolve_wall_time(fb, SH)
    assert FLAG_AMBIGUOUS in r.dst_flags
    early = fb.replace(tzinfo=ZoneInfo(SH), fold=0)
    late = fb.replace(tzinfo=ZoneInfo(SH), fold=1)
    assert r.aware == early
    assert r.aware.astimezone(ZoneInfo("UTC")) < late.astimezone(ZoneInfo("UTC"))


def test_near_transition_flag_within_window():
    """切换点前 2 小时的正常钟面 → dst_transition(提示核对,不影响解释)。"""
    # 1988-04-17 02:00 切换;取 4-17 00:00(切换前 2h,本身无歧义)
    r = resolve_wall_time(datetime(1988, 4, 17, 0, 0), SH)
    assert r.aware.utcoffset() == timedelta(hours=8)
    assert r.dst_flags == frozenset({FLAG_NEAR_TRANSITION})


# ===== Etc/GMT 反符号坑(IANA:X 为正 = 东经)=====


def test_etc_gmt_reverse_sign_pinned():
    """Etc/GMT-8 = UTC+8(IANA 反符号),钉死防实现写反。"""
    r = resolve_wall_time(datetime(1988, 7, 1, 12, 0), "Etc/GMT-8")
    assert r.aware.utcoffset() == timedelta(hours=8)
    r9 = resolve_wall_time(datetime(1988, 7, 1, 12, 0), "Etc/GMT-9")
    assert r9.aware.utcoffset() == timedelta(hours=9)


# ===== 非法输入(错误显式传播)=====


def test_aware_input_rejected():
    with pytest.raises(ValueError, match="naive"):
        resolve_wall_time(
            datetime(1990, 3, 15, 14, 30, tzinfo=ZoneInfo(SH)), SH)


@pytest.mark.parametrize("bad", ["Mars/Olympus", "", "GMT+8", "Asia / Shanghai"])
def test_invalid_timezone_names_rejected(bad: str):
    """注:macOS ZoneInfo 大小写不敏感("utc"/"UTC" 等价),不算非法。"""
    with pytest.raises(ValueError, match="IANA"):
        validate_timezone(bad)


def test_valid_timezone_names_accepted():
    for ok in ["Asia/Shanghai", "America/Los_Angeles", "Etc/GMT-8", "UTC"]:
        validate_timezone(ok)
