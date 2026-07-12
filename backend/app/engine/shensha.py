"""神煞查表(决策 2):《三命通会》20 个固定清单,自写静态查表。

单一来源原则:所有起法以《三命通会》为准,不东拼西凑。
输出顺序固定:20 清单顺序 × 年月日时柱顺序,保证完全确定性。
未命中返回空列表,不报成功假数据(错误显式传播)。

【方案偏离说明】compute_shensha 签名加 gender 参数:
《三命通会》元辰(大耗)起法明确分"阳男阴女顺/阴男阳女逆",
严格单一来源原则下必须传入 gender 才能正确查表。
方案 5.1 初稿签名 compute_shensha(pillars) 不够,实现时补 gender。
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Literal, NamedTuple

from ..engine.pillars import GAN_ELEMENT, ZHI_ELEMENT
from ..models.bazi import Pillars, ShenshaItem

# ---------- 四柱迭代辅助 ----------

# (attr, label) 按年月日时固定顺序
_PILLAR_LABELS: tuple[tuple[str, str], ...] = (
    ("year", "年柱"),
    ("month", "月柱"),
    ("day", "日柱"),
    ("hour", "时柱"),
)


def _pillar_iter(pillars: Pillars) -> tuple[tuple[str, str, str, str], ...]:
    """按 年月日时 顺序返回四柱 (attr, label, gan, zhi)。"""
    return tuple(
        (attr, label, getattr(pillars, attr).gan, getattr(pillars, attr).zhi)
        for attr, label in _PILLAR_LABELS
    )


def _validate_pillars(pillars: Pillars) -> None:
    """校验四柱干支均在基础表中,避免查表路径把未知值当成普通分支。"""
    for attr, label, gan, zhi in _pillar_iter(pillars):
        if gan not in GAN_ELEMENT:
            raise ValueError(f"未知天干,无法计算神煞:{label}({attr}) gan={gan!r}")
        if zhi not in ZHI_ELEMENT:
            raise ValueError(f"未知地支,无法计算神煞:{label}({attr}) zhi={zhi!r}")


# ---------- 三合局 / 三会局 ----------

# 三合局(B 类神煞基准分组)
SANHE_GROUPS: dict[str, tuple[str, str, str]] = {
    "申子辰": ("申", "子", "辰"),
    "寅午戌": ("寅", "午", "戌"),
    "巳酉丑": ("巳", "酉", "丑"),
    "亥卯未": ("亥", "卯", "未"),
}

# 三会局(D 类孤辰寡宿基准分组)
SANHUI_GROUPS: dict[str, tuple[str, str, str]] = {
    "亥子丑": ("亥", "子", "丑"),
    "寅卯辰": ("寅", "卯", "辰"),
    "巳午未": ("巳", "午", "未"),
    "申酉戌": ("申", "酉", "戌"),
}


def _sanhe_group_of(zhi: str) -> str:
    """返回地支所属三合局名(如 '申子辰')。未命中抛 ValueError(不静默吞)。"""
    for name, members in SANHE_GROUPS.items():
        if zhi in members:
            return name
    raise ValueError(f"未知地支,无法归入三合局: {zhi!r}")


def _sanhui_group_of(zhi: str) -> str:
    """返回地支所属三会局名。未命中抛 ValueError。"""
    for name, members in SANHUI_GROUPS.items():
        if zhi in members:
            return name
    raise ValueError(f"未知地支,无法归入三会局: {zhi!r}")


# ---------- A 类:日干查四柱地支 ----------

# 天乙贵人:《三命通会》甲戊庚→丑未,乙己→子申,丙丁→亥酉,壬癸→卯巳,辛→寅午
TIANYI: dict[str, list[str]] = {
    "甲": ["丑", "未"], "戊": ["丑", "未"], "庚": ["丑", "未"],
    "乙": ["子", "申"], "己": ["子", "申"],
    "丙": ["亥", "酉"], "丁": ["亥", "酉"],
    "壬": ["卯", "巳"], "癸": ["卯", "巳"],
    "辛": ["寅", "午"],
}

# 太极贵人:甲乙→子午,丙丁→卯酉,戊己→辰戌丑未,庚辛→寅亥,壬癸→巳申
TAIJI: dict[str, list[str]] = {
    "甲": ["子", "午"], "乙": ["子", "午"],
    "丙": ["卯", "酉"], "丁": ["卯", "酉"],
    "戊": ["辰", "戌", "丑", "未"], "己": ["辰", "戌", "丑", "未"],
    "庚": ["寅", "亥"], "辛": ["寅", "亥"],
    "壬": ["巳", "申"], "癸": ["巳", "申"],
}

# 文昌:甲→巳,乙→午,丙戊→申,丁己→酉,庚→亥,辛→子,壬→寅,癸→卯
WENCHANG: dict[str, list[str]] = {
    "甲": ["巳"], "乙": ["午"], "丙": ["申"], "戊": ["申"],
    "丁": ["酉"], "己": ["酉"], "庚": ["亥"], "辛": ["子"],
    "壬": ["寅"], "癸": ["卯"],
}

# 金舆:甲→辰,乙→巳,丙戊→未,丁己→申,庚→戌,辛→亥,壬→丑,癸→寅
JINYU: dict[str, list[str]] = {
    "甲": ["辰"], "乙": ["巳"], "丙": ["未"], "戊": ["未"],
    "丁": ["申"], "己": ["申"], "庚": ["戌"], "辛": ["亥"],
    "壬": ["丑"], "癸": ["寅"],
}

# 禄神:甲→寅,乙→卯,丙戊→巳,丁己→午,庚→申,辛→酉,壬→亥,癸→子
LU: dict[str, list[str]] = {
    "甲": ["寅"], "乙": ["卯"], "丙": ["巳"], "戊": ["巳"],
    "丁": ["午"], "己": ["午"], "庚": ["申"], "辛": ["酉"],
    "壬": ["亥"], "癸": ["子"],
}

# 羊刃:甲→卯,乙→辰,丙戊→午,丁己→未,庚→酉,辛→戌,壬→子,癸→丑
YANGREN: dict[str, list[str]] = {
    "甲": ["卯"], "乙": ["辰"], "丙": ["午"], "戊": ["午"],
    "丁": ["未"], "己": ["未"], "庚": ["酉"], "辛": ["戌"],
    "壬": ["子"], "癸": ["丑"],
}

# 红艳:甲乙→午,丙→寅,丁→未,戊己→辰,庚→戌,辛→酉,壬→子,癸→申
HONGYAN: dict[str, list[str]] = {
    "甲": ["午"], "乙": ["午"], "丙": ["寅"], "丁": ["未"],
    "戊": ["辰"], "己": ["辰"], "庚": ["戌"], "辛": ["酉"],
    "壬": ["子"], "癸": ["申"],
}

# ---------- B 类:年支/日支查四柱地支(三合局) ----------
# 双查:年支 + 日支各作为基准查一次(方案 5.4 决策点 1,对齐问真)

# 驿马:申子辰→寅,寅午戌→申,巳酉丑→亥,亥卯未→巳
YIMA: dict[str, str] = {
    "申子辰": "寅", "寅午戌": "申", "巳酉丑": "亥", "亥卯未": "巳",
}

# 桃花(咸池):申子辰→酉,寅午戌→卯,巳酉丑→午,亥卯未→子
TAOHUA: dict[str, str] = {
    "申子辰": "酉", "寅午戌": "卯", "巳酉丑": "午", "亥卯未": "子",
}

# 将星:申子辰→子,寅午戌→午,巳酉丑→酉,亥卯未→卯
JIANGXING: dict[str, str] = {
    "申子辰": "子", "寅午戌": "午", "巳酉丑": "酉", "亥卯未": "卯",
}

# 华盖:申子辰→辰,寅午戌→戌,巳酉丑→丑,亥卯未→未
HUAGAI: dict[str, str] = {
    "申子辰": "辰", "寅午戌": "戌", "巳酉丑": "丑", "亥卯未": "未",
}

# 劫煞:申子辰→巳,寅午戌→亥,巳酉丑→寅,亥卯未→申
JIESHA: dict[str, str] = {
    "申子辰": "巳", "寅午戌": "亥", "巳酉丑": "寅", "亥卯未": "申",
}

# 亡神:申子辰→亥,寅午戌→巳,巳酉丑→申,亥卯未→寅
WANGSHEN: dict[str, str] = {
    "申子辰": "亥", "寅午戌": "巳", "巳酉丑": "申", "亥卯未": "寅",
}

# 灾煞:申子辰→午,寅午戌→子,巳酉丑→卯,亥卯未→酉
ZAISHA: dict[str, str] = {
    "申子辰": "午", "寅午戌": "子", "巳酉丑": "卯", "亥卯未": "酉",
}

# ---------- C 类:月支查四柱天干/地支 ----------

# 天德:《三命通会》正月寅→丁,二月卯→申(坤),三月辰→壬,四月巳→辛,
#        五月午→亥(乾),六月未→甲,七月申→癸,八月酉→寅(艮),
#        九月戌→丙,十月亥→乙,十一月子→巳(巽),十二月丑→庚
# 注:申/亥/寅/巳 为四维卦对应地支,查四柱天干或地支命中
TIANDE: dict[str, list[str]] = {
    "寅": ["丁"], "卯": ["申"], "辰": ["壬"], "巳": ["辛"],
    "午": ["亥"], "未": ["甲"], "申": ["癸"], "酉": ["寅"],
    "戌": ["丙"], "亥": ["乙"], "子": ["巳"], "丑": ["庚"],
}

# 月德:寅午戌→丙,申子辰→壬,亥卯未→甲,巳酉丑→庚(查四柱天干)
YUEDE: dict[str, list[str]] = {
    "寅": ["丙"], "午": ["丙"], "戌": ["丙"],
    "申": ["壬"], "子": ["壬"], "辰": ["壬"],
    "亥": ["甲"], "卯": ["甲"], "未": ["甲"],
    "巳": ["庚"], "酉": ["庚"], "丑": ["庚"],
}

# ---------- D 类:年支查四柱地支 ----------

# 孤辰:亥子丑→寅,寅卯辰→巳,巳午未→申,申酉戌→亥(按年支三会局)
GUCHEN: dict[str, str] = {
    "亥": "寅", "子": "寅", "丑": "寅",
    "寅": "巳", "卯": "巳", "辰": "巳",
    "巳": "申", "午": "申", "未": "申",
    "申": "亥", "酉": "亥", "戌": "亥",
}

# 寡宿:亥子丑→戌,寅卯辰→丑,巳午未→辰,申酉戌→未(按年支三会局)
GUASHU: dict[str, str] = {
    "亥": "戌", "子": "戌", "丑": "戌",
    "寅": "丑", "卯": "丑", "辰": "丑",
    "巳": "辰", "午": "辰", "未": "辰",
    "申": "未", "酉": "未", "戌": "未",
}

# 元辰(大耗):《三命通会》阳男阴女取冲前一位(顺),阴男阳女取冲后一位(逆)
# 顺行(阳男阴女):子→未,丑→午,寅→酉,卯→申,辰→亥,巳→戌,午→丑,未→子,申→卯,酉→寅,戌→巳,亥→辰
YUANCHEN_FORWARD: dict[str, str] = {
    "子": "未", "丑": "午", "寅": "酉", "卯": "申",
    "辰": "亥", "巳": "戌", "午": "丑", "未": "子",
    "申": "卯", "酉": "寅", "戌": "巳", "亥": "辰",
}
# 逆行(阴男阳女):子→巳,丑→辰,寅→未,卯→午,辰→酉,巳→申,午→亥,未→戌,申→丑,酉→子,戌→卯,亥→寅
YUANCHEN_BACKWARD: dict[str, str] = {
    "子": "巳", "丑": "辰", "寅": "未", "卯": "午",
    "辰": "酉", "巳": "申", "午": "亥", "未": "戌",
    "申": "丑", "酉": "子", "戌": "卯", "亥": "寅",
}

# 阳年干:甲丙戊庚壬
YANG_GAN: frozenset[str] = frozenset({"甲", "丙", "戊", "庚", "壬"})

# 天罗地网:《三命通会》辰为天罗,戌为地网
# 查四柱地支含辰→天罗地网,含戌→天罗地网(通用查法,不区分命局纳音)
TIANLUO_ZHI: str = "辰"
DIWANG_ZHI: str = "戌"

# ---------- 20 个神煞清单(固定顺序,对齐决策文档) ----------
# 吉神 11 + 凶煞 9 = 20;红艳传统吉凶参半,归凶煞以平衡

SHENSHA_NAMES: tuple[str, ...] = (
    # 吉神 11
    "天乙贵人", "太极贵人", "文昌", "天德", "月德",
    "驿马", "桃花", "将星", "华盖", "金舆", "禄神",
    # 凶煞 9
    "羊刃", "劫煞", "亡神", "孤辰", "寡宿",
    "元辰", "灾煞", "天罗地网", "红艳",
)

AUSPICIOUS: frozenset[str] = frozenset(SHENSHA_NAMES[:11])
INAUSPICIOUS: frozenset[str] = frozenset(SHENSHA_NAMES[11:])


# ---------- ShenshaRule 统一结构 ----------

class ShenshaRule(NamedTuple):
    """单条神煞查表规则(内部结构,不进 API)。

    matcher 接收 (pillars, gender),返回命中的 position 列表(按年月日时顺序)。
    matcher 内部负责查表与去重,未命中返回空列表,查表缺失抛 ValueError。
    """

    name: str
    polarity: str  # "auspicious"|"inauspicious"
    note: str  # 《三命通会》起法注释
    matcher: Callable[[Pillars, Literal["male", "female"]], list[str]]


# ---------- matcher 实现 ----------

def _match_day_gan_zhi(table: dict[str, list[str]]) -> Callable[[Pillars, str], list[str]]:
    """A 类:日干查四柱地支。返回命中的 position 列表。"""
    def _matcher(pillars: Pillars, _gender: str) -> list[str]:
        day_gan = pillars.day.gan
        targets = table.get(day_gan)
        if targets is None:
            raise ValueError(f"神煞查表缺失:未知日干 {day_gan!r}")
        return [label for _attr, label, _gan, zhi in _pillar_iter(pillars)
                if zhi in targets]
    return _matcher


def _match_sanhe_dual(table: dict[str, str]) -> Callable[[Pillars, str], list[str]]:
    """B 类:年支 + 日支双查四柱地支(三合局)。同柱命中只算一条(去重)。"""
    def _matcher(pillars: Pillars, _gender: str) -> list[str]:
        # 预计算年支/日支对应的查表目标(合并去重)
        targets: set[str] = set()
        for anchor_zhi in (pillars.year.zhi, pillars.day.zhi):
            group = _sanhe_group_of(anchor_zhi)
            target = table.get(group)
            if target is None:
                raise ValueError(f"神煞三合查表缺失:未知三合局 {group!r}")
            targets.add(target)
        # 按年月日时顺序遍历四柱,命中任一目标即记录(天然去重 + 保序)
        return [label for _attr, label, _gan, zhi in _pillar_iter(pillars)
                if zhi in targets]
    return _matcher


def _match_tiande(pillars: Pillars, _gender: str) -> list[str]:
    """C 类天德:月支查四柱天干或地支(含四维卦地支)。"""
    month_zhi = pillars.month.zhi
    targets = TIANDE.get(month_zhi)
    if targets is None:
        raise ValueError(f"天德查表缺失:未知月支 {month_zhi!r}")
    hits: list[str] = []
    for _attr, label, gan, zhi in _pillar_iter(pillars):
        if gan in targets or zhi in targets:
            hits.append(label)
    return hits


def _match_yuede(pillars: Pillars, _gender: str) -> list[str]:
    """C 类月德:月支查四柱天干。"""
    month_zhi = pillars.month.zhi
    targets = YUEDE.get(month_zhi)
    if targets is None:
        raise ValueError(f"月德查表缺失:未知月支 {month_zhi!r}")
    return [label for _attr, label, gan, _zhi in _pillar_iter(pillars)
            if gan in targets]


def _match_guchen(pillars: Pillars, _gender: str) -> list[str]:
    """D 类孤辰:年支三会局查四柱地支。"""
    year_zhi = pillars.year.zhi
    target = GUCHEN.get(year_zhi)
    if target is None:
        raise ValueError(f"孤辰查表缺失:未知年支 {year_zhi!r}")
    return [label for _attr, label, _gan, zhi in _pillar_iter(pillars)
            if zhi == target]


def _match_guashu(pillars: Pillars, _gender: str) -> list[str]:
    """D 类寡宿:年支三会局查四柱地支。"""
    year_zhi = pillars.year.zhi
    target = GUASHU.get(year_zhi)
    if target is None:
        raise ValueError(f"寡宿查表缺失:未知年支 {year_zhi!r}")
    return [label for _attr, label, _gan, zhi in _pillar_iter(pillars)
            if zhi == target]


def _match_yuanchen(pillars: Pillars, gender: str) -> list[str]:
    """D 类元辰:年支 + 性别 + 年干阴阳查四柱地支。

    《三命通会》阳男阴女取冲前一位(顺),阴男阳女取冲后一位(逆)。
    """
    year_gan = pillars.year.gan
    year_zhi = pillars.year.zhi
    is_yang_gan = year_gan in YANG_GAN
    # 阳男阴女顺行,阴男阳女逆行
    forward = (is_yang_gan and gender == "male") or \
              (not is_yang_gan and gender == "female")
    table = YUANCHEN_FORWARD if forward else YUANCHEN_BACKWARD
    target = table.get(year_zhi)
    if target is None:
        raise ValueError(f"元辰查表缺失:未知年支 {year_zhi!r}")
    return [label for _attr, label, _gan, zhi in _pillar_iter(pillars)
            if zhi == target]


def _match_tianluodiwang(pillars: Pillars, _gender: str) -> list[str]:
    """D 类天罗地网:四柱地支含辰(天罗)或戌(地网)。"""
    hits: list[str] = []
    for _attr, label, _gan, zhi in _pillar_iter(pillars):
        if zhi == TIANLUO_ZHI or zhi == DIWANG_ZHI:
            hits.append(label)
    return hits


# ---------- 20 条规则(固定顺序,对齐 SHENSHA_NAMES) ----------

SHENSHA_RULES: tuple[ShenshaRule, ...] = (
    # 吉神 11
    ShenshaRule("天乙贵人", "auspicious", "日干查地支,《三命通会》甲戊庚丑未、乙己子申、丙丁亥酉、壬癸卯巳、辛寅午",
                _match_day_gan_zhi(TIANYI)),
    ShenshaRule("太极贵人", "auspicious", "日干查地支,甲乙子午、丙丁卯酉、戊己辰戌丑未、庚辛寅亥、壬癸巳申",
                _match_day_gan_zhi(TAIJI)),
    ShenshaRule("文昌", "auspicious", "日干查地支,甲巳乙午丙戊申丁己酉庚亥辛子壬寅癸卯",
                _match_day_gan_zhi(WENCHANG)),
    ShenshaRule("天德", "auspicious", "月支查天干/四维地支,正月丁二月申三月壬四月辛五月亥六月甲七月癸八月寅九月丙十月乙十一月巳十二月庚",
                _match_tiande),
    ShenshaRule("月德", "auspicious", "月支查天干,寅午戌丙、申子辰壬、亥卯未甲、巳酉丑庚",
                _match_yuede),
    ShenshaRule("驿马", "auspicious", "年支/日支三合局查地支,申子辰寅、寅午戌申、巳酉丑亥、亥卯未巳",
                _match_sanhe_dual(YIMA)),
    ShenshaRule("桃花", "auspicious", "年支/日支三合局查地支(咸池),申子辰酉、寅午戌卯、巳酉丑午、亥卯未子",
                _match_sanhe_dual(TAOHUA)),
    ShenshaRule("将星", "auspicious", "年支/日支三合局查地支,申子辰子、寅午戌午、巳酉丑酉、亥卯未卯",
                _match_sanhe_dual(JIANGXING)),
    ShenshaRule("华盖", "auspicious", "年支/日支三合局查地支,申子辰辰、寅午戌戌、巳酉丑丑、亥卯未未",
                _match_sanhe_dual(HUAGAI)),
    ShenshaRule("金舆", "auspicious", "日干查地支,甲辰乙巳丙戊未丁己申庚戌辛亥壬丑癸寅",
                _match_day_gan_zhi(JINYU)),
    ShenshaRule("禄神", "auspicious", "日干查地支,甲寅乙卯丙戊巳丁己午庚申辛酉壬亥癸子",
                _match_day_gan_zhi(LU)),
    # 凶煞 9
    ShenshaRule("羊刃", "inauspicious", "日干查地支,甲卯乙辰丙戊午丁己未庚酉辛戌壬子癸丑",
                _match_day_gan_zhi(YANGREN)),
    ShenshaRule("劫煞", "inauspicious", "年支/日支三合局查地支,申子辰巳、寅午戌亥、巳酉丑寅、亥卯未申",
                _match_sanhe_dual(JIESHA)),
    ShenshaRule("亡神", "inauspicious", "年支/日支三合局查地支,申子辰亥、寅午戌巳、巳酉丑申、亥卯未寅",
                _match_sanhe_dual(WANGSHEN)),
    ShenshaRule("孤辰", "inauspicious", "年支三会局查地支,亥子丑寅、寅卯辰巳、巳午未申、申酉戌亥",
                _match_guchen),
    ShenshaRule("寡宿", "inauspicious", "年支三会局查地支,亥子丑戌、寅卯辰丑、巳午未辰、申酉戌未",
                _match_guashu),
    ShenshaRule("元辰", "inauspicious", "年支+性别+年干阴阳查地支(大耗),阳男阴女顺、阴男阳女逆",
                _match_yuanchen),
    ShenshaRule("灾煞", "inauspicious", "年支/日支三合局查地支,申子辰午、寅午戌子、巳酉丑卯、亥卯未酉",
                _match_sanhe_dual(ZAISHA)),
    ShenshaRule("天罗地网", "inauspicious", "四柱地支含辰(天罗)或戌(地网)",
                _match_tianluodiwang),
    ShenshaRule("红艳", "inauspicious", "日干查地支,甲乙午丙寅丁未戊己辰庚戌辛酉壬子癸申",
                _match_day_gan_zhi(HONGYAN)),
)


# ---------- 主入口 ----------

def compute_shensha(pillars: Pillars, gender: str) -> list[ShenshaItem]:
    """计算 20 神煞命中列表。

    Args:
        pillars: 四柱(已含干支)
        gender: "male"|"female",用于元辰顺逆查表

    Returns:
        按 20 清单顺序 × 年月日时柱顺序排列的命中列表。
        未命中返回空列表(不报成功假数据)。

    Raises:
        ValueError: 查表缺失(未知干支)——由 BaziEngine 包装为 BaziCalculationFailedError
    """
    if gender not in ("male", "female"):
        raise ValueError(f"非法 gender: {gender!r}(必须 male/female)")
    _validate_pillars(pillars)

    results: list[ShenshaItem] = []
    for rule in SHENSHA_RULES:
        positions = rule.matcher(pillars, gender)
        for pos in positions:
            results.append(ShenshaItem(
                name=rule.name, position=pos, source="三命通会",
            ))
    return results
