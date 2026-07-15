"""喜忌引擎(决策 1):扶抑法 + 调候法 + 从格检测(D3)。

确定性纯函数,同输入同输出。LLM 只润色不判断。
计算顺序(关键):从格检测优先于扶抑 —— 命中从格特征则诚实降级,不硬塞扶抑。

权重/阈值全部集中在本模块常量,便于 50 盘 spike 后标定,不散落在业务流程中。
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ..engine.pillars import (
    GAN_ELEMENT, ZHI_ELEMENT,
    EN2ZH, SHENG_WO, WO_SHENG, WO_KE, KE_WO,
)
from ..models.bazi import ElementBalance, Pillars

# ---------- 调候用神 ----------

# 极寒月(子、丑)喜火暖局;极热月(午、未)喜水润局
TIAOSHOU: dict[str, str] = {
    "子": "fire", "丑": "fire",
    "午": "water", "未": "water",
}

# ---------- 扶抑打分权重(初值,待 50 盘 spike 标定) ----------

DELING_WEIGHT = 5          # 得令:月支主气同类/生我
DEDI_MAIN_WEIGHT = 2       # 得地:日支主气同类/生我
DEDI_RESIDUAL_WEIGHT = 1   # 得地:日支余气同类/生我(每个)
DESHI_WEIGHT = 1           # 得势:年/月/时干每个同类/生我

# 强弱阈值(初值,待 50 盘 spike 标定)
STRONG_THRESHOLD = 6       # score >= 6 → strong
WEAK_THRESHOLD = 3         # score <= 3 → weak
# 4-5 → balanced;balanced 时按 score 倾斜:>= 中点偏强走 strong 喜忌,< 中点偏弱走 weak
BALANCED_TILT_THRESHOLD = (STRONG_THRESHOLD + WEAK_THRESHOLD) / 2  # 4.5

# 从格阈值(初值,待 50 盘 spike 标定)
ZHUANWANG_THRESHOLD = 6    # 日主同气五行 >= 6 → 专旺
CONG_THRESHOLD = 5         # 某一行 >= 5 → 从格(需日主孤立)


# ---------- 输出结构 ----------

@dataclass
class XijiResult:
    """喜忌引擎输出(对应决策 1 输出结构)。"""

    day_master_strength: str  # strong|weak|balanced|special_pattern
    favorable_elements: list[str] = field(default_factory=list)
    unfavorable_elements: list[str] = field(default_factory=list)
    tiaoshou_applied: bool = False
    xiji_method: str = ""
    pattern_hint: str | None = None  # "zhuanwang"|"cong"|None
    # 内部字段(不进 API):扶抑打分,special_pattern 时为 -1 表示未计算
    score: int = -1


# ---------- 内部辅助 ----------

def _element_of_gan(gan: str) -> str:
    """天干 → 五行(英文)。未知抛 ValueError。"""
    elem = GAN_ELEMENT.get(gan)
    if elem is None:
        raise ValueError(f"未知天干: {gan!r}")
    return elem


def _element_of_zhi(zhi: str) -> str:
    """地支主气 → 五行(英文)。未知抛 ValueError。"""
    elem = ZHI_ELEMENT.get(zhi)
    if elem is None:
        raise ValueError(f"未知地支: {zhi!r}")
    return elem


def _is_support(element: str, day_element: str) -> bool:
    """该五行是否生扶日主(同类比劫 或 生我印)。"""
    return element == day_element or element == SHENG_WO[day_element]


# ---------- 从格检测(D3) ----------

def _detect_special_pattern(
    pillars: Pillars,
    counts: dict[str, int],
    day_element: str,
) -> str | None:
    """从格特征检测:返回 'zhuanwang'|'cong'|None。

    - 专旺:element_balance[日主同气五行] >= 6(8 字中 6 个同气)
    - 从格:天干(年/月/时干)无印(生我)无比劫(同我) + 某行(非日主) >= 5

    命中任一返回对应 hint,否则 None。
    """
    # 专旺
    if counts[day_element] >= ZHUANWANG_THRESHOLD:
        return "zhuanwang"

    # 从格:日主孤立(年/月/时干无印无比劫) + 某非日主行 >= 5
    sheng_wo = SHENG_WO[day_element]
    other_gans = (pillars.year.gan, pillars.month.gan, pillars.hour.gan)
    no_support = all(
        _element_of_gan(g) not in (day_element, sheng_wo)
        for g in other_gans
    )
    if no_support:
        for elem, cnt in counts.items():
            if elem != day_element and cnt >= CONG_THRESHOLD:
                return "cong"

    return None


# ---------- 扶抑打分 ----------

def _compute_fuyi_score(pillars: Pillars, day_element: str) -> int:
    """扶抑打分 = 得令 + 得地 + 得势。

    - 得令:月支主气同类/生我 → +DELING_WEIGHT
    - 得地:日支藏干主气同类/生我 → +DEDI_MAIN_WEIGHT;余气每个 +DEDI_RESIDUAL_WEIGHT
    - 得势:年/月/时干每个同类/生我 → +DESHI_WEIGHT
    """
    score = 0

    # 得令:月支主气
    month_zhi_element = _element_of_zhi(pillars.month.zhi)
    if _is_support(month_zhi_element, day_element):
        score += DELING_WEIGHT

    # 得地:日支藏干(pillars.day.hide_gan[0] 是主气,其余是余气)
    hide_gan = pillars.day.hide_gan
    if not hide_gan:
        # 地支必有藏干,空则数据异常,抛出(不吞)
        raise ValueError(
            f"日支藏干为空:日柱 {pillars.day.gan_zhi!r} zhi={pillars.day.zhi!r}"
        )
    for idx, gan in enumerate(hide_gan):
        if _is_support(_element_of_gan(gan), day_element):
            score += DEDI_MAIN_WEIGHT if idx == 0 else DEDI_RESIDUAL_WEIGHT

    # 得势:年/月/时干
    for gan in (pillars.year.gan, pillars.month.gan, pillars.hour.gan):
        if _is_support(_element_of_gan(gan), day_element):
            score += DESHI_WEIGHT

    return score


# ---------- 喜忌五行映射 ----------

def _map_xiji(day_element: str, strength: str) -> tuple[list[str], list[str]]:
    """根据日主五行和强弱方向返回 (喜用五行,忌五行),中文。

    调用方负责将 balanced 倾斜为 "strong" 或 "weak" 后再传入;
    本函数只处理 "strong"(喜克泄耗)和 "weak"(喜生扶)两种方向。

    身强 → 喜克泄耗(食伤/财/官杀),忌生扶(印/比劫)
    身弱 → 喜生扶(印/比劫),忌克泄耗(食伤/财/官杀)
    """
    same = day_element                              # 比劫
    sheng_wo = SHENG_WO[day_element]                # 印
    wo_sheng = WO_SHENG[day_element]                # 食伤
    wo_ke = WO_KE[day_element]                      # 财
    ke_wo = KE_WO[day_element]                      # 官杀

    if strength == "strong":
        favorable = [EN2ZH[wo_sheng], EN2ZH[wo_ke], EN2ZH[ke_wo]]
        unfavorable = [EN2ZH[same], EN2ZH[sheng_wo]]
    else:
        # weak(身弱,喜生扶)
        favorable = [EN2ZH[same], EN2ZH[sheng_wo]]
        unfavorable = [EN2ZH[wo_sheng], EN2ZH[wo_ke], EN2ZH[ke_wo]]
    return favorable, unfavorable


# ---------- 调候修正 ----------

def _apply_tiaoshou(
    favorable: list[str],
    unfavorable: list[str],
    month_zhi: str,
) -> tuple[list[str], list[str], bool]:
    """调候修正:极寒/极热月叠加调候用神,优先级高于扶抑。

    调候用神与扶抑忌神冲突时,从 unfavorable 移除并放入 favorable 首位。
    Returns: (新 favorable, 新 unfavorable, tiaoshou_applied)
    """
    tiaoshou_elem = TIAOSHOU.get(month_zhi)
    if tiaoshou_elem is None:
        return favorable, unfavorable, False

    tiaoshou_zh = EN2ZH[tiaoshou_elem]
    new_favorable = list(favorable)
    new_unfavorable = list(unfavorable)

    # 冲突处理:调候用神在忌神列表 → 移除
    if tiaoshou_zh in new_unfavorable:
        new_unfavorable.remove(tiaoshou_zh)
    # 放入 favorable 首位(若不在)
    if tiaoshou_zh not in new_favorable:
        new_favorable.insert(0, tiaoshou_zh)

    return new_favorable, new_unfavorable, True


# ---------- 主入口 ----------

def compute_xiji(pillars: Pillars, element_balance: ElementBalance) -> XijiResult:
    """计算喜忌。

    Args:
        pillars: 四柱(已含干支/藏干)
        element_balance: 五行统计(4 干 + 4 支主气,和 = 8)

    Returns:
        XijiResult,普通盘返回 strong/weak/balanced + 喜忌;
        从格特征命中返回 special_pattern + 空喜忌(诚实降级)。

    Raises:
        ValueError: 未知干支/藏干缺失 —— 由 BaziEngine 包装为 BaziCalculationFailedError
    """
    day_gan = pillars.day.gan
    day_element = _element_of_gan(day_gan)
    counts = element_balance.model_dump()

    # 1. 从格检测(优先于扶抑)
    pattern = _detect_special_pattern(pillars, counts, day_element)
    if pattern is not None:
        return XijiResult(
            day_master_strength="special_pattern",
            favorable_elements=[],
            unfavorable_elements=[],
            tiaoshou_applied=False,
            xiji_method="扶抑+调候(从格特征检测命中,未判定具体格局)",
            pattern_hint=pattern,
        )

    # 2. 扶抑打分
    score = _compute_fuyi_score(pillars, day_element)

    # 3. 定强弱
    if score >= STRONG_THRESHOLD:
        strength = "strong"
    elif score <= WEAK_THRESHOLD:
        strength = "weak"
    else:
        strength = "balanced"

    # 4. 喜忌方向(balanced 按 score 倾斜:>= BALANCED_TILT_THRESHOLD 偏强,否则偏弱)
    if strength == "balanced":
        xiji_direction = "strong" if score >= BALANCED_TILT_THRESHOLD else "weak"
    else:
        xiji_direction = strength

    # 5. 喜忌五行映射
    favorable, unfavorable = _map_xiji(day_element, xiji_direction)

    # 6. 调候修正
    month_zhi = pillars.month.zhi
    favorable, unfavorable, tiaoshou_applied = _apply_tiaoshou(
        favorable, unfavorable, month_zhi,
    )

    # 7. xiji_method 标注
    xiji_method = "扶抑+调候(中和)" if strength == "balanced" else "扶抑+调候"

    return XijiResult(
        day_master_strength=strength,
        favorable_elements=favorable,
        unfavorable_elements=unfavorable,
        tiaoshou_applied=tiaoshou_applied,
        xiji_method=xiji_method,
        pattern_hint=None,
        score=score,
    )
