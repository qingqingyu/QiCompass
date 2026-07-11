"""四柱结构化:从 lunar_python EightChar 提取年/月/日/时四柱。

天干地支五行用自写查表(稳定,不依赖 lunar_python 的五行字符串格式)。
"""

from __future__ import annotations

from typing import Any

from ..models.bazi import ElementBalance, GanZhiNaYin, Pillar, Pillars

# 天干 → 五行(英文 key,对齐文档 element_balance)
GAN_ELEMENT: dict[str, str] = {
    "甲": "wood", "乙": "wood",
    "丙": "fire", "丁": "fire",
    "戊": "earth", "己": "earth",
    "庚": "metal", "辛": "metal",
    "壬": "water", "癸": "water",
}

# 地支 → 五行
ZHI_ELEMENT: dict[str, str] = {
    "子": "water", "亥": "water",
    "寅": "wood", "卯": "wood",
    "巳": "fire", "午": "fire",
    "申": "metal", "酉": "metal",
    "辰": "earth", "戌": "earth", "丑": "earth", "未": "earth",
}

# 五行中文 → 英文(统计用)
WUXING_CN_TO_EN: dict[str, str] = {
    "金": "metal", "木": "wood", "水": "water",
    "火": "fire", "土": "earth",
}
WUXING_EN_TO_CN: dict[str, str] = {v: k for k, v in WUXING_CN_TO_EN.items()}


def _build_pillar(ec: Any, prefix: str) -> Pillar:
    """从 EightChar 构造单柱。

    prefix ∈ {"Year","Month","Day","Time"}
    """
    gan_zhi: str = getattr(ec, f"get{prefix}")()
    gan: str = getattr(ec, f"get{prefix}Gan")()
    zhi: str = getattr(ec, f"get{prefix}Zhi")()
    hide_gan: list[str] = list(getattr(ec, f"get{prefix}HideGan")())
    shishen_gan: str = getattr(ec, f"get{prefix}ShiShenGan")()
    shishen_zhi: list[str] = list(getattr(ec, f"get{prefix}ShiShenZhi")())
    nayin: str = getattr(ec, f"get{prefix}NaYin")()
    dishi: str = getattr(ec, f"get{prefix}DiShi")()
    xunkong: str = getattr(ec, f"get{prefix}XunKong")()

    return Pillar(
        gan_zhi=gan_zhi,
        gan=gan,
        zhi=zhi,
        gan_element=GAN_ELEMENT.get(gan, "unknown"),
        zhi_element=ZHI_ELEMENT.get(zhi, "unknown"),
        hide_gan=hide_gan,
        shishen_gan=shishen_gan,
        shishen_zhi=shishen_zhi,
        nayin=nayin,
        dishi=dishi,
        xunkong=xunkong,
    )


def build_pillars(ec: Any) -> Pillars:
    """构造四柱。调用方必须已 setSect(1)。"""
    return Pillars(
        year=_build_pillar(ec, "Year"),
        month=_build_pillar(ec, "Month"),
        day=_build_pillar(ec, "Day"),
        hour=_build_pillar(ec, "Time"),
    )


def compute_element_balance(pillars: Pillars) -> ElementBalance:
    """五行统计:遍历四柱 8 字(4 天干 + 4 地支)。

    藏干不计入主统计(避免重复加权);文档示例 element_balance 之和 = 8。
    """
    counts = {"wood": 0, "fire": 0, "earth": 0, "metal": 0, "water": 0}
    for p in (pillars.year, pillars.month, pillars.day, pillars.hour):
        if p.gan_element in counts:
            counts[p.gan_element] += 1
        if p.zhi_element in counts:
            counts[p.zhi_element] += 1
    return ElementBalance(**counts)


def build_auxiliary_gong(ec: Any) -> tuple[GanZhiNaYin, GanZhiNaYin, GanZhiNaYin]:
    """命宫 / 身宫 / 胎元(库自带)。"""
    ming = GanZhiNaYin(gan_zhi=ec.getMingGong(), nayin=ec.getMingGongNaYin())
    shen = GanZhiNaYin(gan_zhi=ec.getShenGong(), nayin=ec.getShenGongNaYin())
    tai = GanZhiNaYin(gan_zhi=ec.getTaiYuan(), nayin=ec.getTaiYuanNaYin())
    return ming, shen, tai
