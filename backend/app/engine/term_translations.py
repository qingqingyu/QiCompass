"""八字术语翻译表(Joey Yap 体系为事实源)。

i18n 决策 9(`i18n-implementation-plan.md` § 2):以 Joey Yap 体系为英文八字圈事实标准。
所有术语必须显式注册,未注册的术语抛 KeyError(显式失败,不静默返回中文)。

Slice 1 范围:每日运势所需最小术语集(42 项)。
- HEAVENLY_STEMS_EN: 天干 10
- EARTHLY_BRANCHES_EN: 地支 12
- FIVE_ELEMENTS_EN: 五行 5
- TEN_GODS_EN: 十神 11(含偏官/七杀同义映射)
- STRENGTH_LABEL_EN: 旺衰 label 5(raw key:strong/weak/balanced/special_pattern/
  unknown_hour;S09 补 unknown_hour 条目——context 翻译不再覆盖该字段,
  条目供 translate_term 按需使用)
- MISC_TERMS_EN: 空(Slice 1 无独立杂项;day_chong 由 EARTHLY_BRANCHES_EN 覆盖)

T1(i18n-trilingual,2026-09-22)扩展 deep(M0-M7)/compat 所需值域:
- STRENGTH_LABEL_ZH_EN: v1 chart 内的中文旺衰标签 4(偏旺/偏弱/中和/从格特征;
  与 STRENGTH_LABEL_EN 的 raw key 是两套——chart_builder 输出中文 label)
- NAYIN_EN: 纳音 30(六十甲子纳音 condense;v1 chart 每柱 nayin 字段)
- TWELVE_STAGES_EN: 十二长生 12(v1 chart 每柱 dishi 字段)
- GENDER_EN: 性别 2(合盘 gender_a/b 发"男"/"女")
- COMPAT_TERMS_EN: 合盘定性枚举 19 + context 标签 3(取值集见
  app/models/compatibility.py QualitativeAssessment / iOS contextLabel 映射)
- MISC_TERMS_EN: 补"日主"(v1 chart 日柱 shishen_gan 值)

后续如需:神煞 20 —— 2026-09-27 已补(SHENSHA_EN,展示层 U3;译名待用户终审)。

术语来源:
- 天干/地支:拼音直用(英文八字圈通用)
- 十神:Joey Yap《The Ten Gods》体系(https://www.joeyyap.com/tutorial/tutorial-details.asp?tid=28)
- 五行:字面意译
- 旺衰:沿用 bazi_engine.py 英文 key + 翻译
"""

from __future__ import annotations

import json
import logging
import re
from typing import Final

logger = logging.getLogger(__name__)


class ChartJSONDecodeError(ValueError):
    """deep(M0-M7)context 的 chart 字段非合法 JSON(客户端提交坏数据)。

    ValueError 子类(向后兼容既有 `pytest.raises(ValueError)` 口径):
    `json.loads` 的 JSONDecodeError 在翻译层收窄包成本类,路由层
    (api/interpret.py)只对本类包装「chart 非合法 JSON」的结构化 500——
    validate_context / render_prompt 的其他 ValueError(如模板花括号
    写错)不再被误报成 chart 问题(2026-09-23 review P2-5)。
    """

# ---------- 天干(拼音直用) ----------
HEAVENLY_STEMS_EN: Final[dict[str, str]] = {
    "甲": "Jia", "乙": "Yi", "丙": "Bing", "丁": "Ding",
    "戊": "Wu", "己": "Ji", "庚": "Geng", "辛": "Xin",
    "壬": "Ren", "癸": "Gui",
}

# ---------- 地支(拼音直用) ----------
EARTHLY_BRANCHES_EN: Final[dict[str, str]] = {
    "子": "Zi", "丑": "Chou", "寅": "Yin", "卯": "Mao",
    "辰": "Chen", "巳": "Si", "午": "Wu", "未": "Wei",
    "申": "Shen", "酉": "You", "戌": "Xu", "亥": "Hai",
}

# ---------- 五行(字面意译) ----------
FIVE_ELEMENTS_EN: Final[dict[str, str]] = {
    "木": "Wood",
    "火": "Fire",
    "土": "Earth",
    "金": "Metal",
    "水": "Water",
}

# ---------- 十神(Joey Yap 体系) ----------
# 参考:
# - https://www.joeyyap.com/tutorial/tutorial-details.asp?tid=28
# - https://imperialharvest.com/blog/10-gods/
# - https://www.bazicalculator.io/learn/bazi-calculator-vs-joey-yap
# 例外:劫财 2026-09-29 用户拍板弃 Joey Yap 直译「Rob Wealth」(犯罪感过强,
# 与产品「专业不忽悠」语气不合),改温和译名「Wealth Rival」;
# iOS BaziTerms.swift 同步,由 tools/check_term_sync.py 守卫双端一致。
TEN_GODS_EN: Final[dict[str, str]] = {
    "比肩": "Companion",
    "劫财": "Wealth Rival",
    "食神": "Eating God",
    "伤官": "Hurting Officer",
    "偏财": "Indirect Wealth",
    "正财": "Direct Wealth",
    "正官": "Direct Officer",
    "七杀": "Seven Killings",
    "偏官": "Seven Killings",  # 同义,Joey Yap 统一用 Seven Killings
    "正印": "Direct Resource",
    "偏印": "Indirect Resource",
}

