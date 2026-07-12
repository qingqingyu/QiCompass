"""真太阳时计算(纯数学,无外部依赖)。

偏移 = 均时差(EoT) + (经度 - 时区中心经度) × 4 分钟/度
- EoT 用标准经验公式(Wikipedia "Equation of time"),精度 ±0.5 分钟,对 2 小时时辰桶足够
- 时区中心经度按时区推算:东八区 = 120°E
- 不引天文库,遵循「不擅自加依赖」约束
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timedelta


@dataclass(frozen=True)
class SolarTimeResult:
    """真太阳时调整结果。"""

    adjusted: datetime
    offset_minutes: float
    # 调整前后是否跨越某种边界(供 boundary_warning 拼装)
    boundary_crossed: set[str]  # 可能含 "时辰" / "日" / "月" / "年"


def equation_of_time_minutes(dt: datetime) -> float:
    """均时差(单位:分钟)。

    B = 2π × (N - 81) / 365,其中 N 为年中的日数(1月1日 = 1)
    EoT = 9.87 sin(2B) - 7.53 cos(B) - 1.5 sin(B)
    """
    n = dt.timetuple().tm_yday  # 年中第几天(1-based)
    b = 2 * math.pi * (n - 81) / 365.0
    return 9.87 * math.sin(2 * b) - 7.53 * math.cos(b) - 1.5 * math.sin(b)


def timezone_central_longitude(dt: datetime) -> float:
    """从 datetime 的 utcoffset 推算时区中心经度。东八区 → 120°E。"""
    if dt.utcoffset() is None:
        raise ValueError("birth_datetime 必须带时区(offset-aware)")
    offset_hours = dt.utcoffset().total_seconds() / 3600.0
    return offset_hours * 15.0


def shichen_bucket(hour: int) -> int:
    """传统时辰桶序号(0=子, 1=丑, ..., 11=亥)。

    (hour+1)%24//2 对齐传统时辰:子时=23/0→0,丑时=1/2→1,寅时=3/4→2...
    content_hash.py 与本文件的边界检测共享此函数,避免公式分叉。
    """
    return (hour + 1) % 24 // 2


def compute_true_solar_time(birth: datetime, longitude: float) -> SolarTimeResult:
    """计算真太阳时。

    Args:
        birth: 出生本地时间(timezone-aware)
        longitude: 经度(东正西负)

    Returns:
        SolarTimeResult,含调整后的 datetime、偏移分钟数、跨边界集合
    """
    tz_central = timezone_central_longitude(birth)
    eot = equation_of_time_minutes(birth)
    offset = eot + (longitude - tz_central) * 4.0

    adjusted = birth + timedelta(minutes=offset)

    # 边界检测:对比 birth 与 adjusted 是否跨时辰(2h桶)/日/月/年
    # 时辰桶用本地日历组件(adjusted 已在同一时区)
    # 注意:b_key != a_key 不等同于"跨时辰"——日期不同但 shichen_bucket 相同
    # (如 23:50→次日 00:10 同属子时桶0)只算跨日,不算跨时辰
    boundary: set[str] = set()
    if shichen_bucket(birth.hour) != shichen_bucket(adjusted.hour):
        boundary.add("时辰")
    b_date = (birth.year, birth.month, birth.day)
    a_date = (adjusted.year, adjusted.month, adjusted.day)
    if b_date != a_date:
        boundary.add("日")
        if (birth.year, birth.month) != (adjusted.year, adjusted.month):
            boundary.add("月")
            if birth.year != adjusted.year:
                boundary.add("年")

    return SolarTimeResult(adjusted=adjusted, offset_minutes=round(offset, 2),
                            boundary_crossed=boundary)
