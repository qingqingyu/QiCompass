"""L2 接地校验层(不花钱,本系列价值核心)。

把"LLM 编造了后端没给的东西"从"要靠裁判读出来"变成"机器直接判死"。
纯函数,统一签名 (module, parsed_output, engine_result) -> list[str]
(链式一致性多一个可选 chain_context),只读入参不做 IO——这是它们
能被大量单测覆盖的前提。

关于误报的立场(宁可漏报,不可误报):
- 模式匹配一律保守:证据不足就不判(歧义句跳过、信号词与五行必须
  近距共现、"泄/克"类有方向歧义的关系动词不启用、非五行复合词
  二次否决——金融/土地/火车这类日常词里的五行字不算五行义)
- 每条 failure 自带命中原文片段 + 冲突的 ground truth 值,可在 UI 人工复核
- 首轮基线(S06)后人工复核全部 L2 failure;误报优先收紧模式

2026-10-12 M0 质量批(docs/命书M0主线结构内容质量修复-plan.md S2)新增
五项 m0 结构纪律检查 + 复合格局名模式:A1(格名模式)/A3(分层)/A4(flow
箭头)/A5(机器字段名)/B1(地支五行)/B2(十神归类)。其中 A3/A4/A5/B1/B2
仅对 m0_structure 生效——zh m1-m7 模板尚未含机器字段名禁令等规则(本批
范围外,plan S5),全开会把旧模板的概率性泄漏放大成 evalkit fail 且本批
无法修复;m1-m7 模板补齐规则时再放开。

对齐:ADR-0004(喜忌确定性)/ 0005(神煞 20 固定清单)/ 0006(格局砍掉
模糊叙事)/ 0007(从格诚实降级)。
"""

from __future__ import annotations

import re
from difflib import SequenceMatcher
from typing import Any, Iterator

from app.engine.chart_builder import build_v1_chart
from app.engine.shensha import SHENSHA_NAMES

# ---------- 五行中英映射 ----------
# 实测(2026-08-18):BaziEngine 的 favorable_elements/unfavorable_elements
# 直接输出中文('金'/'土');英文映射保留兼容( Spike/老模块语境)。
# run_spike.py 的 _ELEMENT_ZH 已随其失效标注冻结,此处是 evalkit 侧唯一一份。

_ELEMENT_ZH = {"wood": "木", "fire": "火", "earth": "土",
               "metal": "金", "water": "水"}
_ELEMENT_CHARS = ("木", "火", "土", "金", "水")


def _element_to_zh(element: str) -> str:
    """五行 → 中文。接受英文(wood/…)或中文(木/…)输入。

    未知值显式 raise(ground truth 出了问题要暴露,不静默跳过)。
    """
    if element in _ELEMENT_ZH:
        return _ELEMENT_ZH[element]
    if element in _ELEMENT_CHARS:
        return element
    raise ValueError(
        f"未知五行值: {element!r}"
        f"(合法: 英文 {sorted(_ELEMENT_ZH)} 或中文 {list(_ELEMENT_CHARS)})"
    )


# ---------- 共享文本工具 ----------

def _iter_text_leaves(obj: Any) -> Iterator[str]:
    """递归收集 parsed_output 里所有字符串叶子(含嵌套 list/dict)。"""
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, dict):
        for value in obj.values():
            yield from _iter_text_leaves(value)
    elif isinstance(obj, (list, tuple)):
        for item in obj:
            yield from _iter_text_leaves(item)


# 切句标点(半/全角都要)。2026-10-12 M0 批全量 run 分诊修复:原集合把
# 半角 ; 写了两遍、全角 ；(U+FF1B)从未收录——真机 m7 输出「…在喜用位；水
# 透出层为 0」没被切开,「喜用.{0,2}水」跨子句命中,把「推荐土金(正确)」
# 误报成「推荐水(忌)」。! 与 ? 同病(两个全是半角重复,全角 ！？ 从未
# 收录),双 review 第 1 轮一并补齐。
_SENTENCE_SPLIT = re.compile(r"[。!？！?;；\n\r]")


