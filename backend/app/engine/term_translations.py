"""八字术语翻译表(Joey Yap 体系为事实源)。

i18n 决策 9(`i18n-implementation-plan.md` § 2):以 Joey Yap 体系为英文八字圈事实标准。
所有术语必须显式注册,未注册的术语抛 KeyError(显式失败,不静默返回中文)。

Slice 1 范围:每日运势所需最小术语集(43 项)。
- HEAVENLY_STEMS_EN: 天干 10
- EARTHLY_BRANCHES_EN: 地支 12
- FIVE_ELEMENTS_EN: 五行 5
- TEN_GODS_EN: 十神 11(含偏官/七杀同义映射)
- STRENGTH_LABEL_EN: 旺衰 label 5(对齐 bazi_engine.py:194-200 _STRENGTH_LABEL)
- MISC_TERMS_EN: 空(Slice 1 无独立杂项;day_chong 由 EARTHLY_BRANCHES_EN 覆盖)

后续 Slice 2/3/4 扩展神煞 20 + 纳音 30 + 合盘术语。

术语来源:
- 天干/地支:拼音直用(英文八字圈通用)
- 十神:Joey Yap《The Ten Gods》体系(https://www.joeyyap.com/tutorial/tutorial-details.asp?tid=28)
- 五行:字面意译
- 旺衰:沿用 bazi_engine.py 英文 key + 翻译
"""

from __future__ import annotations

import logging
from typing import Final

logger = logging.getLogger(__name__)

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
TEN_GODS_EN: Final[dict[str, str]] = {
    "比肩": "Companion",
    "劫财": "Rob Wealth",
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

# ---------- 旺衰 label(对齐 bazi_engine.py:194-200 _STRENGTH_LABEL) ----------
# 这些是后端已转好的中文 label,会被填入 prompt context 的 day_master_strength。
# 英文翻译保持语义一致,以便 LLM 在英文 prompt 下生成对应话术。
STRENGTH_LABEL_EN: Final[dict[str, str]] = {
    "偏旺": "Slightly Strong",
    "偏弱": "Slightly Weak",
    "中和": "Balanced",
    "呈现从格特征": "Shows Special Pattern Characteristics",
    "旺衰未判定": "Strength Undetermined",
}

# ---------- 杂项核心术语 ----------
# Slice 1:daily_fortune prompt 无独立杂项术语需翻译
# (day_chong 字段存的是地支字如"午",由 EARTHLY_BRANCHES_EN 覆盖;
#  "冲"字本身不出现在 context 值中,模板里有独立 label)
# Slice 2/3/4 若需可在此扩展
MISC_TERMS_EN: Final[dict[str, str]] = {}

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
    },
}


def translate_term(zh_term: str, target_language: str) -> str:
    """术语翻译:中文源 → 目标语言。

    严格显式失败策略(对齐 CLAUDE.md "错误显式传播"):
    - 中文目标语言 → 直接返回原文(identity)
    - 未注册的目标语言 → 抛 KeyError(避免误用未实现的语言)
    - 未注册的中文术语 → 抛 KeyError(避免静默返回中文,污染 LLM prompt)

    Args:
        zh_term: 中文术语(如 "甲"/"比肩"/"偏旺")
        target_language: 目标语言代码("zh" / "en",未来扩展 "ja" / "es")

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
_DAILY_FORTUNE_SINGLE_TERM_FIELDS: Final[tuple[str, ...]] = (
    "day_master",         # 日主(单天干)
    "day_stem",           # 流日天干
    "day_branch",         # 流日地支
    "day_chong",          # 流日冲(单地支)
    "day_master_element",   # 五行
    "day_stem_element",    # 五行
    "day_branch_element",   # 五行
    "day_master_strength",  # 旺衰 label
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
        language: 目标语言代码("zh" / "en")
        module: module 名(决定翻译规则)

    Returns:
        翻译后的 context(新 dict,不修改原)
    """
    if language == "zh":
        return context
    if module == "daily_fortune":
        return _translate_daily_fortune_context(context, language)
    # 其他 module 暂未实现(Slice 2/3/4 跟进)
    # 不抛错(避免阻塞已有 module 的英文请求),但 log warning
    # 注意:返回原 context 不代表请求成功 — 后续 render_prompt 会因 prompts/{lang}/
    # 模板缺失而抛 FileNotFoundError,路由层包成 500。此 warning 仅说明翻译层跳过,
    # 不暗示英文请求能正常完成。
    logger.warning(
        "translate_context: module=%s 暂未实现 %s 翻译规则,context 保留中文 "
        "(下游 render_prompt 将因模板缺失抛 FileNotFoundError → 500;"
        "Slice 2/3/4 补齐 module 翻译规则 + 模板文件后才能成功)",
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

    # 复合术语字段(逐字符翻译 + 空格连接)
    for field in _DAILY_FORTUNE_COMPOSITE_FIELDS:
        if field in translated:
            v = translated[field]
            if isinstance(v, str):
                result = _translate_pillar(v, table)
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
                result = _translate_element_list(v, table)
                if result is _TRANSLATION_FAILED:
                    logger.warning(
                        "translate_context: 字段 %s 值 %r 含未知字符,"
                        "保留原文",
                        field, v,
                    )
                else:
                    translated[field] = result

    return translated


def _translate_pillar(pillar: str, table: dict[str, str]) -> str | object:
    """翻译干支字符串("甲子" → "Jia Zi";"丙午" → "Bing Wu")。

    长度 2(天干+地支)时翻译,其他长度保留原文(避免误伤)。

    Returns:
        翻译后的字符串,或 _TRANSLATION_FAILED sentinel(无法翻译时)
    """
    if len(pillar) != 2:
        return _TRANSLATION_FAILED  # 非标准干支格式
    gan, zhi = pillar[0], pillar[1]
    if gan in table and zhi in table:
        return f"{table[gan]} {table[zhi]}"
    return _TRANSLATION_FAILED  # 部分字符不在表里


def _translate_element_list(elements: str, table: dict[str, str]) -> str | object:
    """翻译五行列表("木火" → "Wood Fire";"金水" → "Metal Water")。

    逐字符尝试翻译,所有字符都在表里才翻译,否则返回 _TRANSLATION_FAILED。
    """
    translated_chars = []
    for ch in elements:
        if ch in table:
            translated_chars.append(table[ch])
        else:
            # 任意字符不在表里,放弃翻译整个字符串
            return _TRANSLATION_FAILED
    return " ".join(translated_chars)