# ---------- 旺衰 label(对齐 bazi_engine.py _STRENGTH_LABEL 的 raw key) ----------
# 注意:iOS 客户端 PromptContextBuilder 发送到 /api/interpret 的 context 里
# day_master_strength 字段值是 **raw key**(strong / weak / balanced / special_pattern /
# unknown_hour),不是 bazi_engine._STRENGTH_LABEL 转换后的中文 label(偏旺 / 偏弱 /
# 中和 / 呈现从格特征)。中文 label 只用于 _build_anchor_sentence(UI 显示),不进
# prompt context。因此此表的 key 必须是 raw key,与客户端实际发送值对齐。
# S09 起 context 翻译不再覆盖该字段(见 _DAILY_FORTUNE_SINGLE_TERM_FIELDS 注释),
# 表条目保留供 translate_term 按需使用。
STRENGTH_LABEL_EN: Final[dict[str, str]] = {
    "strong": "Strong",
    "weak": "Weak",
    "balanced": "Balanced",
    "special_pattern": "Special Pattern",
    "unknown_hour": "Hour Unknown",
}

# ---------- 杂项核心术语 ----------
# Slice 1:daily_fortune prompt 无独立杂项术语需翻译
# (day_chong 字段存的是地支字如"午",由 EARTHLY_BRANCHES_EN 覆盖;
#  "冲"字本身不出现在 context 值中,模板里有独立 label)
# T1 补"日主":v1 chart 日柱 shishen_gan 的值(其余柱为十神,日柱对日主本身)
MISC_TERMS_EN: Final[dict[str, str]] = {
    "日主": "Day Master",
}

# ---------- v1 chart 中文旺衰标签(对齐 chart_builder._STRENGTH_LABEL_ZH) ----------
# 注意与 STRENGTH_LABEL_EN(raw key)区分:这是 chart JSON 里 strength_label
# 字段的**中文值**(chart_builder 输出端),deep(M0-M7)的 chart 翻译走这张表。
STRENGTH_LABEL_ZH_EN: Final[dict[str, str]] = {
    "偏旺": "Slightly Strong",
    "偏弱": "Slightly Weak",
    "中和": "Balanced",
    "从格特征": "Special Pattern",
    # iOS PromptContextBuilder.buildV1ChartJSON 的两个额外 strength_label 值
    # (backend chart_builder 只产上面 4 个;时辰未知盘走 deep S06 降级叙事,
    # 这两个值会进 chart strength_label → 必须注册,否则 en prompt 留中文+warn)
    "时辰未知": "Hour Unknown",   # unknown_hour(S05/S06,对齐 STRENGTH_LABEL_EN)
    "未判定": "Undetermined",    # 老 response dayMasterStrength=nil 兜底
}

# ---------- 纳音 30(六十甲子纳音,两柱一名) ----------
# 意译 + "<限定语> <五行>" 组合式;纳音在 v1 chart 属装饰性信息,
# 译名以可识别、不与正五行混淆为准。
NAYIN_EN: Final[dict[str, str]] = {
    "海中金": "Sea Metal", "炉中火": "Furnace Fire",
    "大林木": "Great Forest Wood", "路旁土": "Roadside Earth",
    "剑锋金": "Sword Metal", "山头火": "Mountain-Top Fire",
    "涧下水": "Stream Water", "城头土": "Rampart Earth",
    "白蜡金": "White Wax Metal", "杨柳木": "Willow Wood",
    "泉中水": "Spring Water", "屋上土": "Rooftop Earth",
    "霹雳火": "Thunderbolt Fire", "松柏木": "Pine-Cypress Wood",
    "长流水": "Long-Running Water", "沙中金": "Sand Metal",
    "山下火": "Foothill Fire", "平地木": "Plains Wood",
    "壁上土": "Wall Earth", "金箔金": "Gold-Leaf Metal",
    "覆灯火": "Lantern Fire", "天河水": "Heavenly River Water",
    "大驿土": "Post-Road Earth", "钗钏金": "Hairpin Metal",
    "桑柘木": "Mulberry Wood", "大溪水": "Great Stream Water",
    "沙中土": "Sand Earth", "天上火": "Sky Fire",
    "石榴木": "Pomegranate Wood", "大海水": "Great Sea Water",
}

# ---------- 十二长生(v1 chart 每柱 dishi 字段) ----------
TWELVE_STAGES_EN: Final[dict[str, str]] = {
    "长生": "Growth", "沐浴": "Bathing", "冠带": "Crowning",
    "临官": "Officer", "帝旺": "Emperor", "衰": "Decline",
    "病": "Sickness", "死": "Death", "墓": "Grave",
    "绝": "Extinction", "胎": "Womb", "养": "Nurture",
}

# ---------- 性别(合盘 gender_a/b 的中文值) ----------
GENDER_EN: Final[dict[str, str]] = {
    "男": "Male",
    "女": "Female",
}

# ---------- 合盘定性枚举 + context 标签 ----------
# 取值集事实源:app/models/compatibility.py QualitativeAssessment 的 Literal
# + iOS PromptContextBuilder+Compatibility.contextLabel 的映射("通用"/"婚姻"/"事业")。
# 枚举两端(后端产出 / iOS 产出)任一侧加值需同步此表,否则 en 渲染 KeyError → 500。
COMPAT_TERMS_EN: Final[dict[str, str]] = {
    # five_elements_assessment
    "互补佳": "Strongly complementary",
    "有一定互补": "Somewhat complementary",
    "互补较弱": "Weakly complementary",
    "信息不足": "Insufficient data",
    # day_master_relation
    "同气": "Same element",
    "相生": "Generating cycle",
    "相克": "Controlling cycle",
    # zodiac_match
    "六合": "Six Harmony",
    "三合": "Three Harmony",
    "六冲": "Six Clash",
    "三刑": "Three Punishment",
    "相害": "Harm",
    "无特殊合冲": "No notable harmony or clash",
    # branch_harmony
    "无冲无刑": "No clash, no punishment",
    "一冲一合": "One clash, one harmony",
    "多冲少合": "More clashes than harmonies",
    "多合少冲": "More harmonies than clashes",
    "多刑多害": "Multiple punishments and harms",
    "略有冲刑害": "Slight clash / punishment / harm",
    # context_label(小写:en 模板内联 "along the {context_label} dimension")
    "通用": "general",
    "婚姻": "marriage",
    "事业": "career",
}