def _iter_sentences(text: str) -> list[str]:
    """切句:推荐/规避判定只在句内做,跨句不判。"""
    return [s for s in _SENTENCE_SPLIT.split(text) if s.strip()]


# 信号词与五行的近距 gap(≤2 字):排除开括号(半/全角)——信号词跨进括号
# 插入语再遇五行字,是两个语义单元(2026-10-12 全量 run m6 实踩:「回补
# (水行计数 0」被判「补(水」推荐水;括号内是数据陈述不是推荐对象)。
_GAP = "[^\uff08(]{0,2}"


def _clip(text: str, limit: int = 40) -> str:
    """failure 证据片段截断。"""
    return text if len(text) <= limit else text[:limit] + "…"


# ---------- 信号词与模式(保守设计) ----------
#
# "泄/克"类关系动词有方向歧义(如"宜用金泄土"里金是被推荐的),
# 首轮不启用;带噪声的判据会训练出"习惯性忽略红色"的坏习惯。
# 同句同时出现推荐与规避信号 → 视为歧义句,整句跳过(宁可漏报)。

_RECO_SIGNALS_FIRST = ("宜", "喜用", "适合", "补", "增强", "用神")
_RECO_SIGNALS_LAST = ("有利", "为用神", "当旺", "来补")
_AVOID_SIGNALS_FIRST = ("忌", "避", "不宜", "克制")
_AVOID_SIGNALS_LAST = ("不利", "为忌")


def _signal_regex(sig: str) -> str:
    """信号词 → 正则片段。

    单字「宜」加负向后顾:不许命中「不宜」内部的宜。否则任何以
    「不宜」为唯一规避信号的句子都被判成"推荐+规避并存"的歧义句
    整句跳过,规避判据静默失效(P1-2,2026-08-19 review 修复)。
    """
    if sig == "宜":
        return r"(?<!不)宜"
    return re.escape(sig)


_RECO_SIGNAL_RES = tuple(re.compile(_signal_regex(s))
                         for s in _RECO_SIGNALS_FIRST + _RECO_SIGNALS_LAST)
_AVOID_SIGNAL_RES = tuple(re.compile(_signal_regex(s))
                          for s in _AVOID_SIGNALS_FIRST + _AVOID_SIGNALS_LAST)


# ---------- 非五行复合词否决表(P1-1) ----------
#
# 五行单字大量出现在日常复合词里:财富/事业模块天然高频出现
# 金融、资金、水产、土地、木工、火车……"信号词.{0,2}五行字"的
# 近距共现挡不住这类误报。命中后做二次否决:五行字的前/后一位
# 若与它构成下表中的常见复合词,不算五行义。
# 立场:宁可漏报——否决从宽;首轮基线人工复核后按误报样本扩充。

_NON_WUXING_SUFFIX: dict[str, tuple[str, ...]] = {
    "金": ("融", "额", "属"),            # 金融 金额 金属
    "水": ("产", "平", "准", "果"),      # 水产 水平 水准 水果
    "土": ("地", "壤"),                  # 土地 土壤
    "木": ("工", "材"),                  # 木工 木材
    "火": ("车", "力", "中", "候"),      # 火车 火力 火中取栗 火候
}
_NON_WUXING_PREFIX: dict[str, tuple[str, ...]] = {
    "金": ("资", "现", "黄", "奖", "基", "佣"),  # 资金 现金 黄金 奖金 基金 佣金
    # 补 2026-10-12 全量 run 实踩:「补水」高频词义歧义——m4 生理饮水
    # (「补水少」)/m5 流动性隐喻(「补水 0 的缓冲缺口」),真五行推荐另有
    # 宜/喜用/适合 等信号词携带;宁可漏报,只有 水 收「补」前缀。
    # 其余行不收:「宜补火」是真五行推荐实踩样本(见
    # test_special_pattern_real_fabrication_still_fails),补火/补土
    # 不是日常词,收了就是把真编造放走。
    "水": ("薪", "补"),                  # 薪水 补水
    "土": ("本",),                      # 本土
    "火": ("上",),                      # 上火
}


