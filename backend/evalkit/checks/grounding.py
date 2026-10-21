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

2026-10-14 M0 白话结论层批(docs/命书M0白话结论层-plan.md S2,模板 v9)
再增四项 m0-gated 检查:v9-1(结论层无术语/无干支/无数字,headline 缺失
即 fail)/v9-2(展开层无数字,年龄豁免)/v9-3(权重>0 不得写缺)/v9-5(照抄
示例短语);另有 v9-4 工程腔禁用词只统计不判 fail(warnings 旁路,
collect_banned_register_warnings,词表误伤面未观察够前不进 failures)。

对齐:ADR-0004(喜忌确定性)/ 0005(神煞 20 固定清单)/ 0006(格局砍掉
模糊叙事)/ 0007(从格诚实降级)。
"""

from __future__ import annotations

import re
from difflib import SequenceMatcher
from typing import Any, Iterator

from app.ai.prompts import M0_V9_EXAMPLE_PHRASES
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
    # 2026-10-13 review 修复:无条件否决连真违规一起放走了——水为忌盘
    # 「宜补水」/从格盘「适合补水」整句漏报(信号词直接挂在补水前,明明
    # 是五行断言)。收紧为**条件放行**:仅当补水复合词前 ≤2 字窗口内
    # 无推荐/规避信号词时才当日常词否决(见 _BU_SHUI_SIGNAL_BEFORE)。
    "水": ("薪", "补"),                  # 薪水 补水
    "土": ("本",),                      # 本土
    "火": ("上",),                      # 上火
}


# 「补水」条件放行的信号词前瞻(2026-10-13 review 修复):复合词「补水」
# 前紧挂推荐/规避信号词(信号 ≤2 字 + gap ≤2 字 ⇒ 锚定补字前查尾部),
# 按五行断言处理——否决不再适用。信号集 = 推荐词(除「补」自身)∪ 规避
# 词,与 _RECO/_AVOID 两表同源;LAST 型信号(「补水有利」)不在此列——
# 该句式日常义更自然,维持否决(宁可漏报)。
# 已知残留误报面(gap ≤2 的代价,拍板接受):m4 饮水建议「夏季宜多补水」
# (宜 与补水隔 1 字垫字)会按五行断言误报。不收窄 gap=0——真违规同样
# 有垫字形(「宜以补水调理」),两侧都真实,取舍为抓编造优先(编造漏报
# 无人工复核兜底,饮水误报有);实跑出现误报样本再按词收紧。
_BU_SHUI_SIGNAL_BEFORE = re.compile(
    r"(?:不宜|喜用|适合|增强|用神|克制|忌|避|宜)[^（(]{0,2}$")


def _is_non_wuxing_compound(sentence: str, idx: int, element_zh: str) -> bool:
    """sentence[idx] 处的五行字是否与相邻一字构成常见非五行复合词。"""
    prefix = sentence[idx - 1: idx]
    suffix = sentence[idx + 1: idx + 2]
    if (element_zh == "水" and prefix == "补"
            and _BU_SHUI_SIGNAL_BEFORE.search(sentence[:idx - 1])):
        return False
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
    "网格", "空格", "方格",  # 2026-10-13 review:「网格化管理/按空格分开/
    # 九宫格里排方格」误报(方格一词还救贪婪吞长的「…九宫格…方格」token)
    "半格",  # 2026-10-13 全量 run 实踩:m4「电量从半格充到满格」(电量条
    # 量词,满格/掉格同族)
    "格格",  # 成语「格格不入」:负向前瞻放行第一枚格后,贪婪匹配会在
    # 第二枚格上另成 token「你越显得格格」,endswith 格格 放行——与
    # _GEJU_NEXT_CHAR_EXEMPT 的「格」双侧堵,只堵一侧另一枚仍被吞
    # (2026-10-13 全量 run m3 实踩「越规范的组织里你越显得格格不入」)
    "够格",  # 2026-10-14 v9 全量 run m7 实踩:「两项力量不够格当杠杆」
    # (够格/不够格=日常「资格」义,格后接「当」不在前瞻豁免集被误杀;
    # 真实格局名无一以「够格」收尾,同 满格/掉格 族按 endswith 从宽)
)
# 格后紧跟「格」= 格格不入类成语的第一枚格(2026-10-13 全量 run 实踩),
# 负向前瞻放行;真实格局名无一以「格格」收尾,按宁可漏报从宽
_GEJU_NEXT_CHAR_EXEMPT = "局式外调子言物斗挡格"
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


# 干净括号列举的分隔符(「财星组(偏财、劫财)」/「比劫(偏印，正印)」)。
_PAREN_ENUM_SPLIT_RE = re.compile(r"[、，,]|与|和")
_PAREN_ANY_RE = re.compile(r"（([^（）]*)）|\(([^()]*)\)")


def _layer_member_weights(
        text: str, weights: dict[str, int]) -> dict[str, int]:
    """层成员 → 权重:首个出现的十神(层领衔)+ 干净括号列举的十神。

    括号「干净」= 内容按分隔符拆分后**全部**是十神名(全神列举才是成员
    声明;「(权重 2,被七杀压制)」「(并列最重)」这类混排括号不是)。
    句中其余顺带提及(压制者/对照)不算成员——见 check docstring。
    """
    members: dict[str, int] = {}
    first_pos: int | None = None
    for god in _TEN_GOD_NAMES:
        if god not in weights:
            continue
        pos = text.find(god)
        if pos < 0:
            continue
        if first_pos is None or pos < first_pos:
            first_pos = pos
    if first_pos is not None:
        for god in _TEN_GOD_NAMES:
            if god in weights and text.find(god) == first_pos:
                members[god] = weights[god]
                break
    for m in _PAREN_ANY_RE.finditer(text):
        inside = m.group(1) if m.group(1) is not None else m.group(2)
        # token 容忍首尾空白(LLM 顿号后带空格的排版,2026-10-13 三查第 3 轮):
        # 去空白后是神名的 token 语义上就是该神,不strip 会把整列按混排丢弃
        tokens = [t for t in
                  (tok.strip() for tok in _PAREN_ENUM_SPLIT_RE.split(inside)) if t]
        if tokens and all(t in _TEN_GOD_NAMES for t in tokens):
            for god in tokens:
                if god in weights:
                    members[god] = weights[god]
    return members


def check_layering_consistency(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """A3 分层与权重一致:dominant/latent 两层的强度序不得倒挂。

    两条:①并列最高的十神不得出现在 latent(真机翻车:七杀 6 = 劫财 6,
    劫财被塞进「潜伏」层);②dominant 层的强度代表 ≥ latent 层的强度代表。

    层成员判定(2026-10-13 review 修复,原实现取句内**全部**提及十神):
    v7 起三层是带依据的长句,句中顺带提及的其他十神是叙事不是成员——
    「伤官权重 2……被七杀与劫财的强势压住」里七杀/劫财是压制者,照旧
    判会把它们当成潜伏层成员,误报「并列最重落 latent」。收紧为:
    **首个出现的十神(层领衔)+ 干净括号列举**(括号内按 、/，/与/和 拆分
    后全是十神名才算成员列举,「财星组(偏财、劫财)」式真列举仍抓)。
    顺带提及(与/顿号连的叙事、「被 X 压住」的压制者)不再算成员——
    宁可漏报。十神名提取不到(EN 输出等)跳过不判。
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
    dom_weights = _layer_member_weights(dominant, weights)
    lat_weights = _layer_member_weights(latent, weights)
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


