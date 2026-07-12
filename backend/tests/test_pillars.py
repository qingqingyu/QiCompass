"""四柱结构化边界测试。"""

from __future__ import annotations

import pytest

from app.engine.pillars import compute_element_balance
from app.models.bazi import Pillar, Pillars


def _pillar(*, gan_zhi: str = "甲子", gan_element: str = "wood",
            zhi_element: str = "water") -> Pillar:
    return Pillar(
        gan_zhi=gan_zhi,
        gan=gan_zhi[0],
        zhi=gan_zhi[1],
        gan_element=gan_element,
        zhi_element=zhi_element,
        hide_gan=[],
        shishen_gan="比肩",
        shishen_zhi=[],
        nayin="海中金",
        dishi="长生",
        xunkong="戌亥",
    )


def test_compute_element_balance_rejects_unknown_elements():
    """未知五行必须显式报错,不能静默少计后返回成功统计。"""
    pillars = Pillars(
        year=_pillar(gan_element="unknown"),
        month=_pillar(gan_zhi="乙丑", gan_element="wood", zhi_element="earth"),
        day=_pillar(gan_zhi="丙寅", gan_element="fire", zhi_element="wood"),
        hour=_pillar(gan_zhi="丁卯", gan_element="fire", zhi_element="wood"),
    )

    with pytest.raises(ValueError, match="未知天干五行"):
        compute_element_balance(pillars)
