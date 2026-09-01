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
_MINUTES_PER_DAY = 24 * 60


def day_pillar_candidate_wall_interval(late_night: bool | None,
                                       ) -> tuple[float, float]:
    """时辰未知时的候选墙钟区间(分钟,以出生日 00:00 为 0)。

    D3 三步区间测试第 1 步(docs/时辰未知设计决策.md D3「v1 用途」,
    2026-09-01 修订版):

        否     → [00:00, 23:00) = [0, 1380)
        是     → [23:00, 24:00) = [1380, 1440)
        不确定 → 全天 [00:00, 24:00) = [0, 1440)

    half-open:端点时刻归属由 day_pillar_ambiguous 的「严格内部」判据处理
    (换日点恰贴端点 → 整个区间仍属同一日柱,不歧义)。
    """
    if late_night is False:
        return 0.0, float(DAY_CHANGE_TRUE_SOLAR_START_MIN)
    if late_night is True:
        return (float(DAY_CHANGE_TRUE_SOLAR_START_MIN),
                float(_MINUTES_PER_DAY))
    return 0.0, float(_MINUTES_PER_DAY)


def day_pillar_ambiguous(late_night: bool | None,
                         offset_minutes: float) -> bool:
    """D3 日柱歧义判据:三步区间测试(**单一事实源,任何 slice 不得另立阈值**)。

    docs/时辰未知设计决策.md D3(2026-09-01 slice review 修订)。原两处旧判据
    均已拆:「hour_known=false 且 late_night != False → 恒 unknown」(过度降级)
    与「offset < −60min 西偏网」(单边近似,东偏漏报 → 静默给错日柱)。

    三步:
    1. 二值答案 → 候选墙钟区间(day_pillar_candidate_wall_interval)
    2. 区间整体 + offset_minutes(真太阳时 − 墙钟,即 compute_true_solar_time
       的 offset_minutes)→ 真太阳时候选区间。允许跨午夜:用绝对分钟比较,
       不回绕折叠到 [0, 1440)
    3. 日柱歧义 ⟺ ∃k∈Z: start < 1380 + 1440k < end
       (23:00 换日点**严格落在区间内部**;恰贴端点不算——此时整个区间仍
       属同一日柱)

    性质(由测试自然得出,不另写分支):
    - 「不确定」恒歧义:区间长 1440 必含一个换日点在内部(offset 恰为 −60
      的测度零退化点除外——真太阳日与墙钟日完全对齐,日柱确定)
    - 「是」仅在西偏 ≤ −60 或 offset ≥ 0 时确定(前者同日 / 后者整体落
      换日窗 → 次日),(-60, 0) 内横跨换日点 → 歧义
    - hour_known=true 恒不歧义,由调用方保证不进本函数(零开销)

    场景表(D3 实测;单边 offset<−60 规则两个方向都错):
        喀什 −176 × 是 → 确定(真太阳时 20:04-21:04 同日)   单边规则误判歧义
        成都 −63  × 是 → 确定                              误判歧义
        上海 +6   × 否 → 歧义(22:54-23:00 墙钟落次日)      误判确定 → 静默给错
        抚远 +57  × 否 → 歧义(22:00-23:00 落次日)          误判确定 → 静默给错
    """
    wall_start, wall_end = day_pillar_candidate_wall_interval(late_night)
    start = wall_start + offset_minutes
    end = wall_end + offset_minutes
    if end <= start:
        # 防御:空区间(三态候选区间均非空,正常不可达)
        return False
    # 大于 start 的最小换日点:1380 + 1440k(k = floor 商 + 1,
    # 保证严格大于 start,避开浮点取模回绕)
    k = (math.floor(
        (start - DAY_CHANGE_TRUE_SOLAR_START_MIN) / _MINUTES_PER_DAY) + 1)
    changeover = DAY_CHANGE_TRUE_SOLAR_START_MIN + _MINUTES_PER_DAY * k
    return changeover < end


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