def _is_non_wuxing_compound(sentence: str, idx: int, element_zh: str) -> bool:
    """sentence[idx] 处的五行字是否与相邻一字构成常见非五行复合词。"""
    prefix = sentence[idx - 1: idx]
    suffix = sentence[idx + 1: idx + 2]
    return (prefix in _NON_WUXING_PREFIX.get(element_zh, ())
            or suffix in _NON_WUXING_SUFFIX.get(element_zh, ()))


def _reco_hits(sentence: str, element_zh: str) -> list[str]:
    """句内"推荐某五行"的命中模式(信号在前或在后,近距共现 ≤2 字)。

    命中后经 _is_non_wuxing_compound 二次否决(金融/土地类不算五行义)。
    """
    hits: list[str] = []
    for sig in _RECO_SIGNALS_FIRST:
        pattern = rf"{_signal_regex(sig)}{_GAP}{re.escape(element_zh)}"
        for m in re.finditer(pattern, sentence):
            if not _is_non_wuxing_compound(sentence, m.end() - 1, element_zh):
                hits.append(m.group(0))
    for sig in _RECO_SIGNALS_LAST:
        pattern = rf"{re.escape(element_zh)}{_GAP}{_signal_regex(sig)}"
        for m in re.finditer(pattern, sentence):
            if not _is_non_wuxing_compound(sentence, m.start(), element_zh):
                hits.append(m.group(0))
    return hits


def _avoid_hits(sentence: str, element_zh: str) -> list[str]:
    """句内"规避某五行"的命中模式(同样过复合词二次否决)。"""
    hits: list[str] = []
    for sig in _AVOID_SIGNALS_FIRST:
        pattern = rf"{_signal_regex(sig)}{_GAP}{re.escape(element_zh)}"
        for m in re.finditer(pattern, sentence):
            if not _is_non_wuxing_compound(sentence, m.end() - 1, element_zh):
                hits.append(m.group(0))
    for sig in _AVOID_SIGNALS_LAST:
        pattern = rf"{re.escape(element_zh)}{_GAP}{_signal_regex(sig)}"
        for m in re.finditer(pattern, sentence):
            if not _is_non_wuxing_compound(sentence, m.start(), element_zh):
                hits.append(m.group(0))
    return hits


def _sentence_has_reco_or_avoid(sentence: str) -> tuple[bool, bool]:
    has_reco = any(r.search(sentence) for r in _RECO_SIGNAL_RES)
    has_avoid = any(r.search(sentence) for r in _AVOID_SIGNAL_RES)
    return has_reco, has_avoid


# ---------- 1. 喜忌一致性 ----------