# ---------- 7. M0 白话结论层(2026-10-14 v9 批 S2) ----------
#
# 来源:用户真机截图(v7 输出,癸酉乙卯辛丑戊戌盘)P1-P8 + plan
# docs/命书M0白话结论层-plan.md。四项 m0-gated fail 检查(立场同前:
# 宁可漏报)+ 一项只统计不判 fail 的禁用词 warn 收集器(词表会误伤,
# 先观察分布,见 collect_banned_register_warnings docstring)。

# 十神五类统称(结论层禁用;与 _TEN_GOD_FAMILY 值集同源)
_TEN_GOD_FAMILY_NAMES: tuple[str, ...] = (
    "比劫", "食伤", "财星", "官杀", "印星",
)
# 作十神简称用的单字:只在 structure_type.name 判(其他 headline 里
# 「财」等单字可能是日常用词,宁可漏报——plan S2-1 拍板口径)
_TG_SINGLE_CHAR_SHORTHAND: tuple[str, ...] = ("印", "财", "官", "杀")
# 干支引用形态:2026-10-14 v9 样本盘实跑实踩 leak 写「丁未」「壬水」
# 「庚金、戌土」(干支+五行注记也是引用具体字);2026-10-16 v10 改
# **接地匹配**(plan S2-1):静态正则匹配任意干支相邻字,把 5 句日常
# 中文全部误报(「自己未必」=己未 /「自己水平」=己水 /「自己金钱」=己金 /
# 「自己土气」=己土 /「一下子火了」=子火)。改为只匹配**本盘实际存在**
# 的形态——
# - 干支对:四柱 gan_zhi + 大运每步 gan_zhi(「乙卯」不在本盘就不判)
# - 「干/支+五行」注记:只收本身五行正确的组合(庚金/壬水/午火/戌土…),
#   字取自上述干支;「自己水平」的「己水」五行不对(己属土),天然不命中
# - 「自己」豁免:「己」开头的匹配且前一字符是「自」(反身代词)跳过
# 已知漏报(接受):盘里不存在的干支(纯编造)在括注以外不被这项检查
# 抓到,plan S4 另立项。
_GAN_STEMS = "甲乙丙丁戊己庚辛壬癸"
_GAN_ELEMENTS = {"甲": "木", "乙": "木", "丙": "火", "丁": "火", "戊": "土",
                 "己": "土", "庚": "金", "辛": "金", "壬": "水", "癸": "水"}
