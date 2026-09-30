"""每日运势引擎:流日柱 / 12 时辰 / 流日冲 / 黄历 / 明日预告。

纯 CPU 同步函数,由 API 层 `run_in_threadpool` 包(对齐 `bazi_engine.py:52`)。

设计要点:
- 服务端**无状态**:不持久化 ChartSnapshot,不反推 birth_datetime,不感知 zi_hour_rule
- 拿到什么 target_date 就按它排,纯函数(决策 §1.A)
- 12 时辰统一用 target_date 当天 00:30(早子时)构造,避免子时跨日把 12 条拆成两组日柱
- 流日 / 流时对**日主(chart_payload.day_master)** 的十神走「日干 + 流干」查 SHI_SHEN 表
- current_hour_index 服务端固定返回 None,由 iOS 本地 Calendar 算(决策 §2.2 #9)
- 所有 lunar_python 内部异常向上抛(全局 handler 接管),不吞错
"""

from __future__ import annotations

import logging
from datetime import date, timedelta
from typing import Any

from lunar_python import Solar
from lunar_python.util.LunarUtil import LunarUtil as _LunarUtil

from ..core.calc_rule_snapshot import build_calc_rule_snapshot
from ..errors import BaziCalculationFailedError
from ..models.daily_fortune import (
    ChartPayload,
    DailyFortuneResponse,
    DayElements,
    DaySignalItem,
    HourPillar,
    PillarRef,
    TomorrowPreview,
)

logger = logging.getLogger(__name__)

# ---------- 十神查表(日干 + 他干 → 十神)----------

# lunar_python 1.4.8 内部 SHI_SHEN 表(100 条,10×10),通过内部 import 取用。
# requirements.txt 已锁 1.4.8,此处 assert 防版本不兼容(升级时立即报错)。
SHISHEN_GAN: dict[str, str] = dict(_LunarUtil.SHI_SHEN)
assert len(SHISHEN_GAN) == 100, (
    f"SHI_SHEN 表异常:{len(SHISHEN_GAN)} ≠ 100 条,"
    "lunar_python 版本不兼容,需复核 engine/daily_fortune.py")

# ---------- 干支五行查表(S6 今日信号:流日五行对喜忌的命中)----------

# lunar_python 1.4.8 内部表(单字 → 五行),同 SHI_SHEN 取用方式;
# assert 防版本不兼容(键数异常立即报错,不静默)。
GAN_WUXING: dict[str, str] = dict(_LunarUtil.WU_XING_GAN)
ZHI_WUXING: dict[str, str] = dict(_LunarUtil.WU_XING_ZHI)
assert len(GAN_WUXING) == 10 and len(ZHI_WUXING) == 12, (
    f"干支五行表异常:gan={len(GAN_WUXING)}(应 10) zhi={len(ZHI_WUXING)}(应 12),"
    "lunar_python 版本不兼容,需复核 engine/daily_fortune.py")

# ---------- 12 时辰表(固定顺序) ----------

# (地支, 时间段, 中点小时)
HOUR_TABLE: list[tuple[str, str, int]] = [
    ("子", "23:00-01:00", 0),    # 早子时 00:30
    ("丑", "01:00-03:00", 2),
    ("寅", "03:00-05:00", 4),
    ("卯", "05:00-07:00", 6),
    ("辰", "07:00-09:00", 8),
    ("巳", "09:00-11:00", 10),
    ("午", "11:00-13:00", 12),
    ("未", "13:00-15:00", 14),
    ("申", "15:00-17:00", 16),
    ("酉", "17:00-19:00", 18),
    ("戌", "19:00-21:00", 20),
    ("亥", "21:00-23:00", 22),
]


