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

后续如需:神煞 20(v1 chart 未含神煞,暂无消费者)。

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
    },
}


def translate_term(zh_term: str, target_language: str) -> str:
    """术语翻译:中文源 → 目标语言。

    严格显式失败策略(对齐 CLAUDE.md "错误显式传播"):
    - 中文目标语言 → 直接返回原文(identity)
    - 未注册的目标语言 → 抛 KeyError(避免误用未实现的语言)
    - 未注册的中文术语 → 抛 KeyError(避免静默返回中文,污染 LLM prompt)

    Args:
        zh_term: 中文术语或 raw key(如 "甲"/"比肩"/"strong")
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
        language: 目标语言代码("zh" / "en")
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
        translated["chart"] = _translate_chart_json(chart, table)
    return translated


_CJK_PATTERN = re.compile(r"[\u4e00-\u9fff]")


def _translate_chart_json(chart_json: str, table: dict[str, str]) -> str:
    """v1 chart JSON 字符串的值级翻译(键不动,值按词表)。"""
    try:
        data = json.loads(chart_json)
    except json.JSONDecodeError as e:
        # 收窄进翻译层:包成专用类型,路由层按本类包装 500(见类注释)
        raise ChartJSONDecodeError(str(e)) from e
    untranslatable: list[str] = []
    walked = _walk_chart_value(data, table, untranslatable)
    if untranslatable:
        logger.warning(
            "translate_context: chart 内 %d 个值未注册翻译,保留中文:%r"
            "(按需在 term_translations.py 扩表)",
            len(untranslatable), sorted(set(untranslatable))[:10],
        )
    return json.dumps(walked, ensure_ascii=False)


def _walk_chart_value(node: object, table: dict[str, str],
                      untranslatable: list[str]) -> object:
    if isinstance(node, dict):
        out: dict = {}
        for key, value in node.items():
            if key == "meta":
                out[key] = value  # 非术语域(日期/locale/规则键/节气界),整体保留
                continue
            # 键也走术语翻译(ten_god_weights / five_elements 的键是十神/五行;
            # 结构键 gan_zhi/shishen_gan 等为拉丁,静默原样)
            new_key = _translate_chart_scalar(key, table, untranslatable) \
                if isinstance(key, str) else key
            out[new_key] = _walk_chart_value(value, table, untranslatable)
        return out
    if isinstance(node, list):
        return [_walk_chart_value(item, table, untranslatable) for item in node]
    if isinstance(node, str):
        return _translate_chart_scalar(node, table, untranslatable)
    return node  # 数字 / None / bool 原样


def _translate_chart_scalar(value: str, table: dict[str, str],
                            untranslatable: list[str]) -> str:
    if not _CJK_PATTERN.search(value):
        return value  # 已是拉丁(如 "metal"/"female"/日期),静默原样
    if value in table:
        return table[value]
    if len(value) == 2 and value[0] in table and value[1] in table:
        return f"{table[value[0]]} {table[value[1]]}"  # 干支 "庚午" → "Geng Wu"
    if all(ch in table for ch in value):
        return " ".join(table[ch] for ch in value)  # 地支对 "戌亥" → "Xu Hai"
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
            result = _translate_pillar(translated[field], table)
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
            result = _translate_element_list(translated[field], table)
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
    """翻译五行列表("木火" → "Wood Fire";"木, 火" → "Wood, Fire")。

    逐 token 尝试逐字符翻译,所有字符都在表里才翻译,否则返回
    _TRANSLATION_FAILED。
    容忍 ", " / "、" 分隔的多 token:真实 wire 格式 iOS 客户端喜忌用
    ", " join(`favorableElements.joined(separator: ", ")`,PromptContextBuilder
    .swift:79 / +Compatibility.swift:99),旧实现只认纯 CJK 连写串,对
    "木, 火" 整体判失败 → en prompt 静默留中文(T1 review 修复)。
    分隔符输出归一为 ", "。
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
        translated_tokens.append(" ".join(translated_chars))
    return ", ".join(translated_tokens)
