"""大运:跳过 index=0 童限(ganZhi="" 空字符串)。"""

from __future__ import annotations

from typing import Any

from ..models.bazi import LuckPillar


def build_luck_pillars(ec: Any, gender: str) -> list[LuckPillar]:
    """构造大运列表。

    坑2:index=0 是童限过渡,ganZhi="",前端跳过,从 index=1 开始。
    gender: "male" → lunar_python 的 1,"female" → 0
    sect 固定 1(调用方已 setSect)。
    """
    # lunar_python gender:1=男,0=女;sect=1
    lp_gender = 1 if gender == "male" else 0
    yun = ec.getYun(lp_gender, 1)
    da_yun_list = yun.getDaYun()

    result: list[LuckPillar] = []
    for i, dy in enumerate(da_yun_list):
        if i == 0:
            continue  # 童限过渡 ganZhi="",跳过
        gz = dy.getGanZhi()
        if not gz:
            # 防御性:末尾空值也跳(不静默,只是库的占位哨兵)
            continue
        result.append(LuckPillar(
            gan_zhi=gz,
            start_year=dy.getStartYear(),
            end_year=dy.getEndYear(),
            start_age=dy.getStartAge(),
            end_age=dy.getEndAge(),
        ))
    return result
