"""流年/流日/流时 + 当前大运定位。

- current_year_pillar:用 getYearInGanZhiByLiChun()(立春换年,非公历年)
- current_day/hour_pillar:用 Solar.fromDate(now) 现排
- current_luck_pillar:在 luck_pillars 里按 start_year <= now.year <= end_year 查
"""

from __future__ import annotations

from datetime import datetime
from typing import Any, Optional

from lunar_python import Solar

from ..models.bazi import CurrentPillar, LuckPillar


def build_current_year_pillar(now: datetime) -> str:
    """流年(按立春切换,非公历年)。"""
    lunar = Solar.fromDate(now).getLunar()
    return lunar.getYearInGanZhiByLiChun()


def build_current_day_pillar(now: datetime) -> str:
    """流日:当日日柱。sect=1。"""
    ec = Solar.fromDate(now).getLunar().getEightChar()
    ec.setSect(1)
    return ec.getDay()


def build_current_hour_pillar(now: datetime) -> str:
    """流时:当时时柱。sect=1。"""
    ec = Solar.fromDate(now).getLunar().getEightChar()
    ec.setSect(1)
    return ec.getTime()


def locate_current_luck_pillar(luck_pillars: list[LuckPillar],
                                now: datetime) -> Optional[CurrentPillar]:
    """在 luck_pillars 里定位当前大运。

    匹配条件:start_year <= now.year <= end_year。
    找不到 → None(不静默用默认值,前端展示「未入运」或「已出运」)。
    """
    year = now.year
    for lp in luck_pillars:
        if lp.start_year <= year <= lp.end_year:
            return CurrentPillar(gan_zhi=lp.gan_zhi,
                                  start_year=lp.start_year,
                                  end_year=lp.end_year)
    return None