# ---------- 神煞 20(11 吉 + 9 凶,《三命通会》单一来源) ----------
# 清单事实源:app/engine/shensha.py SHENSHA_NAMES(固定顺序,本表键序与其一致)。
# 意译为主;译名提案来自 i18n-display-layer-handoff.md §5,**待用户术语 QA 终审
# (U6 HITL),不得静默改词**。iOS 展示层同款三语表在 BaziTerms.swift,
# 键集合由 tools/check_term_sync.py 强制同步。
# 当前后端消费者:v1 chart 不含神煞(deep context 不走此表);注册进总表供
# translate_term 按需使用 + 同步工具比对(prompt context 未来携带神煞时即通)。
SHENSHA_EN: Final[dict[str, str]] = {
    # 吉神 11
    "天乙贵人": "Nobleman",
    "太极贵人": "Supreme Nobleman",
    "文昌": "Academic Star",
    "天德": "Heavenly Virtue",
    "月德": "Monthly Virtue",
    "驿马": "Travelling Horse",
    "桃花": "Peach Blossom",
    "将星": "General Star",
    "华盖": "Canopy Star",
    "金舆": "Golden Carriage",
    "禄神": "Prosperity Star",
    # 凶煞 9
    "羊刃": "Goat Blade",
    "劫煞": "Robbery Star",
    "亡神": "Loss Spirit",
    "孤辰": "Solitary Star",
    "寡宿": "Widowhood Star",
    "元辰": "Grievance Star",
    "灾煞": "Calamity Star",
    "天罗地网": "Heaven Net, Earth Snare",
    "红艳": "Red Beauty",
}

# ---------- zh-Hant 表(i18n-zh-hant-plan.md D1,2026-10-01) ----------
# 显式注册表,不引 OpenCC(一对多映射风险 + 新依赖须批准;"显式注册、显式失败"
# 与 en 表同构)。值与 iOS BaziTerms.swift 的 zhHant 列逐字对齐(09-27 已人工
# 校对的定稿),由 tools/check_term_sync.py ①③ 组强制同步——改词须双端同改。
# 干支 / 五行 / 生肖全同形(identity 也显式进表,未注册值在严格字段会 KeyError)。
# STRENGTH_LABEL_EN 的 raw key(strong/weak/...)不进 zh-hant 表:Latin 控制键
# 不属于 CJK 术语域,context 翻译也不碰它(S09 口径)。

# ---------- 天干(zh-hant identity) ----------
HEAVENLY_STEMS_ZH_HANT: Final[dict[str, str]] = {
    "甲": "甲", "乙": "乙", "丙": "丙", "丁": "丁",
    "戊": "戊", "己": "己", "庚": "庚", "辛": "辛",
    "壬": "壬", "癸": "癸",
}

# ---------- 地支(zh-hant identity) ----------
EARTHLY_BRANCHES_ZH_HANT: Final[dict[str, str]] = {
    "子": "子", "丑": "丑", "寅": "寅", "卯": "卯",
    "辰": "辰", "巳": "巳", "午": "午", "未": "未",
    "申": "申", "酉": "酉", "戌": "戌", "亥": "亥",
}

# ---------- 五行(zh-hant identity) ----------
FIVE_ELEMENTS_ZH_HANT: Final[dict[str, str]] = {
    "木": "木", "火": "火", "土": "土", "金": "金", "水": "水",
}

# ---------- 十神(zh-hant;异形:伤官/七杀/偏财/正财/劫财) ----------
TEN_GODS_ZH_HANT: Final[dict[str, str]] = {
    "比肩": "比肩",
    "劫财": "劫財",
    "食神": "食神",
    "伤官": "傷官",
    "偏财": "偏財",
    "正财": "正財",
    "正官": "正官",
    "七杀": "七殺",
    "偏官": "偏官",
    "正印": "正印",
    "偏印": "偏印",
}

# ---------- 日主(zh-hant identity) ----------
MISC_TERMS_ZH_HANT: Final[dict[str, str]] = {
    "日主": "日主",
}

# ---------- v1 chart 中文旺衰标签(zh-hant;从格特征/时辰未知异形) ----------
STRENGTH_LABEL_ZH_ZH_HANT: Final[dict[str, str]] = {
    "偏旺": "偏旺",
    "偏弱": "偏弱",
    "中和": "中和",
    "从格特征": "從格特徵",
    "时辰未知": "時辰未知",
    "未判定": "未判定",
}

# ---------- 纳音 30(zh-hant) ----------
NAYIN_ZH_HANT: Final[dict[str, str]] = {
    "海中金": "海中金", "炉中火": "爐中火",
    "大林木": "大林木", "路旁土": "路旁土",
    "剑锋金": "劍鋒金", "山头火": "山頭火",
    "涧下水": "澗下水", "城头土": "城頭土",
    "白蜡金": "白蠟金", "杨柳木": "楊柳木",
    "泉中水": "泉中水", "屋上土": "屋上土",
    "霹雳火": "霹靂火", "松柏木": "松柏木",
    "长流水": "長流水", "沙中金": "沙中金",
    "山下火": "山下火", "平地木": "平地木",
    "壁上土": "壁上土", "金箔金": "金箔金",
    "覆灯火": "覆燈火", "天河水": "天河水",
    "大驿土": "大驛土", "钗钏金": "釵釧金",
    "桑柘木": "桑柘木", "大溪水": "大溪水",
    "沙中土": "沙中土", "天上火": "天上火",
    "石榴木": "石榴木", "大海水": "大海水",
}

# ---------- 十二长生(zh-hant;长生→長生 注意非 identity) ----------
TWELVE_STAGES_ZH_HANT: Final[dict[str, str]] = {
    "长生": "長生", "沐浴": "沐浴", "冠带": "冠帶",
    "临官": "臨官", "帝旺": "帝旺", "衰": "衰",
    "病": "病", "死": "死", "墓": "墓",
    "绝": "絕", "胎": "胎", "养": "養",
}

