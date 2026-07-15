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

# ---------- 五行基础映射(单一事实源,xiji.py / compatibility.py 共用) ----------

# 英→中五行映射
EN2ZH: dict[str, str] = {
    "wood": "木", "fire": "火", "earth": "土", "metal": "金", "water": "水",
}

# 我生(食伤): 木→火→土→金→水→木
WO_SHENG: dict[str, str] = {
    "wood": "fire", "fire": "earth", "earth": "metal",
    "metal": "water", "water": "wood",
}

# 我克(财): 木→土→水→火→金→木
WO_KE: dict[str, str] = {
    "wood": "earth", "fire": "metal", "earth": "water",
    "metal": "wood", "water": "fire",
}

# 生我(印): 木←水, 火←木, 土←火, 金←土, 水←金
SHENG_WO: dict[str, str] = {
    "wood": "water", "fire": "wood", "earth": "fire",
    "metal": "earth", "water": "metal",
}

# 克我(官杀): 木←金, 火←水, 土←木, 金←火, 水←土
KE_WO: dict[str, str] = {
    "wood": "metal", "fire": "water", "earth": "wood",
    "metal": "fire", "water": "earth",
}


def _build_pillar(ec: Any, prefix: str) -> Pillar:
    """从 EightChar 构造单柱。

    prefix ∈ {"Year","Month","Day","Time"}
    """
    gan_zhi: str = getattr(ec, f"get{prefix}")()
    gan: str = getattr(ec, f"get{prefix}Gan")()
    zhi: str = getattr(ec, f"get{prefix}Zhi")()
    gan_element = GAN_ELEMENT.get(gan)
    if gan_element is None:
        raise ValueError(f"未知天干: {gan!r}")
    zhi_element = ZHI_ELEMENT.get(zhi)
    if zhi_element is None:
        raise ValueError(f"未知地支: {zhi!r}")
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
        gan_element=gan_element,
        zhi_element=zhi_element,
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
        if p.gan_element not in counts:
            raise ValueError(
                f"未知天干五行: {p.gan_element!r}, pillar={p.gan_zhi!r}"
            )
        if p.zhi_element not in counts:
            raise ValueError(
                f"未知地支五行: {p.zhi_element!r}, pillar={p.gan_zhi!r}"
            )
        counts[p.gan_element] += 1
        counts[p.zhi_element] += 1
    return ElementBalance(**counts)


def build_auxiliary_gong(ec: Any) -> tuple[GanZhiNaYin, GanZhiNaYin, GanZhiNaYin]:
    """命宫 / 身宫 / 胎元(库自带)。"""
    ming = GanZhiNaYin(gan_zhi=ec.getMingGong(), nayin=ec.getMingGongNaYin())
    shen = GanZhiNaYin(gan_zhi=ec.getShenGong(), nayin=ec.getShenGongNaYin())
    tai = GanZhiNaYin(gan_zhi=ec.getTaiYuan(), nayin=ec.getTaiYuanNaYin())
    return ming, shen, tai