def compute_daily_fortune(
    chart_hash: str,
    target_date: date,
    chart_payload: ChartPayload,
) -> DailyFortuneResponse:
    """主流程。返回 DailyFortuneResponse。

    Raises:
        BaziCalculationFailedError: lunar_python 内部异常(不吞,向上抛)
        ValueError: chart_payload 字段非法(未知天干/地支)
    """
    try:
        day_master = chart_payload.day_master
        four_pillars = chart_payload.four_pillars

        # 1. 流日柱(target_date 当天正午,保证日柱稳定不受子时影响)
        day_solar = Solar.fromYmdHms(
            target_date.year, target_date.month, target_date.day, 12, 0, 0,
        )
        day_lunar = day_solar.getLunar()
        day_ec = day_lunar.getEightChar()
        day_ec.setSect(1)
        day_pillar = day_ec.getDay()
        day_gan = day_ec.getDayGan()
        day_chong: str | None = day_lunar.getDayChong() or None

        # 2. 流日对日主十神
        day_relation = _ten_god(day_master, day_gan)

        # 3. 流日冲命中盘四柱位置
        day_chong_targets = _chong_targets(day_chong, four_pillars)

        # 3b. 今日信号(S6,确定性 0 AI 成本):流日天干/地支五行 + 对喜忌的命中。
        # 喜忌为空(时辰未知 unknown_hour / 从格 special_pattern)→ day_signal 空表,
        # iOS 只显示流日五行不标 ↑↓(语义由前端口径标注,不在引擎编)。
        day_branch = day_pillar[1] if len(day_pillar) >= 2 else ""
        stem_element = GAN_WUXING.get(day_gan)
        branch_element = ZHI_WUXING.get(day_branch)
        if stem_element is None or branch_element is None:
            # 干支字不在表内:结构性异常,显式抛错不静默(错误显式传播约束)
            raise ValueError(
                f"干支五行查表失败:day_gan={day_gan!r} day_branch={day_branch!r} "
                f"day_pillar={day_pillar!r}")
        day_elements = DayElements(
            stem_element=stem_element, branch_element=branch_element)
        day_signal = _day_signal(
            elements=[stem_element, branch_element],
            favorable=chart_payload.favorable_elements,
            unfavorable=chart_payload.unfavorable_elements,
        )

        # 4. 12 时辰扫排(子时统一用当天 00:30,保证日柱引用统一)
        hour_pillars: list[HourPillar] = []
        for zhi, time_range, mid_hour in HOUR_TABLE:
            hp = _build_hour_pillar(
                target_date=target_date,
                mid_hour=mid_hour,
                hour_zhi=zhi,
                time_range=time_range,
                day_master=day_master,
                four_pillars=four_pillars,
            )
            hour_pillars.append(hp)

        # 5. 农历日期(库已带"初/十/廿"前缀)
        lunar_date = f"{day_lunar.getMonthInChinese()}月{day_lunar.getDayInChinese()}"

        # 6. 黄历宜/忌
        huangli_yi = list(day_lunar.getDayYi())
        huangli_ji = list(day_lunar.getDayJi())

        # 7. 明日预告(target_date + 1 day 重排,仅取三字段)
        tomorrow = target_date + timedelta(days=1)
        tomorrow_preview = _build_tomorrow_preview(
            tomorrow=tomorrow, day_master=day_master,
        )

        # 8. calc_rule_snapshot(daily-fortune 无经度/真太阳时,传 0.0)
        # S09:hour_known 接真实值(S01 遗留恒 True)——chart_payload.
        # day_master_strength == "unknown_hour" 即时辰未知盘(S01 引擎语义,
        # 日柱歧义盘按 D5 在客户端全拦不调本接口),补时辰前后快照可分辨。
        # pillar_ambiguity 恒 None:本链路无出生数据可判歧义(见
        # build_calc_rule_snapshot docstring 的 daily 例外说明)。
        hour_known = chart_payload.day_master_strength != "unknown_hour"
        calc_rule_snapshot = build_calc_rule_snapshot(
            sect=1,
            zi_hour_rule="client_decided",  # 业务日期由客户端决定,服务端无 zi 规则
            longitude=0.0,
            offset_minutes=0.0,
            hour_known=hour_known,
        )

        logger.info(
            "daily.fortune.ok chart_hash=%s target_date=%s day_pillar=%s "
            "day_chong=%s hour_count=%d",
            chart_hash, target_date.isoformat(), day_pillar,
            day_chong, len(hour_pillars),
        )

        return DailyFortuneResponse(
            day_pillar=day_pillar,
            day_relation_to_day_master=day_relation,
            day_chong=day_chong,
            day_chong_targets=day_chong_targets,
            hour_pillars=hour_pillars,
            current_hour_index=None,  # 服务端不替客户端决策
            day_elements=day_elements,
            day_signal=day_signal,
            lunar_date=lunar_date,
            huangli_yi=huangli_yi,
            huangli_ji=huangli_ji,
            tomorrow_preview=tomorrow_preview,
            calc_rule_snapshot=calc_rule_snapshot,
        )
    except (BaziCalculationFailedError, ValueError):
        # 已是结构化错误,原样向上抛
        raise
    except Exception as e:
        # 不吞:把 lunar_python / 内部异常向上抛为结构化错误
        raise BaziCalculationFailedError(
            f"每日运势计算失败: {type(e).__name__}: {e}",
            content_hash=chart_hash,
        ) from e


