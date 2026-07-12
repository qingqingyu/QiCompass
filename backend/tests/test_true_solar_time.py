"""真太阳时单测。

均时差(EoT)与标准星历表对照,精度 ±2 分钟内。
经度时差 4 分钟/度。
边界检测:跨时辰/日/月/年。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest

from app.core.true_solar_time import (
    compute_true_solar_time,
    equation_of_time_minutes,
    timezone_central_longitude,
)

TZ8 = timezone(timedelta(hours=8))


def test_eot_february_negative_about_minus12():
    """2 月中旬 EoT 约 -14 分钟(一年中最大负值)。"""
    dt = datetime(2020, 2, 12, 12, 0, tzinfo=TZ8)
    eot = equation_of_time_minutes(dt)
    assert -16 < eot < -10, f"2 月 EoT 期望约 -14,实得 {eot}"


def test_eot_november_positive_about_plus16():
    """11 月初 EoT 约 +16 分钟(一年中最大正值)。"""
    dt = datetime(2020, 11, 3, 12, 0, tzinfo=TZ8)
    eot = equation_of_time_minutes(dt)
    assert 13 < eot < 18, f"11 月 EoT 期望约 +16,实得 {eot}"


def test_timezone_central_longitude_cst_is_120():
    """东八区中心经度 = 120°E。"""
    dt = datetime(2020, 6, 1, 12, 0, tzinfo=TZ8)
    assert timezone_central_longitude(dt) == pytest.approx(120.0)


def test_timezone_central_longitude_uses_datetime_offset():
    """西五区中心经度 = 75°W,覆盖海外出生地/非东八区路径。"""
    tz5_west = timezone(timedelta(hours=-5))
    dt = datetime(2020, 6, 1, 12, 0, tzinfo=tz5_west)
    assert timezone_central_longitude(dt) == pytest.approx(-75.0)


def test_true_solar_time_beijing_offset_negative():
    """北京(116.41)经度时差 = (116.41-120)*4 ≈ -14.36 分钟。

    真太阳时 = 输入 + EoT + 经度时差。
    3 月 EoT 约 -9 → 合计约 -23 分钟。
    """
    dt = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    r = compute_true_solar_time(dt, 116.41)
    assert r.offset_minutes < 0
    assert -30 < r.offset_minutes < -18


def test_true_solar_time_no_boundary_when_stays_in_bucket():
    """非边界用例:14:30 北京 → 14:06,同日同时辰桶,无跨越。"""
    dt = datetime(1990, 3, 15, 14, 30, tzinfo=TZ8)
    r = compute_true_solar_time(dt, 116.41)
    assert r.boundary_crossed == set()


def test_true_solar_time_boundary_cross_hour_bucket():
    """乌鲁木齐(87.62)经度时差 = (87.62-120)*4 ≈ -129.5 分钟。

    输入 01:50 → 调整 ≈ 01:50 - 129.5 - EoT ≈ 前一日 23:30 附近 → 跨日+跨时辰。
    """
    dt = datetime(1990, 3, 15, 1, 50, tzinfo=TZ8)
    r = compute_true_solar_time(dt, 87.62)
    assert "时辰" in r.boundary_crossed
    assert "日" in r.boundary_crossed


def test_true_solar_time_same_zi_hour_across_midnight_no_shichen_boundary():
    """同子时跨午夜:23:50 → 次日 00:10(同子时桶0)→ 只跨日,不跨时辰。

    回归测试:防止边界检测把"日期不同但 shichen_bucket 相同"误判为跨时辰。
    构造:11 月初 EoT ≈ +16 分钟,经度 121° → 经度时差 +4 分钟 → offset ≈ +20 分钟。
    birth=23:50 → adjusted ≈ 00:10 次日。
    """
    dt = datetime(2020, 11, 3, 23, 50, tzinfo=TZ8)
    r = compute_true_solar_time(dt, 121.0)
    # adjusted 应在次日 00:00 附近
    assert r.adjusted.day != dt.day, "测试前提:应跨日"
    # 同子时桶(shichen_bucket(23)=0, shichen_bucket(0)=0)→ 不应报跨时辰
    assert "时辰" not in r.boundary_crossed, (
        f"同子时跨午夜不应报跨时辰,boundary={r.boundary_crossed}"
    )
    # 但应报跨日
    assert "日" in r.boundary_crossed


def test_true_solar_time_aware_required():
    """naive datetime 必须报错(不静默)。"""
    naive = datetime(1990, 3, 15, 14, 30)
    with pytest.raises(ValueError):
        compute_true_solar_time(naive, 116.41)
