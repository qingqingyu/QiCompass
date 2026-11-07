"""喜忌引擎(决策 1):扶抑法 + 调候法 + 从格检测(D3)。

确定性纯函数,同输入同输出。LLM 只润色不判断。
计算顺序(关键):从格检测优先于扶抑 —— 命中从格特征则诚实降级,不硬塞扶抑。

权重/阈值全部集中在本模块常量,便于 50 盘 spike 后标定,不散落在业务流程中。
"""

from __future__ import annotations

from dataclasses import dataclass, field

from ..engine.pillars import (
    GAN_ELEMENT,
    EN2ZH, SHENG_WO, WO_SHENG, WO_KE, KE_WO,
    compute_ten_god_weights,
)
from ..models.bazi import ElementBalance, Pillars

# ---------- 调候用神 ----------

# 极寒月(子、丑)喜火暖局;极热月(午、未)喜水润局
TIAOSHOU: dict[str, str] = {
    "子": "fire", "丑": "fire",
    "午": "water", "未": "water",
}

# ---------- 扶抑打分 v2(2026-11-07 借鉴项④:证据面扩充)----------
# v1(至 2026-11-06):得令二值 +5/0、得地仅日支、得势平权——证据面窄,
# 月令十神分量差(印 vs 比劫、食伤 vs 官杀)全部丢失,通根只看日支。
# v2 扩面(权重=徐子平基线,docs/prompt对比-徐子平skill-20261107.md A1;
# 阈值=占位初值,50 盘标定候选已产出待拍板,见
# spikes/xiji_v2_calibration.py 及其生成的标定报告):
# - 月令按主气十神分档(含负档,失令程度差异化)
# - 通根查全部四柱,按藏干层次(本/中/余气)加权,真根口径(同五行,
#   不含印生——v1 得地含印,v2 收紧为传统通根口径)
# - 天干得势带位置因子(月干最重)与十神因子(比劫>印),只加不减
#   (克泄耗已在月令负档体现,不双重惩罚)
# 规则版本 XIJI_RULE_VERSION 见 config(观测通道 calc_rule_snapshot;
# content_hash 刻意不含规则版本——「hash 掺版本」已两轮驳回)。

# 月令分档:月支主气藏干对日主的十神 → 加权
MONTH_TENGOD_WEIGHTS: dict[str, float] = {
    "比肩": 3.0, "劫财": 3.0,
    "正印": 2.0, "偏印": 2.0,
    "食神": -1.75, "伤官": -1.75,
    "正财": -1.25, "偏财": -1.25,
    "七杀": -2.5, "正官": -2.5,
}

# 通根:四柱地支藏干首个与日主同五行者,按藏干层次计
ROOT_WEIGHTS: tuple[float, ...] = (1.75, 1.0, 0.5)  # 本气/中气/余气

# 天干得势:位置因子(年/月/时)× 十神因子(比劫 1.0/印 0.8)
GAN_POSITION_FACTOR: dict[str, float] = {"year": 0.8, "month": 1.2, "hour": 1.0}
GAN_PEER_FACTOR = 1.0
GAN_RESOURCE_FACTOR = 0.8

# 强弱阈值(v2 初值;50 盘标定后定稿——调整须同步
# tests/fixtures/xiji_cases.py 的 expected)
STRONG_THRESHOLD: float = 4.5     # score >= STRONG → strong
WEAK_THRESHOLD: float = 1.5       # score <= WEAK → weak
# (WEAK, STRONG) 开区间 → balanced;balanced 时按 score 倾斜:
# >= 中点偏强走 strong 喜忌,< 中点偏弱走 weak
BALANCED_TILT_THRESHOLD = (STRONG_THRESHOLD + WEAK_THRESHOLD) / 2  # 随阈值联动,勿手写数值

# 从格阈值(与打分公式无关,按五行计数,v2 不动)
ZHUANWANG_THRESHOLD = 6    # 日主同气五行 >= 6 → 专旺
CONG_THRESHOLD = 5         # 某一行 >= 5 → 从格(需日主孤立)


# ---------- 输出结构 ----------

@dataclass
class XijiResult:
    """喜忌引擎输出(对应决策 1 输出结构)。"""

    day_master_strength: str  # strong|weak|balanced|special_pattern|unknown_hour
    favorable_elements: list[str] = field(default_factory=list)
    unfavorable_elements: list[str] = field(default_factory=list)
    tiaoshou_applied: bool = False
    xiji_method: str = ""
    pattern_hint: str | None = None  # "zhuanwang"|"cong"|None
    # 内部字段(不进 API):扶抑打分(v2 float),special_pattern 时为 -1 表示未计算
    score: float = -1.0
    # v1 prompt 系统:M0 chart 注入字段
    # ten_god_weights: 全局十神权重(从 pillars.compute_ten_god_weights 透传)
    # useful_god_candidates: 喜用五行中文 list(普通盘 = favorable_elements 拷贝;
    #   special_pattern 时为空,对齐"从格诚实降级")
    ten_god_weights: dict[str, int] = field(default_factory=dict)
    useful_god_candidates: list[str] = field(default_factory=list)


