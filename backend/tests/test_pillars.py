"""四柱结构化边界测试。"""

from __future__ import annotations

import pytest

from app.engine.pillars import (
    TEN_GODS,
    compute_element_balance,
    compute_ten_god_weights,
)
from app.models.bazi import Pillar, Pillars


def _pillar(*, gan_zhi: str = "甲子", gan_element: str = "wood",
            zhi_element: str = "water",
            shishen_gan: str = "比肩",
            shishen_zhi: list[str] | None = None) -> Pillar:
    return Pillar(
        gan_zhi=gan_zhi,
        gan=gan_zhi[0],
        zhi=gan_zhi[1],
        gan_element=gan_element,
        zhi_element=zhi_element,
        hide_gan=[],
        shishen_gan=shishen_gan,
        shishen_zhi=shishen_zhi if shishen_zhi is not None else [],
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


# ===== v1 prompt 系统:compute_ten_god_weights =====


def test_ten_god_weights_returns_all_ten_gods():
    """返回 dict 必须含完整 10 个十神 key(即使计数为 0)。"""
    pillars = Pillars(
        year=_pillar(shishen_gan="七杀", shishen_zhi=["正印"]),
        month=_pillar(shishen_gan="正财", shishen_zhi=["伤官"]),
        day=_pillar(shishen_gan="日主", shishen_zhi=["正印"]),
        hour=_pillar(shishen_gan="伤官", shishen_zhi=["劫财"]),
    )
    weights = compute_ten_god_weights(pillars)
    assert set(weights.keys()) == set(TEN_GODS), (
        f"缺十神 key: {set(TEN_GODS) - set(weights.keys())}"
    )


def test_ten_god_weights_skips_day_pillar_gan():
    """日柱 shishen_gan 是"日主"非十神,不应进入统计。"""
    pillars = Pillars(
        year=_pillar(shishen_gan="比肩", shishen_zhi=["比肩"]),
        month=_pillar(shishen_gan="比肩", shishen_zhi=["比肩"]),
        day=_pillar(shishen_gan="日主", shishen_zhi=["比肩"]),
        hour=_pillar(shishen_gan="比肩", shishen_zhi=["比肩"]),
    )
    weights = compute_ten_god_weights(pillars)
    # 3 个非日柱天干 + 4 个地支主气 = 3×5 + 4×3 = 27
    assert weights["比肩"] == 27


def test_ten_god_weights_residual_vs_main_distinction():
    """地支主气 shishen_zhi[0] 权重 3,余气 shishen_zhi[1:] 每个 +1。"""
    pillars = Pillars(
        year=_pillar(shishen_gan="正印", shishen_zhi=["食神", "正财", "七杀"]),
        month=_pillar(shishen_gan="正印", shishen_zhi=["比肩"]),
        day=_pillar(shishen_gan="日主", shishen_zhi=["比肩"]),
        hour=_pillar(shishen_gan="正印", shishen_zhi=["比肩"]),
    )
    weights = compute_ten_god_weights(pillars)
    # 食神:year 主气 3;正财/七杀:year 余气 各 1
    assert weights["食神"] == 3
    assert weights["正财"] == 1
    assert weights["七杀"] == 1
    # 正印:3 个非日柱天干 × 5 = 15
    assert weights["正印"] == 15
    # 比肩:month/day/hour 主气 × 3 = 9
    assert weights["比肩"] == 9


def test_ten_god_weights_rejects_empty_shishen_zhi():
    """shishen_zhi 为空 list 是数据异常(地支必有藏干),必须显式抛错。"""
    pillars = Pillars(
        year=_pillar(shishen_gan="比肩", shishen_zhi=[]),  # 空 → 异常
        month=_pillar(shishen_zhi=["比肩"]),
        day=_pillar(shishen_zhi=["比肩"]),
        hour=_pillar(shishen_zhi=["比肩"]),
    )
    with pytest.raises(ValueError, match="地支藏干十神为空"):
        compute_ten_god_weights(pillars)


def test_ten_god_weights_rejects_unknown_gan_shishen():
    """未知天干十神名必须报错,不静默跳过。"""
    pillars = Pillars(
        year=_pillar(shishen_gan="不存在的十神", shishen_zhi=["比肩"]),
        month=_pillar(shishen_zhi=["比肩"]),
        day=_pillar(shishen_zhi=["比肩"]),
        hour=_pillar(shishen_zhi=["比肩"]),
    )
    with pytest.raises(ValueError, match="未知天干十神"):
        compute_ten_god_weights(pillars)


def test_ten_god_weights_rejects_day_pillar_with_wrong_shishen_gan():
    """日柱 shishen_gan 必须是"日主",其它值是数据异常必须抛错(不静默跳过)。"""
    pillars = Pillars(
        year=_pillar(shishen_gan="比肩", shishen_zhi=["比肩"]),
        month=_pillar(shishen_zhi=["比肩"]),
        # 日柱 shishen_gan 不应是"比肩"(应为"日主")
        day=_pillar(shishen_gan="比肩", shishen_zhi=["比肩"]),
        hour=_pillar(shishen_zhi=["比肩"]),
    )
    with pytest.raises(ValueError, match="日柱 shishen_gan 应为"):
        compute_ten_god_weights(pillars)


def test_ten_god_weights_deterministic():
    """同输入同输出(确定性)。"""
    pillars = Pillars(
        year=_pillar(shishen_gan="七杀", shishen_zhi=["正印", "偏财"]),
        month=_pillar(shishen_gan="正财", shishen_zhi=["伤官"]),
        day=_pillar(shishen_gan="日主", shishen_zhi=["偏印"]),
        hour=_pillar(shishen_gan="伤官", shishen_zhi=["劫财", "食神"]),
    )
    w1 = compute_ten_god_weights(pillars)
    w2 = compute_ten_god_weights(pillars)
    assert w1 == w2