# ---------- 性别(zh-hant identity) ----------
GENDER_ZH_HANT: Final[dict[str, str]] = {
    "男": "男",
    "女": "女",
}

# ---------- 合盘定性枚举 + context 标签(zh-hant) ----------
# 「信息不足」维持与 iOS BaziTerms zhHant 同形(两岸均通,不强改「資訊不足」,
# 双端一致优先——check_term_sync ① 组锁定)。
COMPAT_TERMS_ZH_HANT: Final[dict[str, str]] = {
    # five_elements_assessment
    "互补佳": "互補佳",
    "有一定互补": "有一定互補",
    "互补较弱": "互補較弱",
    "信息不足": "信息不足",
    # day_master_relation
    "同气": "同氣",
    "相生": "相生",
    "相克": "相剋",
    # zodiac_match
    "六合": "六合",
    "三合": "三合",
    "六冲": "六沖",
    "三刑": "三刑",
    "相害": "相害",
    "无特殊合冲": "無特殊合沖",
    # branch_harmony
    "无冲无刑": "無沖無刑",
    "一冲一合": "一沖一合",
    "多冲少合": "多沖少合",
    "多合少冲": "多合少沖",
    "多刑多害": "多刑多害",
    "略有冲刑害": "略有沖刑害",
    # context_label
    "通用": "通用",
    "婚姻": "婚姻",
    "事业": "事業",
}

# ---------- 神煞 20(zh-hant) ----------
SHENSHA_ZH_HANT: Final[dict[str, str]] = {
    # 吉神 11
    "天乙贵人": "天乙貴人",
    "太极贵人": "太極貴人",
    "文昌": "文昌",
    "天德": "天德",
    "月德": "月德",
    "驿马": "驛馬",
    "桃花": "桃花",
    "将星": "將星",
    "华盖": "華蓋",
    "金舆": "金輿",
    "禄神": "祿神",
    # 凶煞 9
    "羊刃": "羊刃",
    "劫煞": "劫煞",
    "亡神": "亡神",
    "孤辰": "孤辰",
    "寡宿": "寡宿",
    "元辰": "元辰",
    "灾煞": "災煞",
    "天罗地网": "天羅地網",
    "红艳": "紅艷",
}

# ---------- 翻译注册表(语言 → {中文术语 → 目标语言术语}) ----------
# 加新语言时只需在此 dict 加一个 key,无需改 translate_term() 函数。
TERM_TRANSLATIONS: Final[dict[str, dict[str, str]]] = {
    # zh: identity map 不需要(translate_term 直接返回原文)
    "en": {
        **HEAVENLY_STEMS_EN,
        **EARTHLY_BRANCHES_EN,
        **FIVE_ELEMENTS_EN,
        **TEN_GODS_EN,
        **STRENGTH_LABEL_EN,
        **MISC_TERMS_EN,
        **STRENGTH_LABEL_ZH_EN,
        **NAYIN_EN,
        **TWELVE_STAGES_EN,
        **GENDER_EN,
        **COMPAT_TERMS_EN,
        **SHENSHA_EN,
    },
    "zh-hant": {
        **HEAVENLY_STEMS_ZH_HANT,
        **EARTHLY_BRANCHES_ZH_HANT,
        **FIVE_ELEMENTS_ZH_HANT,
        **TEN_GODS_ZH_HANT,
        **MISC_TERMS_ZH_HANT,
        **STRENGTH_LABEL_ZH_ZH_HANT,
        **NAYIN_ZH_HANT,
        **TWELVE_STAGES_ZH_HANT,
        **GENDER_ZH_HANT,
        **COMPAT_TERMS_ZH_HANT,
        **SHENSHA_ZH_HANT,
    },
}

# ---------- 术语拼接分隔符(按目标语言) ----------
# en 译值是拼音/意译词,多字词间需空格("Geng Wu");zh-hant 译值仍是 CJK,
# 连写无空格("庚午" 不得变 "庚 午")。加新语言在此登记;未登记语言沿用
# 空格分隔(en 先例)。
_TERM_JOINERS: Final[dict[str, str]] = {"zh-hant": ""}


def _term_joiner(language: str) -> str:
    """该语言的术语拼接分隔符(见 _TERM_JOINERS 注释)。"""
    return _TERM_JOINERS.get(language, " ")


# ---------- 翻译端点术语对构建(D10.2,2026-10-01) ----------

# 反查方向(source ≠ zh)的已知同义冲突显式裁决:
# - 值 = zh 术语 → 裁决保留该 canonical(同义词:七杀/偏官在 Joey Yap 体系
#   统一 Seven Killings,裁决「七杀」= engine 侧 ten_god_weights 主用形)
# - 值 = None → 整组剔除(同形异义,不可机械裁决:"Wu" 同时是 戊(天干)与
#   午(地支)的无调拼音——译回方向不进术语表,由 LLM 按上下文判断;
#   干支在正文多以干支对出现,上下文足够)
# 出现新冲突而不补裁决 → build_translation_term_pairs 显式 KeyError
# (不静默取任一,对齐"显式注册、显式失败"哲学)。
_REVERSE_CANONICAL_OVERRIDES: Final[dict[str, str | None]] = {
    "Seven Killings": "七杀",
    "Wu": None,
}