def check_xiji_consistency(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """输出中被明确推荐的五行不得与后端 favorable/unfavorable 矛盾。

    favorable_elements 为空(special_pattern 盘)→ 本项跳过,交给
    check_special_pattern_honesty。缺键 → raise(排盘结果不完整要暴露)。
    """
    favorable = engine_result["favorable_elements"]
    unfavorable = engine_result["unfavorable_elements"]
    if not favorable:
        return []

    fav_zh = {_element_to_zh(e) for e in favorable}
    unfav_zh = {_element_to_zh(e) for e in unfavorable}

    failures: list[str] = []
    for leaf in _iter_text_leaves(parsed_output):
        for sentence in _iter_sentences(leaf):
            has_reco, has_avoid = _sentence_has_reco_or_avoid(sentence)
            if has_reco and has_avoid:
                continue  # 歧义句不判(宁可漏报)
            if has_reco:
                for zh in sorted(unfav_zh):
                    for hit in _reco_hits(sentence, zh):
                        failures.append(
                            f"喜忌矛盾:文本「{hit}」推荐 {zh},"
                            f"但后端 unfavorable={sorted(unfav_zh)}"
                            f"(原文:{_clip(sentence)!r})"
                        )
            if has_avoid:
                for zh in sorted(fav_zh):
                    for hit in _avoid_hits(sentence, zh):
                        failures.append(
                            f"喜忌矛盾:文本「{hit}」规避 {zh},"
                            f"但后端 favorable={sorted(fav_zh)}"
                            f"(原文:{_clip(sentence)!r})"
                        )
    return failures


# ---------- 2. 神煞不超界 ----------

# 清单外神煞 watchlist:无法穷举编造词,只扫常见项;首轮人工复核后扩充。
_KNOWN_OUT_OF_LIST: tuple[str, ...] = (
    "天医", "国印", "天厨", "金匮", "三奇贵人", "福星贵人", "天喜", "红鸾",
)


def check_shensha_bounded(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """神煞不超界:越界(清单外)与未命中(清单内但本盘没查到)分别成条。"""
    names_hit = {s["name"] for s in engine_result["shensha"]}

    failures: list[str] = []
    for leaf in _iter_text_leaves(parsed_output):
        for name in SHENSHA_NAMES:
            if name in leaf and name not in names_hit:
                failures.append(
                    f"神煞未命中:文本提及「{name}」(在 20 清单内,但本盘"
                    f"实际命中={sorted(names_hit) or '无'},"
                    f"原文:{_clip(leaf)!r})"
                )
        for name in _KNOWN_OUT_OF_LIST:
            if name in leaf:
                failures.append(
                    f"神煞越界:文本提及「{name}」(不在 SHENSHA_NAMES "
                    f"20 固定清单内,原文:{_clip(leaf)!r})"
                )
    return failures


# ---------- 3. 格局红线 ----------

_HARD_GEJU_WORDS: tuple[str, ...] = (
    "正官格", "七杀格", "偏官格", "正财格", "偏财格",
    "正印格", "偏印格", "食神格", "伤官格", "比肩格",
    "劫财格", "建禄格", "羊刃格",
)

# 复合格局名模式(2026-10-12 M0 质量批 A1):固定词表只列了 13 个单十神
# 格名,复合格名(杀印相生格/伤官配印格/食神制杀格/财滋弱杀格…)漏网,
# 真机 M0 实踩。两层否决——立场仍是宁可漏报:白名单/排除集从宽收录,
# 实跑误报样本出现时再补。
# ① 后缀白名单(词尾「X格」的日常/认可措辞,token.endswith 命中即放行)。
#   「常格」「从格」必须在内:special_pattern 诚实降级表述「不入常格/
#   从格特征」是 _HONEST_WORDS 与 _special_pattern_suffix 模板认可的
#   措辞(20 盘语料 5 盘从格盘,M0-M7 都被要求这么写),不能被模式误杀;
#   「从格」只在 special_pattern 盘放行,普通盘写「从格」是把身强身弱
#   讲错,仍应拦。
# ② 负向前瞻(格后紧跟「局/式/外/调/子/…」时放行):「格局/格式/格外/
#   格调/格子」等格字开头的日常词,endswith 结构性救不了,只能按后继
#   字排除。「杀印相生格局」这类后继字写法随之漏报——接受(宁可漏报)。
_COMMON_GE_SUFFIX_WORDS: tuple[str, ...] = (
    "性格", "风格", "规格", "资格", "价格", "人格", "表格", "合格",
    "及格", "品格", "体格", "定格", "破格", "升格", "降格", "严格",
    "顶格", "一格", "宾格", "主格", "常格", "从格", "出格", "九宫格",
    "满格",  # 2026-10-12 全量 run 实踩:m6「精力是否回到满格」误报
    "掉格",  # 同族:m7「拆解时电池不掉格」(电池/信号条量词)
    "正格",  # 同 run 实踩:m7 推翻信号段「按正格的方式运转」(从格的否定
    # 语域,泛指常规命局,不是具体格局名)
)
_GEJU_NEXT_CHAR_EXEMPT = "局式外调子言物斗挡"
_GEJU_RE = re.compile(rf"[一-鿿]{{2,6}}格(?![{_GEJU_NEXT_CHAR_EXEMPT}])")


def check_no_hard_geju(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """硬性格局分类是红线(ADR-0006),命中即 fail,不打分。

    词表(13 个单十神格名)+ 模式(2-6 个汉字 + 格,即任意复合格名)双层;
    单独的"格局"二字是允许的中性表述。模式命中后过两层否决:日常词后缀
    白名单(别具一格/高规格/不入常格…)+ 格字开头日常词的负向前瞻
    (格局/格式/格外…,见 _GEJU_RE)。「从格」仅在 special_pattern 盘放行
    (_HONEST_WORDS 认可的诚实降级措辞)。
    """
    congge_allowed = (
        engine_result["day_master_strength"] == "special_pattern")
    suffixes = _COMMON_GE_SUFFIX_WORDS if congge_allowed else tuple(
        w for w in _COMMON_GE_SUFFIX_WORDS if w != "从格")
    failures: list[str] = []
    for leaf in _iter_text_leaves(parsed_output):
        reported_words = {
            word for word in _HARD_GEJU_WORDS if word in leaf}
        for word in sorted(reported_words):
            failures.append(
                f"硬性格局:文本出现「{word}」(只准「命局呈现××倾向」"
                f"模糊叙事,原文:{_clip(leaf)!r})"
            )
        reported_tokens: set[str] = set()
        for m in _GEJU_RE.finditer(leaf):
            token = m.group(0)
            # 词表已单独报过的不再重复报;token 内含词表词(贪婪匹配吃进
            # 前缀,如「此为正官格」)也已由词表覆盖
            if any(word in token for word in reported_words):
                continue
            if token in reported_tokens:
                continue
            if any(token.endswith(w) for w in suffixes):
                continue
            reported_tokens.add(token)
            failures.append(
                f"硬性格局:文本出现「{token}」(以「格」结尾的传统格局名"
                f"一律禁止,含复合格名;原文:{_clip(leaf)!r})"
            )
    return failures


# ---------- 4. special_pattern 诚实 ----------

_HONEST_WORDS: tuple[str, ...] = (
    "不入常格", "不适用扶抑", "扶抑框架", "特殊格局", "从格", "专旺",
)


def check_special_pattern_honesty(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """特殊盘(20 盘中的 5 盘)两条:不得编造喜忌 + 须诚实告知降级。

    chart 注入的 strength_label="从格特征" 天然引导 LLM 复述"从格",
    完全不提才是异常(隐藏降级)。
    """
    if engine_result["day_master_strength"] != "special_pattern":
        return []

    failures: list[str] = []
    leaves = list(_iter_text_leaves(parsed_output))

    # 规则 1:不得编造喜忌(后端 favorable/unfavorable 按设计为空)
    for leaf in leaves:
        for sentence in _iter_sentences(leaf):
            has_reco, has_avoid = _sentence_has_reco_or_avoid(sentence)
            if has_reco and has_avoid:
                continue
            for zh in _ELEMENT_CHARS:
                if has_reco:
                    for hit in _reco_hits(sentence, zh):
                        failures.append(
                            f"special_pattern 编造喜忌:文本「{hit}」推荐 {zh},"
                            f"但后端未下喜忌结论(原文:{_clip(sentence)!r})"
                        )
                if has_avoid:
                    for hit in _avoid_hits(sentence, zh):
                        failures.append(
                            f"special_pattern 编造喜忌:文本「{hit}」规避 {zh},"
                            f"但后端未下喜忌结论(原文:{_clip(sentence)!r})"
                        )

    # 规则 2:须出现诚实降级表述,否则视为隐藏降级
    if not any(word in leaf for leaf in leaves for word in _HONEST_WORDS):
        failures.append(
            "special_pattern 隐藏降级:全文未出现「不入常格/从格/专旺/特殊格局」"
            "类诚实表述(后端喜忌留空的原因必须告知用户)"
        )
    return failures


# ---------- 5. 链式一致性 ----------

def check_chain_consistency(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
    chain_context: dict[str, Any] | None = None,
) -> list[str]:
    """M1-M6 引用 structure_fingerprint 必须逐字等于 M0 产出。

    M7 不做逐字判:模板明写"不要复述前面的分析",输出是综合改写而非
    echo,逐字比对要么永不触发要么松匹配误报;M7 忠实度归 L3。

    chain_context: {module_id: parsed_output}(本盘已完成模块);
    None 时跳过(便于单模块调试,不报错)。
    """
    if chain_context is None:
        return []
    if module in ("m0_structure", "m7_manual"):
        return []  # M0 是 fingerprint 生产者;M7 不做逐字判(见 docstring)

    m0 = chain_context.get("m0_structure")
    fp = m0.get("structure_fingerprint") if isinstance(m0, dict) else None
    if not isinstance(fp, str) or not fp:
        return []

    leaves = list(_iter_text_leaves(parsed_output))
    if any(fp in leaf for leaf in leaves):
        return []  # 逐字继承,通过

    # 未逐字出现:检测"近似引用"(最长公共连续块 ≥ 半个 fingerprint)
    # ——改写一两个字还能抓住,正常行文不可能巧合命中半个指纹。
    threshold = max(6, len(fp) // 2)
    best_block = ""
    for leaf in leaves:
        matcher = SequenceMatcher(None, fp, leaf, autojunk=False)
        match = matcher.find_longest_match(0, len(fp), 0, len(leaf))
        if match.size > len(best_block):
            best_block = fp[match.a:match.a + match.size]
    if len(best_block) >= threshold:
        return [
            f"链式不一致:M0 structure_fingerprint 被改写。期望「{fp}」,"
            f"输出出现近似引用「{best_block}」(须逐字继承)"
        ]
    return []


# ---------- 6. M0 结构纪律(2026-10-12 M0 质量批 S2) ----------
#
# 来源:用户真机截图(丙寅辛丑庚午庚辰盘)M0 输出实测翻车五类。
# 全部 m0_structure 专属(理由见模块 docstring);正例 = 真机翻车原文,
# 反例 = 日常措辞不误报。

_TEN_GOD_NAMES: tuple[str, ...] = (
    "比肩", "劫财", "食神", "伤官", "偏财", "正财",
    "七杀", "正官", "偏印", "正印",
)
# 十神五类归属(命理固定,与 prompt v7 自检规则同源)
_TEN_GOD_FAMILY: dict[str, str] = {
    "比肩": "比劫", "劫财": "比劫",
    "食神": "食伤", "伤官": "食伤",
    "偏财": "财星", "正财": "财星",
    "七杀": "官杀", "正官": "官杀",
    "偏印": "印星", "正印": "印星",
}
# 地支五行归属(命理固定):五行字面 → 该五行地支集
_ELEMENT_BRANCHES: dict[str, frozenset[str]] = {
    "木": frozenset("寅卯"), "火": frozenset("巳午"),
    "金": frozenset("申酉"), "水": frozenset("亥子"),
    "土": frozenset("辰戌丑未"),
}
_BRANCH_ELEMENT: dict[str, str] = {
    branch: element
    for element, branches in _ELEMENT_BRANCHES.items()
    for branch in branches
}

# 「X支(…)」/「X支:…」列举地支(plan B1:保守——只在五行字面紧跟
# 括号/冒号列举时判,散句提及不判)。冒号列举的停止类必须含全角
# 「；！?」与半/全角逗号:「土支:丑辰；火支:巳午」「土支:丑辰，火支:
# 巳午」这类排比若不在组分隔标点停,会把下一组的巳午吞进土支列举 →
# 误报(逗号 2026-10-12 双 review 第 1 轮补:全角逗号是 LLM zh 排比的
# 自然标点)。代价:列举内部用逗号分项(「土支:丑,辰」)只检到逗号前,
# 漏报接受。空格分隔无标点的排比仍可能吞组——语料未见,按「实跑误报
# 样本出现时再补」立场搁置。
_BRANCH_PAREN_RE = re.compile(r"([木火土金水])支\s*[（(]([^）)]*)[）)]")
_BRANCH_COLON_RE = re.compile(r"([木火土金水])支\s*[：:]([^。;；!！?？\n,，]*)")
# 「财星(…)」/「财星组(…)」/「印星家族(…)」列举十神(plan B2)
_FAMILY_PAREN_RE = re.compile(
    r"(比劫|食伤|财星|官杀|印星)(?:组|类|家族)?\s*[（(]([^）)]*)[）)]")


def check_no_machine_field_names(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """A5 机器字段名外泄:输出字符串出现 chart JSON 的 snake_case 键名。

    键名从 build_v1_chart(engine_result) 动态收集(LLM 实际看到什么键就
    禁什么键,不手写死清单),只取含下划线的多词标识符——stem/branch/
    pillar 这类单词是 EN 输出的合法英文词,收进来必误报(宁可漏报)。
    真机翻车原文:「据 · five_elements: 水0,木1;ten_god_weights: 食神0…」。
    """
    if module != "m0_structure":
        return []
    keys: set[str] = set()

    def _walk(node: Any) -> None:
        if isinstance(node, dict):
            for k, v in node.items():
                if isinstance(k, str) and "_" in k:
                    keys.add(k)
                _walk(v)
        elif isinstance(node, list):
            for item in node:
                _walk(item)

    _walk(build_v1_chart(engine_result))

    failures: list[str] = []
    for leaf in _iter_text_leaves(parsed_output):
        for key in sorted(keys):
            # ASCII 词边界:下划线标识符两侧不得是字母/数字/下划线
            # (CJK 视为边界,「如five_elements:」这种紧贴写法也能命中)
            if re.search(
                rf"(?<![A-Za-z0-9_]){re.escape(key)}(?![A-Za-z0-9_])", leaf
            ):
                failures.append(
                    f"机器字段名外泄:输出出现「{key}」(依据必须用人话写,"
                    f"原文:{_clip(leaf)!r})"
                )
    return failures


def check_branch_element_attribution(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """B1 地支五行错置:「土支(丑月、辰时、午日)」——午属火不属土。

    只判括号/冒号紧跟列举的形式;列举里的非地支字(月/时/日等)忽略。
    真机翻车原文即 driver 段「土支(丑月、辰时、午日)生助正印」。
    """
    if module != "m0_structure":
        return []
    failures: list[str] = []
    for leaf in _iter_text_leaves(parsed_output):
        matches = list(_BRANCH_PAREN_RE.finditer(leaf)) + list(
            _BRANCH_COLON_RE.finditer(leaf))
        for m in matches:
            element, inside = m.group(1), m.group(2)
            wrong = sorted({
                ch for ch in inside if ch in _BRANCH_ELEMENT
                and _BRANCH_ELEMENT[ch] != element
            })
            if wrong:
                detail = "、".join(
                    f"{ch}({_BRANCH_ELEMENT[ch]})" for ch in wrong)
                failures.append(
                    f"地支五行错置:「{element}支」列举里出现 {detail}"
                    f"(原文:{_clip(m.group(0))!r})"
                )
    return failures


def check_ten_god_category_attribution(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """B2 十神归类错置:「财星组(偏财、劫财)」——劫财属比劫不属财星。

    只判五类标签紧跟括号列举的形式;括号里没有十神名则跳过。
    """
    if module != "m0_structure":
        return []
    failures: list[str] = []
    for leaf in _iter_text_leaves(parsed_output):
        for m in _FAMILY_PAREN_RE.finditer(leaf):
            family, inside = m.group(1), m.group(2)
            wrong = sorted({
                god for god in _TEN_GOD_NAMES
                if god in inside and _TEN_GOD_FAMILY[god] != family
            })
            if wrong:
                detail = "、".join(
                    f"{g}({_TEN_GOD_FAMILY[g]})" for g in wrong)
                failures.append(
                    f"十神归类错置:「{family}」括注里出现 {detail}"
                    f"(原文:{_clip(m.group(0))!r})"
                )
    return failures


def check_flow_no_chain_symbols(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """A4 flow 复述链条:from/to 已单独成字段,flow 里再写「A → B → A」
    就是复读。≥2 个箭头符号(→ / ->)即 fail(单箭头容许,保守)。

    真机翻车原文:flow 含 4 个箭头,把 from→to 链条完整复述一遍还多转一圈。
    """
    if module != "m0_structure":
        return []
    core_loop = parsed_output.get("core_loop")
    if not isinstance(core_loop, dict):
        return []
    flow = core_loop.get("flow")
    if not isinstance(flow, str):
        return []
    arrows = flow.count("→") + flow.count("->")
    if arrows >= 2:
        return [
            f"flow 复述链条:含 {arrows} 个箭头符号,from/to 已单独成字段,"
            f"flow 只讲机制(原文:{_clip(flow)!r})"
        ]
    return []


def check_layering_consistency(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """A3 分层与权重一致:dominant/latent 两层的强度序不得倒挂。

    两条:①并列最高的十神不得出现在 latent(真机翻车:七杀 6 = 劫财 6,
    劫财被塞进「潜伏」层);②dominant 层的强度代表(该层提及十神的**最高**
    权重)≥ latent 层的强度代表。用最高而非最低:LLM 常按十神家族分层
    (dominant=「比劫(劫财 7…比肩仅 1…)」),家族内低权重神是叙事说明
    不是层成员判定,按最低权重比对会把正当的家族分层误杀(2026-10-12
    全量 run 三条实踩);层的强弱由它的领衔十神决定。十神名提取不到
    (EN 输出等)跳过不判(宁可漏报)。
    """
    if module != "m0_structure":
        return []
    axis = parsed_output.get("main_axis")
    if not isinstance(axis, dict):
        return []
    weights = engine_result["ten_god_weights"]
    dominant, latent = axis.get("dominant"), axis.get("latent")
    if not isinstance(dominant, str) or not isinstance(latent, str):
        return []
    dom_weights = {
        g: weights[g] for g in _TEN_GOD_NAMES
        if g in dominant and g in weights
    }
    lat_weights = {
        g: weights[g] for g in _TEN_GOD_NAMES
        if g in latent and g in weights
    }
    if not dom_weights or not lat_weights:
        return []
    failures: list[str] = []
    max_weight = max(weights.values())
    if max_weight > 0:
        top_in_latent = sorted(
            g for g, w in lat_weights.items() if w == max_weight)
        if top_in_latent:
            failures.append(
                f"分层失真:并列最重 {'、'.join(top_in_latent)}"
                f"(权重 {max_weight})不得落在 latent 层"
            )
    dom_max = max(dom_weights.values())
    lat_max = max(lat_weights.values())
    if dom_max < lat_max:
        dom_lead = max(dom_weights, key=lambda g: dom_weights[g])
        lat_lead = max(lat_weights, key=lambda g: lat_weights[g])
        failures.append(
            f"分层失真:dominant 层领衔「{dom_lead}」权重 {dom_max} 低于 "
            f"latent 层领衔「{lat_lead}」权重 {lat_max}"
        )
    return failures


# ---------- 聚合入口 ----------

def check_grounding(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
    chain_context: dict[str, Any] | None = None,
) -> list[str]:
    """L2 聚合:顺序跑全部检查并合并 failures(空 = 全过)。"""
    failures: list[str] = []
    failures += check_xiji_consistency(module, parsed_output, engine_result)
    failures += check_shensha_bounded(module, parsed_output, engine_result)
    failures += check_no_hard_geju(module, parsed_output, engine_result)
    failures += check_special_pattern_honesty(module, parsed_output, engine_result)
    failures += check_chain_consistency(
        module, parsed_output, engine_result, chain_context=chain_context)
    failures += check_no_machine_field_names(
        module, parsed_output, engine_result)
    failures += check_branch_element_attribution(
        module, parsed_output, engine_result)
    failures += check_ten_god_category_attribution(
        module, parsed_output, engine_result)
    failures += check_flow_no_chain_symbols(
        module, parsed_output, engine_result)
    failures += check_layering_consistency(
        module, parsed_output, engine_result)
    return failures