# ---------- 内部 helpers ----------

def _ten_god(day_master: str, other_gan: str) -> str:
    """日干 + 他干 → 十神(查 SHI_SHEN 表,缺键抛 ValueError 不静默)。"""
    key = day_master + other_gan
    god = SHISHEN_GAN.get(key)
    if god is None:
        raise ValueError(
            f"十神查表失败:day_master={day_master!r} other_gan={other_gan!r}"
            f" key={key!r} 不在 SHISHEN_GAN 表")
    return god


def _day_signal(
    *,
    elements: list[str],
    favorable: list[str],
    unfavorable: list[str],
) -> list[DaySignalItem]:
    """流日五行(天干+地支,保序去重)对喜忌的命中 → 今日信号表。

    规则(S6 拍板):命中喜用 → up;命中忌神 → down;喜忌双空(时辰未知/从格)
    → 空表。同一五行只出一条(天干地支同五行同向不重复;若引擎口径里同五行
    既是喜又是忌——上层规则引擎不会产出——按喜优先,不静默编向)。
    """
    if not favorable and not unfavorable:
        return []
    seen: set[str] = set()
    items: list[DaySignalItem] = []
    for element in elements:
        if element in seen:
            continue
        seen.add(element)
        if element in favorable:
            items.append(DaySignalItem(element=element, direction="up"))
        elif element in unfavorable:
            items.append(DaySignalItem(element=element, direction="down"))
    return items


def _chong_targets(chong: str | None,
                    four_pillars: dict[str, PillarRef]) -> list[str]:
    """流日/流时冲(地支字)→ 命盘四柱中被冲到的位置列表。

    返回形如 ["年支寅", "日支寅"];未命中或 chong 为 None 时返回空列表。
    """
    if not chong:
        return []
    targets: list[str] = []
    for position in ("year", "month", "day", "hour"):
        ref = four_pillars.get(position)
        if ref is None:
            continue
        if ref.zhi == chong:
            zh_position = {"year": "年支", "month": "月支",
                            "day": "日支", "hour": "时支"}[position]
            targets.append(f"{zh_position}{ref.zhi}")
    return targets


def _build_hour_pillar(
    *,
    target_date: date,
    mid_hour: int,
    hour_zhi: str,
    time_range: str,
    day_master: str,
    four_pillars: dict[str, PillarRef],
) -> HourPillar:
    """构造单时辰条。子时(mid_hour=0)用 00:30(早子时)避免跨日。"""
    # 子时统一用 00:30,其余用 mid_hour:00
    minute = 30 if mid_hour == 0 else 0
    hour = 0 if mid_hour == 0 else mid_hour
    solar = Solar.fromYmdHms(
        target_date.year, target_date.month, target_date.day,
        hour, minute, 0,
    )
    lunar = solar.getLunar()
    ec = lunar.getEightChar()
    ec.setSect(1)

    pillar = ec.getTime()
    time_gan = ec.getTimeGan()
    relation = _ten_god(day_master, time_gan)
    hour_chong: str | None = lunar.getTimeChong() or None
    chong_targets = _chong_targets(hour_chong, four_pillars)

    return HourPillar(
        hour=hour_zhi,
        time_range=time_range,
        pillar=pillar,
        relation=relation,
        chong=hour_chong,
        chong_targets=chong_targets,
    )


def _build_tomorrow_preview(
    *, tomorrow: date, day_master: str,
) -> TomorrowPreview:
    """明日预告:重排 target_date+1,取 day_pillar/day_relation/day_chong。"""
    solar = Solar.fromYmdHms(
        tomorrow.year, tomorrow.month, tomorrow.day, 12, 0, 0,
    )
    lunar = solar.getLunar()
    ec = lunar.getEightChar()
    ec.setSect(1)
    day_pillar = ec.getDay()
    day_gan = ec.getDayGan()
    day_relation = _ten_god(day_master, day_gan)
    day_chong: str | None = lunar.getDayChong() or None
    return TomorrowPreview(
        day_pillar=day_pillar,
        day_relation=day_relation,
        day_chong=day_chong,
    )