def build_translation_term_pairs(
    source_language: str, target_language: str,
) -> list[tuple[str, str]]:
    """翻译 prompt 注入用的 源语言→目标语言 术语对(D10.2)。

    术语域 = zh-hant 表键集(131,纯 CJK 术语;en 表减 raw strength key 同集),
    按 zh id 空间取两侧显示值,只保留两侧不同形的对(identity 对是噪音):
    - zh → en / zh → zh-hant:正向,天然无歧义(多对一允许:七杀/偏官 →
      Seven Killings 两条都给,LLM 照表译不冲突)
    - en → zh / en → zh-hant:反查,同一源值对应多个 zh id 时按
      _REVERSE_CANONICAL_OVERRIDES 裁决收敛(丢弃非 canonical 同义项);
      未裁决的冲突显式 KeyError

    Args:
        source_language: 原文语言("zh" / "zh-hant" / "en")
        target_language: 目标语言(同上)

    Returns:
        [(源术语, 目标术语), ...](源 ≠ 目标)

    Raises:
        KeyError: 语言未注册,或反查冲突未裁决
        ValueError: 源与目标语言相同(调用方应先拦)
    """
    if source_language == target_language:
        raise ValueError(
            f"源与目标语言相同({source_language!r}),无术语对可建"
            f"(翻译端点在路由层已拦同语言请求)")
    src_table = None if source_language == "zh" else TERM_TRANSLATIONS.get(
        source_language)
    tgt_table = None if target_language == "zh" else TERM_TRANSLATIONS.get(
        target_language)
    if (source_language != "zh" and src_table is None) or (
            target_language != "zh" and tgt_table is None):
        raise KeyError(
            f"未注册的语言: source={source_language!r} target={target_language!r}"
            f"(已注册: {sorted(TERM_TRANSLATIONS.keys())})")
    zh_ids = list(TERM_TRANSLATIONS["zh-hant"].keys())

    dropped: set[str] = set()
    if source_language != "zh":
        by_src: dict[str, list[str]] = {}
        for zh_id in zh_ids:
            by_src.setdefault(src_table[zh_id], []).append(zh_id)
        for src_val, ids in by_src.items():
            if len(ids) > 1:
                canonical = _REVERSE_CANONICAL_OVERRIDES.get(src_val)
                if canonical is None and src_val in _REVERSE_CANONICAL_OVERRIDES:
                    # 显式裁决 = 整组剔除(同形异义,见常量注释)
                    dropped.update(ids)
                    continue
                if canonical not in ids:
                    raise KeyError(
                        f"术语反查冲突未裁决: {src_val!r} 同时对应 {ids}"
                        f"(需在 _REVERSE_CANONICAL_OVERRIDES 显式裁决——"
                        f"canonical zh 术语或 None 剔除整组,不静默取任一)")
                dropped.update(i for i in ids if i != canonical)

    pairs: list[tuple[str, str]] = []
    for zh_id in zh_ids:
        if zh_id in dropped:
            continue
        src_val = zh_id if source_language == "zh" else src_table[zh_id]
        tgt_val = zh_id if target_language == "zh" else tgt_table[zh_id]
        if src_val != tgt_val:
            pairs.append((src_val, tgt_val))
    return pairs


def translate_term(zh_term: str, target_language: str) -> str:
    """术语翻译:中文源 → 目标语言。

    严格显式失败策略(对齐 CLAUDE.md "错误显式传播"):
    - 中文目标语言 → 直接返回原文(identity)
    - 未注册的目标语言 → 抛 KeyError(避免误用未实现的语言)
    - 未注册的中文术语 → 抛 KeyError(避免静默返回中文,污染 LLM prompt)

    Args:
        zh_term: 中文术语或 raw key(如 "甲"/"比肩"/"strong")
        target_language: 目标语言代码("zh" / "zh-hant" / "en",未来扩展 "ja" / "es")

    Returns:
        目标语言的术语字符串

    Raises:
        KeyError: 语言未注册 或 术语未注册,message 含可操作信息
    """
    if target_language == "zh":
        return zh_term
    table = TERM_TRANSLATIONS.get(target_language)
    if table is None:
        raise KeyError(
            f"未注册的目标语言: {target_language!r}"
            f"(已注册: {sorted(TERM_TRANSLATIONS.keys())})")
    if zh_term not in table:
        raise KeyError(
            f"术语 {zh_term!r} 未注册 {target_language} 翻译"
            f"(需在 term_translations.py 补齐,当前 en 表共 {len(table)} 项)")
    return table[zh_term]


def is_language_supported(language: str) -> bool:
    """检查语言是否已注册(Slice 1.2 language.py 解析层用)。

    Args:
        language: 规范化后的语言代码(如 "zh" / "en")

    Returns:
        True 若该语言已在 TERM_TRANSLATIONS 注册
    """
    return language == "zh" or language in TERM_TRANSLATIONS


# ---------- context 数据翻译层(i18n 决策 1:方案 3b 后端翻译责任) ----------
# 让 LLM 拿到全英文 prompt(避免英文 prompt 里夹杂中文术语,导致输出质量降级)

# 翻译失败 sentinel:用于区分"翻译后恰好等于原文"和"翻译失败保留原文"
# 定义在函数前,确保调用方引用时已存在(可读性优先于 Python 运行时延迟解析)
_TRANSLATION_FAILED = object()

# daily_fortune context 里的"单术语"字段(直接 translate_term)
# 注意:day_master_strength **不在**此表——它是 raw key(strong/weak/.../
# unknown_hour),同时是 render_prompt 的模板/降级分支控制信号(unknown_hour
# 切降级变体、special_pattern 追加从格段)。route 先 translate_context 再
# render,翻译它会破坏分支判定(S09 实测 en 降级链路 422);raw key 原样
# 进 prompt 与 zh 行为一致(命主：日主 己（土），weak)。STRENGTH_LABEL_EN
# 仍并入总表供 translate_term 按需取用。
_DAILY_FORTUNE_SINGLE_TERM_FIELDS: Final[tuple[str, ...]] = (
    "day_master",         # 日主(单天干)
    "day_stem",           # 流日天干
    "day_branch",         # 流日地支
    "day_chong",          # 流日冲(单地支)
    "day_master_element",   # 五行
    "day_stem_element",    # 五行
    "day_branch_element",   # 五行
    "day_relation",       # 十神
)

