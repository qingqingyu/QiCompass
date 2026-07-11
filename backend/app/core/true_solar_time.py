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

from ..config import DEFAULT_TIMEZONE_CENTRAL_LONGITUDE


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
    boundary: set[str] = set()
    b2h, a2h = birth.hour // 2, adjusted.hour // 2
    # 注意:跨日后的时辰桶可能不同,但用日期+小时共同比较
    b_key = (birth.year, birth.month, birth.day, birth.hour // 2)
    a_key = (adjusted.year, adjusted.month, adjusted.day, adjusted.hour // 2)
    if b_key != a_key:
        # 分辨跨了哪一层
        if birth.year != adjusted.year:
            boundary.add("年")
        if (birth.year, birth.month) != (adjusted.year, adjusted.month):
            boundary.add("月")
        if (birth.year, birth.month, birth.day) != (
            adjusted.year,
            adjusted.month,
            adjusted.day,
        ):
            boundary.add("日")
        # 桶不同但日期相同 → 仅跨时辰
        if (birth.year, birth.month, birth.day) == (
            adjusted.year,
            adjusted.month,
            adjusted.day,
        ) and birth.hour // 2 != adjusted.hour // 2:
            boundary.add("时辰")
        elif (birth.year, birth.month, birth.day) != (
            adjusted.year,
            adjusted.month,
            adjusted.day,
        ):
            # 跨日的同时必然跨时辰桶
            boundary.add("时辰")

    return SolarTimeResult(adjusted=adjusted, offset_minutes=round(offset, 2),
                            boundary_crossed=boundary)


def default_timezone_central_longitude() -> float:
    """暴露默认值(测试与 snapshot 用)。"""
    return DEFAULT_TIMEZONE_CENTRAL_LONGITUDE
