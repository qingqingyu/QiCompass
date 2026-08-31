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


# setSect(1) 换日边界:真太阳时 23:00 起日柱归次日(CLAUDE.md「强制 setSect(1)」)
DAY_CHANGE_TRUE_SOLAR_START_MIN = 23 * 60
# 换日歧义窗长度:23:00 → 24:00,共 1 小时
_DAY_CHANGE_WINDOW_MIN = 60
_MINUTES_PER_DAY = 24 * 60


def late_night_wall_window(offset_minutes: float) -> tuple[int, int]:
    """时辰未知时的「半夜出生」日柱歧义窗口,反算为墙钟分钟数(mod 1440)。

    定义(docs/时辰未知设计决策.md D3,**不硬编码墙钟 23:00-24:00**):
    换日判定发生在**真太阳时**上,边界为真太阳时 23:00;墙钟窗口
    = [23:00 − offset, 24:00 − offset)(mod 24h),其中
    offset = EoT(出生日) + (经度 − 时区中心经度) × 4min/度
    (即 compute_true_solar_time 的 offset_minutes,时辰未知时按 12:00
    占位时刻估算 —— EoT 逐日漂移 ≤ 30 秒,对 1 小时窗口判定无影响)。

    出生墙钟落在该窗口内 → 真太阳时已过 23:00,日柱属于次日子时盘,
    日柱歧义。例:喀什 offset ≈ −176 → 窗口 01:56-02:56(次日)。

    Returns:
        (start, end) 墙钟分钟数 mod 1440,end = start + 60(mod 1440,
        跨午夜时 end < start)。调用方拿区间判断时需自行处理回绕。
    """
    start = (DAY_CHANGE_TRUE_SOLAR_START_MIN - round(offset_minutes)) % _MINUTES_PER_DAY
    end = (start + _DAY_CHANGE_WINDOW_MIN) % _MINUTES_PER_DAY
    return start, end


def wall_day_start_before_changeover(offset_minutes: float) -> bool:
    """墙钟日起点(00:00 经真太阳时调整后)是否早于前一日的 23:00 换日点。

    D10/S02 日柱网判据(docs/时辰未知-slices/S02 对 Parent D10 的有意偏离):
    日柱歧义不得用 00:00/23:59 探针比对 —— setSect(1) 下墙钟 23:59 的
    真太阳时几乎必落 [23:00,24:00) 换日窗 → 次日柱,字面实现会让**所有**
    无时辰用户日柱 unknown。正确判定域是「排除换日窗后的当日主体区间」
    是否横跨两个日柱,等价判据:

        墙钟 00:00 + offset = 前一日第 (1440 + offset) 分钟
        早于 23:00(第 1380 分钟)⟺ offset < −60

    命中(西偏场景,如喀什 −176min → 墙钟凌晨段落入前一真太阳日,实证
    1990-03-15@75.99°E:墙钟 [00:00, 02:06) 日柱=前一日)→ 该墙钟日的
    主体区间横跨两日柱 → 日柱 unknown。它是 S01 late_night 网的互补层:
    late_night=否 的用户未必把凌晨出生归入「半夜 11 点之后」。

    东八区标准经度(120°E,EoT ∈ [−15,+17]min)恒不命中(offset ≥ −60
    与 D3「答否→日柱完全确定」一致),不是漏报。
    """
    return offset_minutes < -_DAY_CHANGE_WINDOW_MIN


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