# daily_fortune context 里"复合术语"字段(逐字符翻译,"甲子" → "Jia Zi")
_DAILY_FORTUNE_COMPOSITE_FIELDS: Final[tuple[str, ...]] = (
    "day_pillar",         # 流日柱(2 字符干支)
)

# daily_fortune context 里"喜忌列表"字段(多五行拼接,"木火" → "Wood Fire")
_DAILY_FORTUNE_ELEMENT_LIST_FIELDS: Final[tuple[str, ...]] = (
    "favorable_elements",
    "unfavorable_elements",
)

# daily_fortune context 里"不翻译"字段(保留中文)
# - date / lunar_date: 日期格式,不翻译
# - hour_pillars_with_relations: 复杂拼接(Slice 1 暂留中文,LLM 可理解)
# - huangli_yi / huangli_ji: 黄历项目,Slice 1 阶段不翻译(工作量大,且英文用户可能不关心)


def translate_context(context: dict, language: str, module: str) -> dict:
    """翻译 prompt context 里的术语到目标语言(i18n 决策 1:方案 3b)。

    context 数据来自 lunar_python 输出(永远是中文),此函数按 module 字段规则
    翻译到目标语言,让 LLM 拿到全目标语言的 prompt。

    策略:
    - language == "zh" → 直接返回原 context(identity)
    - module 已实现翻译规则 → 按 rule 翻译
    - module 未实现 → log warning,返回原 context(Slice 2/3/4 逐步覆盖)

    Args:
        context: prompt 渲染负载(来自客户端)
        language: 目标语言代码("zh" / "zh-hant" / "en")
        module: module 名(决定翻译规则)

    Returns:
        翻译后的 context(新 dict,不修改原)
    """
    if language == "zh":
        return context
    if module == "daily_fortune":
        return _translate_daily_fortune_context(context, language)
    if module in _V1_DEEP_MODULES:
        return _translate_deep_context(context, language)
    if module in _COMPAT_FREE_PAID_MODULES:
        return _translate_compat_context(context, language)
    # alias(bazi_deep×3 / compatibility)默认不补 en 模板(handoff T1 拍板),
    # 翻译规则同样不实现——en 请求在 render_prompt 模板加载处显式 FileNotFoundError
    # → 500(既有行为);zh 请求不走本函数。老 App 兼容面维持现状。
    logger.warning(
        "translate_context: module=%s 暂未实现 %s 翻译规则,context 保留中文 "
        "(下游 render_prompt 将因模板缺失抛 FileNotFoundError → 500;"
        "alias module 默认不补 en 模板,见 i18n-trilingual handoff T1)",
        module, language,
    )
    return context


def _translate_daily_fortune_context(context: dict, language: str) -> dict:
    """daily_fortune context 字段级翻译。

    单术语字段严格策略(对齐 translate_term + CLAUDE.md "错误显式传播"):
    - 字段值非字符串 → 保留原值(防御,不抛错)
    - 字段值是字符串但未注册 → **抛 KeyError**(不静默保留中文,
      避免英文 prompt 混入中文术语导致 LLM 输出降级且无日志可查)
    复合术语 / 五行列表字段遇未知字符 → 保留原文 + log warning
    (这些字段结构复杂,部分字符不在表里时保守保留比误翻更安全)
    """
    table = TERM_TRANSLATIONS.get(language)
    if table is None:
        # 已注册语言但缺翻译表(不应发生,语言支持在 is_language_supported 拦)
        raise KeyError(f"语言 {language!r} 翻译表缺失")
    joiner = _term_joiner(language)
    translated = dict(context)  # shallow copy,不修改原 context

    # 单术语字段(严格:未注册抛 KeyError)
    for field in _DAILY_FORTUNE_SINGLE_TERM_FIELDS:
        if field in translated:
            v = translated[field]
            if not isinstance(v, str):
                continue  # 非字符串字段保留原值(防御)
            if v not in table:
                raise KeyError(
                    f"术语 {v!r}(字段 {field!r})未注册 {language} 翻译"
                    f"(需在 term_translations.py 补齐,"
                    f"当前 {language} 表共 {len(table)} 项)")
            translated[field] = table[v]

    # 复合术语字段(逐字符翻译 + 按语言连接:en 空格 / zh-hant 连写)
    for field in _DAILY_FORTUNE_COMPOSITE_FIELDS:
        if field in translated:
            v = translated[field]
            if isinstance(v, str):
                result = _translate_pillar(v, table, joiner)
                if result is _TRANSLATION_FAILED:
                    logger.warning(
                        "translate_context: 字段 %s 值 %r 无法翻译"
                        "(字符不在表里或格式非标准),保留原文",
                        field, v,
                    )
                else:
                    translated[field] = result

    # 喜忌列表字段(多五行拼接)
    for field in _DAILY_FORTUNE_ELEMENT_LIST_FIELDS:
        if field in translated:
            v = translated[field]
            if isinstance(v, str):
                result = _translate_element_list(v, table, joiner)
                if result is _TRANSLATION_FAILED:
                    logger.warning(
                        "translate_context: 字段 %s 值 %r 含未知字符,"
                        "保留原文",
                        field, v,
                    )
                else:
                    translated[field] = result

    return translated


# deep(M0-M7)context 里唯一翻译的字段:chart(engine 中文术语 JSON)。
# 其余字段两类,均**不动**:
# - 链式注入字段(structure_fingerprint / main_axis / core_loop / innate /
#   defensive / threshold / ideal_life_structure / one_leverage /
#   switch_actions / environment_checklist / leverage):上一模块 LLM 输出,
#   en 链路本身即英文(zh 产出注入 en 请求属用户中途切语言的边缘情形,LLM 可理解)
# - 用户输入字段(age / current_concern / assets_summary / preference):自由文本,
#   不属于术语表职责(决策 1 翻译责任层只覆盖 engine 确定性术语)
_V1_DEEP_MODULES: Final[frozenset[str]] = frozenset({
    "m0_structure", "m1_talent", "m2_high_low", "m3_system", "m4_health",
    "m5_wealth", "m6_dynamics", "m7_manual",
})