_ZHI_BRANCHES = "子丑寅卯辰巳午未申酉戌亥"
_ZHI_ELEMENTS = {"子": "水", "丑": "土", "寅": "木", "卯": "木", "辰": "土",
                 "巳": "火", "午": "火", "未": "土", "申": "金", "酉": "金",
                 "戌": "土", "亥": "水"}


def _citable_ganzhi_forms(engine_result: dict[str, Any]) -> tuple[str, ...]:
    """本盘可引用干支形态集(排序保稳定):四柱+大运的干支对,与取自
    这些字的五行正确注记。pillars/luck_pillars 缺失 → 空集(调用方跳过
    干支判定,宁可漏报)。day/hour 可为 None(时辰未知),非 dict 跳过。"""
    forms: set[str] = set()
    pillars = engine_result.get("pillars")
    if isinstance(pillars, dict):
        for pillar in pillars.values():
            if not isinstance(pillar, dict):
                continue
            gz = pillar.get("gan_zhi") or ""
            if len(gz) == 2:
                forms.add(gz)
            gan, zhi = pillar.get("gan"), pillar.get("zhi")
            if gan in _GAN_ELEMENTS:
                forms.add(gan + _GAN_ELEMENTS[gan])
            if zhi in _ZHI_ELEMENTS:
                forms.add(zhi + _ZHI_ELEMENTS[zhi])
    for pillar in engine_result.get("luck_pillars") or []:
        if not isinstance(pillar, dict):
            continue
        gz = pillar.get("gan_zhi") or ""
        if len(gz) == 2:
            forms.add(gz)
            if gz[0] in _GAN_ELEMENTS:
                forms.add(gz[0] + _GAN_ELEMENTS[gz[0]])
            if gz[1] in _ZHI_ELEMENTS:
                forms.add(gz[1] + _ZHI_ELEMENTS[gz[1]])
    return tuple(sorted(forms))


def _find_ganzhi_citations(
        value: str, forms: tuple[str, ...],
        exempt_spans: tuple[tuple[int, int], ...] = ()) -> list[str]:
    """value 中命中的本盘可引用干支形态(每形态报首个命中)。

    「自己」豁免:「己」开头且前一字符是「自」跳过(反身代词,本盘带
    己时「自己土气/自己未必」不误判)。exempt_spans 内的命中跳过
    (合法大运括注,见 _check_luck_notes)。"""
    hits: list[str] = []
    for form in forms:
        idx = value.find(form)
        while idx >= 0:
            end = idx + len(form)
            in_exempt = any(s <= idx and end <= e
                            for s, e in exempt_spans)
            is_ziji = (form[0] == "己" and idx > 0
                       and value[idx - 1] == "自")
            if not in_exempt and not is_ziji:
                hits.append(form)
                break
            idx = value.find(form, idx + 1)
    return hits


