"""D10 节气边界双排盘比对 + 西偏换日网:时辰未知时的柱歧义检测(S02)。

检测域与红线(docs/时辰未知-slices/S02,含对 Parent D10「比对年/月/日柱」
字面措辞的有意偏离):

- **年/月柱**:对该出生日 00:00 与 23:59(与 12:00 占位同款时区/真太阳时
  链路)各排一次,比对干支——不一致 → 该柱歧义(节气交界与子时无关,
  00:00/23:59 探针对年月柱成立)
- **日柱**:不得直接复用 00:00/23:59 探针 —— setSect(1) 下墙钟 23:59 的
  真太阳时几乎必落 [23:00,24:00) 换日窗 → **次日**日柱,字面实现会让所有
  无时辰用户日柱 unknown(与 Parent D3「答否→日柱完全确定」冲突)。正确
  判据见 true_solar_time.wall_day_start_before_changeover(墙钟日起点早于
  前一日 23:00 换日点 ⟺ offset < −60min 的西偏场景)
- **不猜**:歧义柱显式 unknown(置 null),禁止取 00:00 侧或 23:59 侧任一
- **确定性**:比对用 lunar_python 节气表(精确到分),不自算节气;
  hour_known=true 永不进本模块(老路径零开销,由调用方保证)
"""

from __future__ import annotations

from datetime import datetime

from lunar_python import Solar

from ..core.true_solar_time import (
    compute_true_solar_time,
    wall_day_start_before_changeover,
)
from ..models.bazi import PillarAmbiguity


def _probe_year_month_ganzhi(wall_aware: datetime,
                             longitude: float) -> tuple[str, str]:
    """单探针排盘:墙钟时刻 → 真太阳时 → lunar_python,返回 (年柱干支, 月柱干支)。

    与主排盘同款链路(compute_true_solar_time + Solar.fromDate + setSect(1),
    sect 对齐 bazi_engine.SECT 坑1)。lunar_python 异常向上抛,由引擎包装为
    BaziCalculationFailedError(不吞)。
    """
    adjusted = compute_true_solar_time(wall_aware, longitude).adjusted
    ec = Solar.fromDate(adjusted.replace(tzinfo=None)).getLunar().getEightChar()
    ec.setSect(1)  # 坑1:库默认 sect=2,与产品决策「默认 23:00 换日」冲突
    return ec.getYear(), ec.getMonth()


def detect_pillar_ambiguity(
    *,
    calc_birth: datetime,
    longitude: float,
    late_night: bool | None,
) -> PillarAmbiguity:
    """时辰未知(hour_known=false)时的三柱歧义检测。

    Args:
        calc_birth: 12:00 占位归一后的出生时刻(offset-aware,保墙钟日期
                    与时区;探针在其日期上取 00:00 与 23:59)
        longitude: 出生地经度(东正西负),与主排盘同值
        late_night: 「半夜出生」三态(S01)。日柱歧义的另一来源:
                    != False 时无论网是否命中,日柱均歧义(同一终态)

    Returns:
        PillarAmbiguity(终态标记):
        - year/month:双排盘干支不一致(立春日 / 节交界日)
        - day:late_night != False **或** 西偏换日网命中
        不变量:返回值 <pos> == True ⟺ 响应 pillars.<pos> 为 null

    Raises:
        lunar_python 内部异常向上抛(调用方包装,不静默吞)
    """
    day_start = calc_birth.replace(hour=0, minute=0, second=0, microsecond=0)
    day_end = calc_birth.replace(hour=23, minute=59, second=0, microsecond=0)

    year_start, month_start = _probe_year_month_ganzhi(day_start, longitude)
    year_end, month_end = _probe_year_month_ganzhi(day_end, longitude)

    # 日柱网:用 12:00 占位链路的真太阳时 offset(EoT 逐日漂移 ≤ 30 秒,
    # 对 −60min 判据无影响;东八区标准经度恒不命中)
    offset_minutes = compute_true_solar_time(
        calc_birth, longitude,
    ).offset_minutes

    return PillarAmbiguity(
        year=year_start != year_end,
        month=month_start != month_end,
        day=(
            wall_day_start_before_changeover(offset_minutes)
            or late_night is not False
        ),
    )