def _translate_deep_context(context: dict, language: str) -> dict:
    """deep(M0-M7)context 翻译:仅译 chart 字段(engine 中文术语 JSON)。

    chart JSON 翻译策略(对齐 daily 复合字段的容忍先例,整词命中即译):
    - 递归遍历 dict/list;`meta` 子树整体跳过(日期 / locale / 规则键 /
      节气界,非术语域)
    - 字符串值优先级:整词表命中(十神/五行/纳音/十二长生/旺衰label/日主)→ 译;
      两字符均在表(干支"庚午")→ "Geng Wu";逐字符均在表(地支对"戌亥")→
      空格连接;不含 CJK(已拉丁)→ 原样;其余 → 保留原文并收集,
      结束统一 log warning(非静默:值域缺口可据此扩表)
    """
    table = TERM_TRANSLATIONS.get(language)
    if table is None:
        raise KeyError(f"语言 {language!r} 翻译表缺失")
    translated = dict(context)
    chart = translated.get("chart")
    if isinstance(chart, str):
        translated["chart"] = _translate_chart_json(
            chart, table, _term_joiner(language))
    return translated


_CJK_PATTERN = re.compile(r"[\u4e00-\u9fff]")


def _translate_chart_json(chart_json: str, table: dict[str, str],
                          joiner: str = " ") -> str:
    """v1 chart JSON 字符串的值级翻译(键不动,值按词表)。"""
    try:
        data = json.loads(chart_json)
    except json.JSONDecodeError as e:
        # 收窄进翻译层:包成专用类型,路由层按本类包装 500(见类注释)
        raise ChartJSONDecodeError(str(e)) from e
    untranslatable: list[str] = []
    walked = _walk_chart_value(data, table, untranslatable, joiner)
    if untranslatable:
        logger.warning(
            "translate_context: chart 内 %d 个值未注册翻译,保留中文:%r"
            "(按需在 term_translations.py 扩表)",
            len(untranslatable), sorted(set(untranslatable))[:10],
        )
    return json.dumps(walked, ensure_ascii=False)


def _walk_chart_value(node: object, table: dict[str, str],
                      untranslatable: list[str], joiner: str = " ") -> object:
    if isinstance(node, dict):
        out: dict = {}
        for key, value in node.items():
            if key == "meta":
                out[key] = value  # 非术语域(日期/locale/规则键/节气界),整体保留
                continue
            # 键也走术语翻译(ten_god_weights / five_elements 的键是十神/五行;
            # 结构键 gan_zhi/shishen_gan 等为拉丁,静默原样)
            new_key = _translate_chart_scalar(key, table, untranslatable, joiner) \
                if isinstance(key, str) else key
            out[new_key] = _walk_chart_value(value, table, untranslatable, joiner)
        return out
    if isinstance(node, list):
        return [_walk_chart_value(item, table, untranslatable, joiner)
                for item in node]
    if isinstance(node, str):
        return _translate_chart_scalar(node, table, untranslatable, joiner)
    return node  # 数字 / None / bool 原样


def _translate_chart_scalar(value: str, table: dict[str, str],
                            untranslatable: list[str], joiner: str = " ") -> str:
    if not _CJK_PATTERN.search(value):
        return value  # 已是拉丁(如 "metal"/"female"/日期),静默原样
    if value in table:
        return table[value]
    if len(value) == 2 and value[0] in table and value[1] in table:
        # 干支 "庚午" → en "Geng Wu" / zh-hant "庚午"(连写)
        return joiner.join((table[value[0]], table[value[1]]))
    if all(ch in table for ch in value):
        # 地支对 "戌亥" → en "Xu Hai" / zh-hant "戌亥"(连写)
        return joiner.join(table[ch] for ch in value)
    untranslatable.append(value)
    return value


# 合盘(compatibility_free / compatibility_paid)context 翻译的字段分组。
# 取值域事实源:_COMPATIBILITY_REQUIRED_FIELDS + 模板占位符。
_COMPAT_FREE_PAID_MODULES: Final[frozenset[str]] = frozenset({
    "compatibility_free", "compatibility_paid",
})

# 单术语字段(严格:未注册抛 KeyError,对齐 daily 策略)
_COMPAT_SINGLE_TERM_FIELDS: Final[tuple[str, ...]] = (
    "day_master_a", "day_master_b",          # 单天干
    "five_elements_assessment",               # 合盘枚举(COMPAT_TERMS_EN)
    "day_master_relation",
    "zodiac_match",
    "branch_harmony",
)

# 干支柱字段(复合容忍:非 2 字干支如时辰未知占位 → warn + 保留)
_COMPAT_PILLAR_FIELDS: Final[tuple[str, ...]] = (
    "year_a", "month_a", "day_a", "hour_a",
    "year_b", "month_b", "day_b", "hour_b",
)

# 喜忌列表("木火" → "Wood Fire";容忍同 daily)
_COMPAT_ELEMENT_LIST_FIELDS: Final[tuple[str, ...]] = (
    "favorable_a", "favorable_b",
)

# 五行分布(形如"木3火2土1金1水1":译元素字保数字)
_COMPAT_ELEMENT_BALANCE_FIELDS: Final[tuple[str, ...]] = (
    "element_balance_a", "element_balance_b",
)

# 宽容单值(表内则译,表外保留原样:值域含非术语,不值得为它 500)
_COMPAT_TOLERANT_FIELDS: Final[tuple[str, ...]] = (
    "gender_a", "gender_b",   # "男"/"女" 已注册;其他值保留
    "context_label",          # "通用"/"婚姻"/"事业" 已注册;未知 context 保留
)