# ---------- 内部辅助 ----------

def _element_of_gan(gan: str) -> str:
    """天干 → 五行(英文)。未知抛 ValueError。"""
    elem = GAN_ELEMENT.get(gan)
    if elem is None:
        raise ValueError(f"未知天干: {gan!r}")
    return elem


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

def _compute_fuyi_score(pillars: Pillars, day_element: str) -> float:
    """扶抑打分 v2 = 月令十神分档 + 全柱通根 + 天干得势(位置×十神因子)。

    - 月令分档:月支主气藏干对日主的十神(月柱 shishen_zhi[0])按
      MONTH_TENGOD_WEIGHTS 加权,含负档(失令程度差异化)
    - 通根:四柱每柱藏干首个与日主**同五行**者按层次计(真根,不含印生)
    - 得势:年/月/时干比劫或印 → GAN_POSITION_FACTOR × 十神因子,只加不减

    Raises:
        ValueError: 月支藏干十神为空 / 十神不在分档表 / 任一柱藏干为空
            (数据异常,显式暴露)
    """
    score = 0.0

    # 1. 月令分档(shishen_zhi[0] = 主气藏干的十神)
    if not pillars.month.shishen_zhi:
        raise ValueError(
            f"月支藏干十神为空:月柱 {pillars.month.gan_zhi!r} "
            f"zhi={pillars.month.zhi!r}"
        )
    month_main_god = pillars.month.shishen_zhi[0]
    month_weight = MONTH_TENGOD_WEIGHTS.get(month_main_god)
    if month_weight is None:
        raise ValueError(
            f"月令十神不在分档表:{month_main_god!r}"
            f"(月柱 {pillars.month.gan_zhi!r},数据异常)")
    score += month_weight

    # 2. 通根:四柱,每柱藏干首个同五行者按层次计(取首个即最高档)
    for pillar in (pillars.year, pillars.month, pillars.day, pillars.hour):
        if not pillar.hide_gan:
            # 地支必有藏干,空则数据异常(不吞;不依赖 compute_xiji 里
            # compute_ten_god_weights 先跑的同款守卫,本函数自守卫)
            raise ValueError(
                f"地支藏干为空:柱 {pillar.gan_zhi!r} zhi={pillar.zhi!r}")
        for idx, gan in enumerate(pillar.hide_gan):
            if _element_of_gan(gan) == day_element:
                score += (ROOT_WEIGHTS[idx] if idx < len(ROOT_WEIGHTS)
                          else ROOT_WEIGHTS[-1])
                break

    # 3. 天干得势:比劫(同五行)×1.0 / 印(生我)×0.8,乘位置因子
    for key, pillar in (("year", pillars.year), ("month", pillars.month),
                        ("hour", pillars.hour)):
        gan_element = _element_of_gan(pillar.gan)
        if gan_element == day_element:
            score += GAN_POSITION_FACTOR[key] * GAN_PEER_FACTOR
        elif gan_element == SHENG_WO[day_element]:
            score += GAN_POSITION_FACTOR[key] * GAN_RESOURCE_FACTOR

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
        pillars: 四柱(年/月/日/时柱可为 None,见 Pillars 说明;年/月柱
                 None = D10 节气边界歧义,仅在时辰未知下出现)
        element_balance: 五行统计(按已知柱计数,和 = 8/6/4/2)

    Returns:
        XijiResult,普通盘返回 strong/weak/balanced + 喜忌;
        从格特征命中返回 special_pattern + 空喜忌(诚实降级);
        任一柱缺失(时柱缺失/日柱歧义/年月柱歧义)返回 unknown_hour +
        空喜忌(D4,与从格降级同构)。

    Raises:
        ValueError: 未知干支/藏干缺失 —— 由 BaziEngine 包装为 BaziCalculationFailedError
    """
    # 0. 时辰未知分支(D4):时柱缺失(五行/十神权重缺源)或日柱歧义(日主无)
    #    → 引擎不硬算,显式降级 unknown_hour。与 special_pattern 完全同构:
    #    权重公式按 8 字校准,缺字硬算数值意义已变;喜忌是三模块根基,
    #    可靠性无法验证就不给。ten_god_weights/useful_god_candidates 一并留空
    #    (客观统计缺时柱/日柱后与 8 字口径不可比,不降级呈现)
    #    月柱歧义(D10 级联,S02):调候(查月支)与月令分档(查月支
    #    藏干十神)失去输入;年柱歧义(立春日):扶抑得势项缺年干。经引擎路径
    #    两者必伴随 hour=None,本守卫使部分柱直调同样诚实降级(不硬算)
    if (pillars.hour is None or pillars.day is None
            or pillars.year is None or pillars.month is None):
        return XijiResult(
            day_master_strength="unknown_hour",
            favorable_elements=[],
            unfavorable_elements=[],
            tiaoshou_applied=False,
            xiji_method="时辰未知,喜忌未计算(需补时辰)",
            pattern_hint=None,
            score=-1.0,
            ten_god_weights={},
            useful_god_candidates=[],
        )

    day_gan = pillars.day.gan
    day_element = _element_of_gan(day_gan)
    counts = element_balance.model_dump()

    # v1 prompt 系统:ten_god_weights 确定性统计(独立于强弱/从格判定)
    ten_god_weights = compute_ten_god_weights(pillars)

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
            # v1 字段:ten_god_weights 是客观统计(保留),useful_god_candidates
            # 留空对齐"从格诚实降级"(不下硬性喜用结论)
            ten_god_weights=ten_god_weights,
            useful_god_candidates=[],
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
        # v1 字段:useful_god_candidates 直接复用 favorable_elements(中文五行 list)
        ten_god_weights=ten_god_weights,
        useful_god_candidates=list(favorable),
    )

# ---------- 喜用口径分层明细(2026-11-07 借鉴项③,纯暴露不改规则)----------

def xiji_detail(result: XijiResult, pillars: Pillars) -> dict | None:
    """XijiResult → 喜用口径分层明细(v1 chart xiji_detail 注入数据)。

    纯暴露(2026-11-07 拍板):不改任何喜忌规则——调候表/阈值/从格检测
    一概不动,只把 compute_xiji 已算出的分层信息结构化,让 LLM 讲得出
    「为什么喜水」(此前最终列表把口径来源抹掉了):
    - favorable/unfavorable 每项带 source(扶抑/调候)+ reason(闭集短术语,
      白话化是模板层既有职责,数据层保持术语精度)
    - 调候命中的五行标 source=调候(冲突已由 compute_xiji 在列表层解决:
      从忌移除+提至喜首位;调候元素本就在喜时同样标调候——两口径皆可取,
      取更具体的那个)
    - tiaoshou_applied 时附 note 说明冲突优先级
    - 从格/时辰未知 → None(喜忌留空,模板既有诚实降级条款接管)
    - balanced 盘 direction 按倾斜口径取(与 compute_xiji 产列表同向)

    确定性:同输入同输出(闭集文案,三语注册见 term_translations XIJI_TERMS)。
    """
    if result.day_master_strength in ("special_pattern", "unknown_hour"):
        return None
    if pillars.day is None or pillars.month is None:
        # 理论不可达(上述两态已挡住缺柱场景),防御不猜
        return None
    day_element = _element_of_gan(pillars.day.gan)
    if result.day_master_strength == "balanced":
        direction = (
            "strong" if result.score >= BALANCED_TILT_THRESHOLD else "weak")
    else:
        direction = result.day_master_strength
    if direction == "weak":
        reasons: dict[str, tuple[str, str]] = {
            EN2ZH[day_element]: ("扶抑", "比劫帮身"),
            EN2ZH[SHENG_WO[day_element]]: ("扶抑", "印星生扶"),
            EN2ZH[WO_SHENG[day_element]]: ("扶抑", "食伤泄身"),
            EN2ZH[WO_KE[day_element]]: ("扶抑", "财星耗身"),
            EN2ZH[KE_WO[day_element]]: ("扶抑", "官杀克身"),
        }
    else:
        reasons = {
            EN2ZH[WO_SHENG[day_element]]: ("扶抑", "食伤泄秀"),
            EN2ZH[WO_KE[day_element]]: ("扶抑", "财星耗身"),
            EN2ZH[KE_WO[day_element]]: ("扶抑", "官杀制身"),
            EN2ZH[day_element]: ("扶抑", "身旺忌比劫助身"),
            EN2ZH[SHENG_WO[day_element]]: ("扶抑", "身旺忌印再生身"),
        }
    tiaoshou = TIAOSHOU.get(pillars.month.zhi)
    if tiaoshou is not None and result.tiaoshou_applied:
        # 严寒月(子/丑→fire 暖局) / 燥热月(午/未→water 润局)
        reasons[EN2ZH[tiaoshou]] = (
            "调候",
            "严寒月调候,暖局为先" if tiaoshou == "fire"
            else "燥热月调候,润局为先")

    def _tag(element_zh: str) -> dict:
        source, reason = reasons[element_zh]
        return {"element": element_zh, "source": source, "reason": reason}

    detail: dict = {
        "method": result.xiji_method,
        "favorable": [_tag(e) for e in result.favorable_elements],
        "unfavorable": [_tag(e) for e in result.unfavorable_elements],
    }
    if result.tiaoshou_applied:
        detail["note"] = "调候与扶抑冲突时以调候为先"
    return detail