# v10 大运括注:「约 X 岁起的那十年(某某运)」——展开层干支的唯一合法
# 落点(S1 放宽)。数字支持半角/全角阿拉伯与中文(「约四十六岁」样本
# 实见);括号半角/全角;「约」可省;岁/运兼容繁体(歲/運,zh-hant 是
# 一等输出语言,合规繁体括注不得误报)。中文年龄只解析 ≤99(起运岁数
# 上限)。
_LUCK_NOTE_RE = re.compile(
    r"约?\s*([0-9０-９]+|[一二两三四五六七八九十]{1,3})\s*[岁歲]起的那十年"
    rf"\s*[（(]\s*([{_GAN_STEMS}][{_ZHI_BRANCHES}])\s*[运運]\s*[)）]")
_FW_DIGIT_TABLE = str.maketrans("０１２３４５６７８９", "0123456789")
_CN_DIGIT_MAP = {"一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                 "六": 6, "七": 7, "八": 8, "九": 9}


def _parse_cn_age(raw: str) -> int | None:
    """中文数字年龄(1-99)→ int;超出解析能力返回 None(调用方按
    「岁数对不上」处理)。覆盖 单字(一~九)/十/几十/十几/几十几
    (起运岁数域,大运最早 1 岁级故单字也收,如「约五岁」)。

    样本实跑实踩(2026-10-16):「十几」类 tens_raw 为空串,初版长度
    判 `len(tens_raw) != 1` 把「十五」整个拒成 None →「约十五岁起的那
    十年(癸卯运)」癸卯恰是 15 岁运,被误报「岁数对不上」。空串=
    十位省略(合法),只拒多字符。"""
    if raw == "十":
        return 10
    if "十" in raw:
        tens_raw, _, ones_raw = raw.partition("十")
        if len(tens_raw) > 1 or len(ones_raw) > 1:
            return None
        tens = _CN_DIGIT_MAP.get(tens_raw, 0) if tens_raw else 1
        ones = _CN_DIGIT_MAP.get(ones_raw, 0) if ones_raw else 0
        if (tens_raw and tens == 0) or (ones_raw and ones == 0):
            return None
        return tens * 10 + ones
    return _CN_DIGIT_MAP.get(raw) if len(raw) == 1 else None


def _check_luck_notes(
        value: str,
        engine_result: dict[str, Any]) -> tuple[list[str], list[tuple[int, int]]]:
    """括注岁数对账(plan S2-1.4,只用于展开层):「约 N 岁起的那十年
    (XX运)」——XX 必须是 luck_pillars 里实际存在的干支,且该步
    start_age == N。返回 (violations, 合法括注的 span 列表)。

    XX 不在 luck_pillars → fail 编造大运干支;在但岁数不符(或中文
    年龄无法解析)→ fail 岁数对不上;完全对上 → 该 span 豁免干支判定。
    非干支形态的括号内容不匹配本正则(漏报接受)。"""
    violations: list[str] = []
    exempt: list[tuple[int, int]] = []
    ages: dict[str, int | None] = {}
    for pillar in engine_result.get("luck_pillars") or []:
        if isinstance(pillar, dict) and pillar.get("gan_zhi"):
            ages[pillar["gan_zhi"]] = pillar.get("start_age")
    for m in _LUCK_NOTE_RE.finditer(value):
        raw_age, gz = m.group(1), m.group(2)
        if raw_age[0].isdigit():
            age: int | None = int(raw_age.translate(_FW_DIGIT_TABLE))
        else:
            age = _parse_cn_age(raw_age)
        if gz not in ages:
            violations.append(
                f"编造大运干支:括注「{gz}运」不在本盘大运里"
                f"(干支必须引用输入实际存在的那步,原文:{_clip(value)!r})")
        elif age != ages[gz]:
            violations.append(
                f"大运岁数与干支对不上:「{gz}运」起运 {ages[gz]} 岁,"
                f"写了约 {raw_age} 岁(括注须同一步干支对得上;"
                f"原文:{_clip(value)!r})")
        else:
            exempt.append(m.span())
    return violations, exempt


# 阿拉伯数字(半角 + 全角,全角也是阿拉伯数字的排版变体)
_ARABIC_DIGIT_RE = re.compile(r"[0-9０-９]")
# 年龄豁免(岁兼容繁体歲,zh-hant 输出的年龄数字同样只进 leak)
_AGE_RE = re.compile(r"[0-9０-９]+\s*[岁歲]")

# v9 结论层字段(路径, 是否判单字简称)
_V9_HEADLINE_FIELDS: tuple[tuple[tuple[str, ...], bool], ...] = (
    (("main_axis", "headline"), False),
    (("core_loop", "headline"), False),
    (("capability_source", "headline"), False),
    (("structure_type", "name"), True),
)
# v9 展开层字段
_V9_EXPANSION_FIELDS: tuple[tuple[str, ...], ...] = (
    ("main_axis", "body"),
    ("core_loop", "flow"),
    ("core_loop", "leak"),
    ("structure_type", "one_line"),
    ("capability_source", "text"),
)


def _resolve_field(parsed_output: dict[str, Any],
                   path: tuple[str, ...]) -> Any:
    node: Any = parsed_output
    for key in path:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


def check_headline_plain_language(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """v9-1 结论层无术语:headline 与 structure_type.name 不含十神名及
    简称、干支组合、数字;字段缺失或非字符串即 fail(v9 三层契约)。

    真机截图正例(v7 输出):name「印财对峙、食伤通关型」——无「格」字
    绕过 A1,但印/财/食伤全是十神语(P2);headline 若带「偏财重 8」
    同时踩术语+数字(P1)。单字简称只在 name 判,理由见
    _TG_SINGLE_CHAR_SHORTHAND 注释。

    v10:干支改接地匹配(_citable_ganzhi_forms,只认本盘四柱/大运实际
    存在的形态);**结论层不享受大运括注豁免**——括注也是干支(plan
    S2-1.5,headline/name 禁任何干支包括括注)。空集(引擎缺
    pillars/luck_pillars)跳过干支判定。
    """
    if module != "m0_structure":
        return []
    failures: list[str] = []
    forms = _citable_ganzhi_forms(engine_result)
    for path, judge_single in _V9_HEADLINE_FIELDS:
        label = ".".join(path)
        value = _resolve_field(parsed_output, path)
        if not isinstance(value, str) or not value.strip():
            failures.append(
                f"结论层缺失:{label} 须为非空字符串(v9 三层写法,"
                f"结论句是第一层)")
            continue
        hit_terms = [n for n in _TEN_GOD_NAMES if n in value]
        hit_terms += [n for n in _TEN_GOD_FAMILY_NAMES if n in value]
        if judge_single:
            hit_terms += [c for c in _TG_SINGLE_CHAR_SHORTHAND if c in value]
        if hit_terms:
            failures.append(
                f"结论层含术语:{label} 出现 {'、'.join(sorted(set(hit_terms)))}"
                f"(结论句不得出现十神名及简称,原文:{_clip(value)!r})"
            )
        if forms:
            hits = _find_ganzhi_citations(value, forms)
            if hits:
                failures.append(
                    f"结论层含干支:{label} 出现「{hits[0]}」"
                    f"(结论层禁任何干支,大运括注也不例外;"
                    f"原文:{_clip(value)!r})"
                )
        m = _ARABIC_DIGIT_RE.search(value)
        if m:
            failures.append(
                f"结论层含数字:{label} 出现「{m.group(0)}」"
                f"(数字只进据类字段,原文:{_clip(value)!r})"
            )
    return failures


def check_expansion_no_figures(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """v9-2 展开层无数字与干支:body/flow/leak/one_line/text 不含阿拉伯
    数字(「\\d+ 岁」豁免,大运写法「约 32 岁起的那十年」是唯一例外),
    也不含干支引用(干支+五行注记形态同判:「丁未」「壬水」「庚金、戌土」
    ——v9 样本盘实跑实踩)。

    v10 放宽大运括注(plan S1/S2-1):「约 N 岁起的那十年(XX运)」是
    展开层干支的**唯一合法落点**——先做岁数对账(_check_luck_notes:
    XX 须为本盘实际大运且 start_age==N,编造/错配即 fail),完全合法的
    括注 span 豁免干支判定;其余位置命中本盘可引用形态(_citable_
    ganzhi_forms 接地匹配,修「自己未必/自己水平/一下子火了」误报)
    即 fail。空集(引擎缺 pillars/luck_pillars)跳过干支判定。

    真机截图正例:body「偏财重 8,正财重 8」(P1)。字段缺失跳过不判
    (结论层缺失由 v9-1 报,这里不重复)。
    """
    if module != "m0_structure":
        return []
    failures: list[str] = []
    forms = _citable_ganzhi_forms(engine_result)
    for path in _V9_EXPANSION_FIELDS:
        value = _resolve_field(parsed_output, path)
        if not isinstance(value, str):
            continue
        stripped = _AGE_RE.sub("", value)
        m = _ARABIC_DIGIT_RE.search(stripped)
        if m:
            failures.append(
                f"展开层含数字:{'.'.join(path)} 出现「{m.group(0)}」"
                f"(权重/计数等数字只进据类字段,年龄除外;"
                f"原文:{_clip(value)!r})"
            )
        if not forms:
            continue
        note_failures, exempt = _check_luck_notes(value, engine_result)
        failures.extend(note_failures)
        hits = _find_ganzhi_citations(value, forms, tuple(exempt))
        if hits:
            failures.append(
                f"展开层含干支:{'.'.join(path)} 出现「{hits[0]}」"
                f"(干支只许出现在「约 X 岁起的那十年(某某运)」的括注里,"
                f"其余进 evidence;原文:{_clip(value)!r})"
            )
    return failures


# 「写缺」词与否定前瞻守卫(「不算缺失」类否定提及不算指控,宁可漏报)。
# 2026-10-16 v10 review 修复:「没有」从词表移除——review 实测 3 句全部
# 误报:「正财没有七杀那么重」(比较句)/「压力没有压垮你」(否定后面的
# 动词)/「伤官的锋芒没有用上」(藏而不用,不是缺)。中文「没有」多为
# 比较或否定动词,判据无法与缺失指控区分,按宁可漏报放弃;真缺失指控由
# 缺位/缺失/不存在 承担(「没有透出」守卫分支随之删除)。
_MISSING_WORDS: tuple[str, ...] = ("缺位", "缺失", "不存在")
_MISSING_NEGATION_BEFORE = ("不", "非", "未", "别")
_MISSING_WINDOW = 6  # 十神名/统称后多少字内算「说它缺」


def check_present_god_not_missing(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """v9-3 权重 >0 不得写缺(P7):同句内十神名或统称后 6 字出现
    「缺位/缺失/不存在」,而该十神(统称取类内权重之和)权重 >0
    → fail。违反 v7 ⑥「缺/藏/弱」三分法,真机截图正例:七杀 1(藏于
    戌)被写成「官杀系统整体缺位」。

    守卫:缺词前 2 字内有否定词(不算/非缺…)跳过——否定提及不是指控。
    「没有」不在词表(2026-10-16 v10:比较句/否定动词两用,判不了,
    宁可漏报,见 _MISSING_WORDS 注释)。权重为 0 写「缺」是合规措辞,
    不判。
    """
    if module != "m0_structure":
        return []
    weights = engine_result["ten_god_weights"]
    family_weights: dict[str, int] = {}
    for god, family in _TEN_GOD_FAMILY.items():
        family_weights[family] = (
            family_weights.get(family, 0) + weights.get(god, 0))
    failures: list[str] = []
    for leaf in _iter_text_leaves(parsed_output):
        for sentence in _iter_sentences(leaf):
            for name in _TEN_GOD_NAMES + _TEN_GOD_FAMILY_NAMES:
                weight = (weights.get(name, 0) if name in _TEN_GOD_NAMES
                          else family_weights.get(name, 0))
                if weight <= 0:
                    continue
                start = 0
                while True:
                    idx = sentence.find(name, start)
                    if idx < 0:
                        break
                    start = idx + len(name)
                    window = sentence[start:start + _MISSING_WINDOW]
                    for word in _MISSING_WORDS:
                        pos = window.find(word)
                        if pos < 0:
                            continue
                        word_at = start + pos
                        before = sentence[max(0, word_at - 2):word_at]
                        if any(n in before for n in _MISSING_NEGATION_BEFORE):
                            continue
                        failures.append(
                            f"权重>0写缺:「{name}」权重 {weight}>0,"
                            f"却写「{word}」(权重>0 只能写 藏/弱,"
                            f"原文:{_clip(sentence)!r})"
                        )
    return failures


def check_example_plagiarism(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """v9-5 照抄示例:输出任一叶子字符串含 M0_V9_EXAMPLE_PHRASES 短语
    → fail。真机截图正例:「先做出能跑的版本」照搬共享 header 的 ✓
    示例(P5)。清单在模板旁(prompts.py),模板改示例时同步改。"""
    if module != "m0_structure":
        return []
    failures: list[str] = []
    for leaf in _iter_text_leaves(parsed_output):
        for phrase in M0_V9_EXAMPLE_PHRASES:
            if phrase in leaf:
                failures.append(
                    f"照抄示例:输出含示例短语「{phrase}」"
                    f"(示例只演示写法,不得复用;原文:{_clip(leaf)!r})"
                )
    return failures


def check_no_literal_newline_escape(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """v11 换行转义双写防护(2026-10-21 review,判 fail):任何输出字符串
    叶子出现**字面**反斜杠+n 两字符 → fail。模型把 JSON 转义多写一层时,
    "\\\\n" 解析后落成字面两字符——iOS 渲染层不拆段且正文直接显示「\\n」
    (本轮 glm 全量 0 命中;换模型/换供应商的风险面,evalkit 先拦)。漏写
    转义(字符串里真回车)解析层就炸(JSON 解析失败判据已有),与本条
    合起来双写/漏写两向都有守。"""
    failures: list[str] = []
    for leaf in _iter_text_leaves(parsed_output):
        if "\\n" in leaf:
            failures.append(
                f"换行转义双写:输出含字面「\\n」两字符(应写单个换行,"
                f"渲染层才能拆段;原文:{_clip(leaf)!r})"
            )
    return failures


# 工程腔禁用词(P4):只统计不判 fail——词表会误伤(如「巩固」偶有日常
# 义),先观察分布再定是否升级为 fail(plan S2-4 拍板)。runner 把命中
# 写进 l2.warnings 进 run 报告,不进 failures、不影响 verdict。
_BANNED_REGISTER_WORDS: tuple[str, ...] = (
    "通道", "链条", "输出链", "环节", "转换层", "输出端", "吸收端",
    "这一段", "那一段", "承载", "权柄", "泄漏", "流失", "巩固", "咽喉",
    "缺位", "对峙", "通关",
)


def collect_banned_register_warnings(
    module: str,
    parsed_output: dict[str, Any],
) -> list[str]:
    """v9-4 工程腔禁用词统计(不进 failures):扫结论层+展开层字段,
    命中词写成 warning 字符串。L2 检查接口只返回 failures,本函数是
    显式的旁路通道,由 runner 并入 l2.warnings。"""
    if module != "m0_structure":
        return []
    warnings: list[str] = []
    headline_paths = [path for path, _ in _V9_HEADLINE_FIELDS]
    for path in headline_paths + list(_V9_EXPANSION_FIELDS):
        value = _resolve_field(parsed_output, path)
        if not isinstance(value, str):
            continue
        hits = sorted({w for w in _BANNED_REGISTER_WORDS if w in value})
        if hits:
            warnings.append(
                f"工程腔词:{'.'.join(path)} 出现 {'、'.join(hits)}")
    return warnings


def collect_leak_paragraph_warnings(
    module: str,
    parsed_output: dict[str, Any],
) -> list[str]:
    """v11 leak 三段化统计(不进 failures,plan 命书阅读页段落排版A′ S2-5):
    core_loop.leak 按换行拆段后应恰好 3 段非空段(代价/何时会变/现在怎么
    做)。先观察分布(模型对「\\n 分隔」的依从率),不进 verdict——同
    collect_banned_register_warnings 的旁路通道,由 runner 并入
    l2.warnings。v10 及更早的输出(单段 leak)也会命中本 warning,属
    预期(判据按当前模板口径统计,不回溯豁免旧版本)。"""
    if module != "m0_structure":
        return []
    leak = _resolve_field(parsed_output, ("core_loop", "leak"))
    if not isinstance(leak, str):
        return []
    paragraphs = [p.strip() for p in leak.split("\n") if p.strip()]
    if len(paragraphs) != 3:
        return [
            f"leak 段数:{len(paragraphs)} 段"
            f"(v11 期望恰好 3 段非空段,\\n 分隔)"
        ]
    return []


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
    failures += check_headline_plain_language(
        module, parsed_output, engine_result)
    failures += check_expansion_no_figures(
        module, parsed_output, engine_result)
    failures += check_present_god_not_missing(
        module, parsed_output, engine_result)
    failures += check_example_plagiarism(
        module, parsed_output, engine_result)
    failures += check_no_literal_newline_escape(
        module, parsed_output, engine_result)
    return failures
