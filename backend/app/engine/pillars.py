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

# 地支 → 英文生肖名(对齐 iOS Assets.xcassets/Zodiac_*.imageset 命名)
# 单一事实源:后端 lunar_python 已按立春算 year.zhi,这里仅做地支→动物查表暴露
ZODIAC_NAME: dict[str, str] = {
    "子": "Rat", "丑": "Ox", "寅": "Tiger", "卯": "Rabbit",
    "辰": "Dragon", "巳": "Snake", "午": "Horse", "未": "Goat",
    "申": "Monkey", "酉": "Rooster", "戌": "Dog", "亥": "Pig",
}


def compute_year_zodiac(year_zhi: str) -> str:
    """年柱地支 → 英文生肖名(如 '辰' → 'Dragon')。

    由调用方保证 year_zhi 来自 pillars.year.zhi(lunar_python 已按立春算)。
    未知地支 → ValueError(对齐 _build_pillar 范式,不静默吞)。
    """
    if year_zhi not in ZODIAC_NAME:
        raise ValueError(f"未知年柱地支: {year_zhi!r}")
    return ZODIAC_NAME[year_zhi]

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
    """五行统计:遍历**已知柱**的天干 + 地支。

    藏干不计入主统计(避免重复加权);普通盘 4 柱 8 字,和 = 8。
    时辰未知(docs/时辰未知设计决策.md):时柱 None → 三柱 6 字,和 = 6;
    日柱亦歧义(hour_known=false 且 late_night != False)→ 两柱 4 字,和 = 4。
    按已知字数如实计数,不加标注字段(求和即口径)。
    """
    counts = {"wood": 0, "fire": 0, "earth": 0, "metal": 0, "water": 0}
    for p in (pillars.year, pillars.month, pillars.day, pillars.hour):
        if p is None:
            continue
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


# v1 prompt 系统 §1 chart.ten_god_weights
# 10 个十神固定清单(顺序与 lunar_python 八字保持一致)
TEN_GODS: tuple[str, ...] = (
    "比肩", "劫财", "食神", "伤官", "偏财",
    "正财", "七杀", "正官", "偏印", "正印",
)

# 日主字面值(lunar_python 日柱 shishen_gan 固定返回此值,非十神)
DAY_MASTER_LITERAL = "日主"
# 日柱在 (year, month, day, hour) 元组中的索引
_DAY_PILLAR_INDEX = 2

# 权重初值(待 prompt_validation spike 标定,目前是相对计数,LLM 看相对大小足够)
_GAN_WEIGHT = 5        # 天干十神:年/月/时柱 shishen_gan(日柱跳过,值是"日主")
_ZHI_MAIN_WEIGHT = 3   # 地支主气:shishen_zhi[0]
_ZHI_RESIDUAL_WEIGHT = 1  # 地支余气:shishen_zhi[1:]


def compute_ten_god_weights(pillars: Pillars) -> dict[str, int]:
    """全局十神权重统计(v1 prompt 系统 chart.ten_god_weights)。

    数据源:
    - 4 柱天干 shishen_gan 各 +_GAN_WEIGHT(日柱返回字面值"日主"非十神,跳过)
    - 4 柱地支主气 shishen_zhi[0] 各 +_ZHI_MAIN_WEIGHT
    - 4 柱地支余气 shishen_zhi[1:] 每个 +_ZHI_RESIDUAL_WEIGHT

    Returns:
        完整 10 个十神 → 计数 dict(未出现的十神为 0)。同输入同输出(确定性)。

    Raises:
        ValueError: 某柱 shishen_zhi 为空列表(地支必有藏干,空则数据异常);
            或某柱 shishen_gan 不在 TEN_GODS 且日柱不为"日主"(数据异常)
    """
    weights = {name: 0 for name in TEN_GODS}

    # 用 enumerate 索引显式跳过日柱,不依赖 Pydantic model 对象身份比较
    # (未来若 Pillars 改为 frozen / validate_all / __getattr__ 重建,"is" 比较会静默失败)
    all_pillars = (pillars.year, pillars.month, pillars.day, pillars.hour)
    for idx, p in enumerate(all_pillars):
        # 天干十神:跳过日柱("日主"非十神)
        if idx == _DAY_PILLAR_INDEX:
            # 防御:日柱 shishen_gan 必须是"日主";若数据异常返回其它值,
            # 不能静默跳过(CLAUDE.md 错误显式传播)
            if p.shishen_gan != DAY_MASTER_LITERAL:
                raise ValueError(
                    f"日柱 shishen_gan 应为 {DAY_MASTER_LITERAL!r},实得 "
                    f"{p.shishen_gan!r}, pillar={p.gan_zhi!r}"
                )
        else:
            if p.shishen_gan not in weights:
                raise ValueError(
                    f"未知天干十神: {p.shishen_gan!r}, pillar={p.gan_zhi!r}"
                )
            weights[p.shishen_gan] += _GAN_WEIGHT

        # 地支十神(藏干十神):主气 + 余气
        if not p.shishen_zhi:
            # 地支必有藏干,空则数据异常(不吞,显式抛)
            raise ValueError(
                f"地支藏干十神为空: pillar={p.gan_zhi!r} zhi={p.zhi!r}"
            )
        for zhi_idx, name in enumerate(p.shishen_zhi):
            if name not in weights:
                raise ValueError(
                    f"未知地支十神: {name!r}, pillar={p.gan_zhi!r}"
                )
            weights[name] += _ZHI_MAIN_WEIGHT if zhi_idx == 0 else _ZHI_RESIDUAL_WEIGHT

    return weights


def build_auxiliary_gong(ec: Any) -> tuple[GanZhiNaYin, GanZhiNaYin, GanZhiNaYin]:
    """命宫 / 身宫 / 胎元(库自带)。"""
    ming = GanZhiNaYin(gan_zhi=ec.getMingGong(), nayin=ec.getMingGongNaYin())
    shen = GanZhiNaYin(gan_zhi=ec.getShenGong(), nayin=ec.getShenGongNaYin())
    tai = GanZhiNaYin(gan_zhi=ec.getTaiYuan(), nayin=ec.getTaiYuanNaYin())
    return ming, shen, tai