# 不翻译字段(口径与 daily 对齐,留痕防误扩):
# - city_a/b, birth_a/b: 用户/locale 数据(非术语)
# - day_master_strength_a/b: raw key(strong/weak/...),与 daily 的
#   day_master_strength 同口径——模板分支控制信号,原样进 prompt
# - synced_fortune_table: iOS 拼装的中文表格(干支+运+年+同步枚举),
#   复杂拼接,Slice 1 黄历/hour_pillars 同先例:保留中文 + log warning


def _translate_compat_context(context: dict, language: str) -> dict:
    """合盘 context 字段级翻译(对齐 daily 的分组策略)。"""
    table = TERM_TRANSLATIONS.get(language)
    if table is None:
        raise KeyError(f"语言 {language!r} 翻译表缺失")
    joiner = _term_joiner(language)
    translated = dict(context)

    for field in _COMPAT_SINGLE_TERM_FIELDS:
        if field in translated:
            value = translated[field]
            if not isinstance(value, str):
                continue  # 非字符串字段保留原值(防御)
            if value not in table:
                raise KeyError(
                    f"术语 {value!r}(字段 {field!r})未注册 {language} 翻译"
                    f"(需在 term_translations.py 补齐,"
                    f"当前 {language} 表共 {len(table)} 项)")
            translated[field] = table[value]

    for field in _COMPAT_PILLAR_FIELDS:
        if field in translated and isinstance(translated[field], str):
            result = _translate_pillar(translated[field], table, joiner)
            if result is _TRANSLATION_FAILED:
                logger.warning(
                    "translate_context: 字段 %s 值 %r 无法翻译"
                    "(非标准干支,如时辰未知占位),保留原文",
                    field, translated[field],
                )
            else:
                translated[field] = result

    for field in _COMPAT_ELEMENT_LIST_FIELDS:
        if field in translated and isinstance(translated[field], str):
            result = _translate_element_list(translated[field], table, joiner)
            if result is _TRANSLATION_FAILED:
                # 全 CJK 喜忌才译;失败保留(S09 后可能为空串/非五行内容)。
                # 对齐 pillar 路径留痕:中文漏进 en prompt 可据此定位
                # (2026-09-23 review P2-6,此前静默保留无观测)。
                logger.warning(
                    "translate_context: 字段 %s 值 %r 无法翻译"
                    "(非全 CJK 五行列表,S09 后可为空串/非五行内容),保留原文",
                    field, translated[field],
                )
            else:
                translated[field] = result

    for field in _COMPAT_ELEMENT_BALANCE_FIELDS:
        if field in translated and isinstance(translated[field], str):
            translated[field] = _translate_element_balance(
                translated[field], table)

    for field in _COMPAT_TOLERANT_FIELDS:
        if field in translated and isinstance(translated[field], str):
            translated[field] = table.get(translated[field], translated[field])

    if "synced_fortune_table" in translated:
        logger.warning(
            "translate_context: synced_fortune_table 为 iOS 拼装的中文表格,"
            "保留中文(Slice 1 黄历同先例,LLM 可理解;en 章节四据此叙事)"
        )
    return translated


def _translate_element_balance(value: str, table: dict[str, str]) -> str:
    """五行分布串翻译:"木3火2土1金1水1" → "Wood 3 Fire 2 Earth 1 Metal 1 Water 1"。

    逐 CJK 字查表(未注册保留),数字/分隔符原样,译出的词与相邻数字间补空格。
    """
    out = _CJK_PATTERN.sub(
        lambda m: table.get(m.group(), m.group()), value)
    out = re.sub(r"([A-Za-z])(\d)", r"\1 \2", out)  # "Wood3" → "Wood 3"
    return re.sub(r"(\d)([A-Za-z])", r"\1 \2", out)  # "3Fire" → "3 Fire"


def _translate_pillar(pillar: str, table: dict[str, str],
                      joiner: str = " ") -> str | object:
    """翻译干支字符串("甲子" → en "Jia Zi" / zh-hant "甲子" 连写)。

    长度 2(天干+地支)时翻译,其他长度保留原文(避免误伤)。

    Returns:
        翻译后的字符串,或 _TRANSLATION_FAILED sentinel(无法翻译时)
    """
    if len(pillar) != 2:
        return _TRANSLATION_FAILED  # 非标准干支格式
    gan, zhi = pillar[0], pillar[1]
    if gan in table and zhi in table:
        return joiner.join((table[gan], table[zhi]))
    return _TRANSLATION_FAILED  # 部分字符不在表里


def _translate_element_list(elements: str, table: dict[str, str],
                            joiner: str = " ") -> str | object:
    """翻译五行列表("木火" → en "Wood Fire" / zh-hant "木火" 连写)。

    逐 token 尝试逐字符翻译,所有字符都在表里才翻译,否则返回
    _TRANSLATION_FAILED。
    容忍 ", " / "、" 分隔的多 token:真实 wire 格式 iOS 客户端喜忌用
    ", " join(`favorableElements.joined(separator: ", ")`,PromptContextBuilder
    .swift:79 / +Compatibility.swift:99),旧实现只认纯 CJK 连写串,对
    "木, 火" 整体判失败 → en prompt 静默留中文(T1 review 修复)。
    分隔符输出归一为 ", ";token 内字符连接用 joiner(en 空格 /
    zh-hant 连写)。
    """
    translated_tokens: list[str] = []
    for token in re.split(r"\s*[,、]\s*", elements):
        if not token:
            continue  # 首尾分隔符产生的空 token
        translated_chars: list[str] = []
        for ch in token:
            if ch in table:
                translated_chars.append(table[ch])
            else:
                # 任意字符不在表里,放弃翻译整个字符串
                return _TRANSLATION_FAILED
        translated_tokens.append(joiner.join(translated_chars))
    return ", ".join(translated_tokens)
