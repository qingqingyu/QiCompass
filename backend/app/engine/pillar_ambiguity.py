"""D10 节气边界双排盘比对 + D3 日柱区间测试:时辰未知时的柱歧义检测(S02)。

检测域与红线(docs/时辰未知-slices/S01/S02 修订版,2026-09-01):

- **年/月柱**:对**候选墙钟区间的首末时刻**(与占位同款时区/真太阳时链路)
  各排一次,比对干支——不一致 → 该柱歧义(节气交界与子时无关,端点比对
  对年月柱成立:一日之内至多一个节气,两端点同干支 ⟹ 区间内无跨越)。
  **区间随 late_night 收窄**(2026-09-01 review 修正):否 → 00:00/22:59:59、
  是 → 23:00/23:59:59、不确定 → 00:00/23:59:59。原实现固定探全天 00:00/23:59
  不看 late_night,与日柱轴犯的是同一个错(探针区间宽于用户实际候选区间):
  立春 10:11 出生日,答「是」的用户(23:00-24:00,全在立春后)年柱本是确定的,
  却因 00:00 侧落在立春前被误判歧义 → 生肖被 null,onboarding 生肖屏
  无谓降级
- **日柱**:不走这对探针,统一走 D3 三步区间测试
  (true_solar_time.day_pillar_ambiguous,判据事实源在 Parent D3,本模块
  与任何 slice 不得另立阈值)。setSect(1) 下墙钟 23:59 的真太阳时几乎必落
  [23:00,24:00) 换日窗 → **次日**日柱,字面比对探针会让所有无时辰用户
  日柱 unknown(与 D3「三柱盘」前提冲突)
- **不猜**:歧义柱显式 unknown(置 null),禁止取 00:00 侧或 23:59 侧任一
- **确定性**:比对用 lunar_python 节气表(精确到分),不自算节气;
  hour_known=true 永不进本模块(老路径零开销,由调用方保证)
"""

from __future__ import annotations

from datetime import datetime

from lunar_python import Solar

from ..core.true_solar_time import (
    compute_true_solar_time,
    day_pillar_ambiguous,
    day_pillar_candidate_wall_interval,
)
from ..models.bazi import PillarAmbiguity


def _interval_probe_endpoints(calc_birth: datetime,
                              late_night: bool | None,
                              ) -> tuple[datetime, datetime]:
    """候选墙钟区间的首末可达时刻(D3 三态区间的闭区间表达)。

    day_pillar_candidate_wall_interval 给的是 half-open [start, end);年/月柱
    探针要的是区间内**实际可达**的首末时刻,故末端取 end−1 分钟的第 59 秒
    (否 → 22:59:59 / 是、不确定 → 23:59:59)。取 :59 而非 :00 是必要的:
    末端若退到 22:59:00,落在 (22:59:00, 23:00:00) 内的节气会被漏检——
    相对原固定 23:59 探针属新增盲区,不可接受。剩余盲区仅末秒内不足 1 秒,
    与原实现的分钟级粒度同量级。

    与日柱共用 day_pillar_candidate_wall_interval,保证两轴的「用户候选区间」
    定义永不分叉(D3 判据事实源单一)。
    """
    start_min, end_min = day_pillar_candidate_wall_interval(late_night)
    first = calc_birth.replace(hour=int(start_min) // 60,
                               minute=int(start_min) % 60,
                               second=0, microsecond=0)
    last_min = int(end_min) - 1
    last = calc_birth.replace(hour=last_min // 60, minute=last_min % 60,
                              second=59, microsecond=0)
    return first, last


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
        calc_birth: 候选区间中点占位归一后的出生时刻(offset-aware,保墙钟
                    日期与时区——否 11:30 / 是 23:30 / 不确定 12:00,见
                    bazi_engine.hour_unknown_placeholder;年/月探针在其
                    日期上取**候选区间**首末时刻,见 _interval_probe_endpoints)
        longitude: 出生地经度(东正西负),与主排盘同值
        late_night: 「半夜出生」三态(S01/D3:True=是 / False=否 /
                    None=不确定),日柱区间测试的第 1 步输入

    Returns:
        PillarAmbiguity(终态标记):
        - year/month:候选区间首末双排盘干支不一致(立春日 / 节交界日;
          答「是」且节气在当日 23:00 前 → 区间整体在节气后,**不歧义**)
        - day:D3 区间测试命中(true_solar_time.day_pillar_ambiguous:
          真太阳时候选区间内部含 23:00 换日点)。答「是」在西偏 ≤ −60
          或 offset ≥ 0 时**不**命中(日柱确定,占位 23:30 推出同日/次日)
        不变量:返回值 <pos> == True ⟺ 响应 pillars.<pos> 为 null

    Raises:
        lunar_python 内部异常向上抛(调用方包装,不静默吞)
    """
    # 年/月柱探针:端点取**候选区间**首末,不是固定全天(2026-09-01 review
    # 修正,见模块 docstring)。late_night 已把用户可能的出生时刻收窄,
    # 探针必须同步收窄,否则复刻日柱轴修掉的那个「探针宽于候选区间」的错
    interval_first, interval_last = _interval_probe_endpoints(
        calc_birth, late_night)

    year_start, month_start = _probe_year_month_ganzhi(
        interval_first, longitude)
    year_end, month_end = _probe_year_month_ganzhi(interval_last, longitude)

    # 日柱:D3 区间测试(2026-09-01 修订,拆掉旧「late_night != False 恒
    # unknown」与「offset < −60 西偏网」两处判据)。offset 用占位链路的
    # 真太阳时偏移(EoT 逐日漂移 ≤ 30 秒,对区间端点判定无影响)
    offset_minutes = compute_true_solar_time(
        calc_birth, longitude,
    ).offset_minutes

    return PillarAmbiguity(
        year=year_start != year_end,
        month=month_start != month_end,
        day=day_pillar_ambiguous(late_night, offset_minutes),
    )
