"""L2 接地校验层(不花钱,本系列价值核心)。

把"LLM 编造了后端没给的东西"从"要靠裁判读出来"变成"机器直接判死"。
五个纯函数,统一签名 (module, parsed_output, engine_result) -> list[str],
只读入参不做 IO——这是它们能被大量单测覆盖的前提。

关于误报的立场(宁可漏报,不可误报):
- 模式匹配一律保守:证据不足就不判(歧义句跳过、信号词与五行必须
  近距共现、"泄/克"类有方向歧义的关系动词不启用、非五行复合词
  二次否决——金融/土地/火车这类日常词里的五行字不算五行义)
- 每条 failure 自带命中原文片段 + 冲突的 ground truth 值,可在 UI 人工复核
- 首轮基线(S06)后人工复核全部 L2 failure;误报优先收紧模式

对齐:ADR-0004(喜忌确定性)/ 0005(神煞 20 固定清单)/ 0006(格局砍掉
模糊叙事)/ 0007(从格诚实降级)。
"""

from __future__ import annotations

import re
from difflib import SequenceMatcher
from typing import Any, Iterator

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


_SENTENCE_SPLIT = re.compile(r"[。!?!?;;\n\r]")


def _iter_sentences(text: str) -> list[str]:
    """切句:推荐/规避判定只在句内做,跨句不判。"""
    return [s for s in _SENTENCE_SPLIT.split(text) if s.strip()]


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
    "水": ("薪",),                      # 薪水
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
        pattern = rf"{_signal_regex(sig)}.{{0,2}}{re.escape(element_zh)}"
        for m in re.finditer(pattern, sentence):
            if not _is_non_wuxing_compound(sentence, m.end() - 1, element_zh):
                hits.append(m.group(0))
    for sig in _RECO_SIGNALS_LAST:
        pattern = rf"{re.escape(element_zh)}.{{0,2}}{_signal_regex(sig)}"
        for m in re.finditer(pattern, sentence):
            if not _is_non_wuxing_compound(sentence, m.start(), element_zh):
                hits.append(m.group(0))
    return hits


def _avoid_hits(sentence: str, element_zh: str) -> list[str]:
    """句内"规避某五行"的命中模式(同样过复合词二次否决)。"""
    hits: list[str] = []
    for sig in _AVOID_SIGNALS_FIRST:
        pattern = rf"{_signal_regex(sig)}.{{0,2}}{re.escape(element_zh)}"
        for m in re.finditer(pattern, sentence):
            if not _is_non_wuxing_compound(sentence, m.end() - 1, element_zh):
                hits.append(m.group(0))
    for sig in _AVOID_SIGNALS_LAST:
        pattern = rf"{re.escape(element_zh)}.{{0,2}}{_signal_regex(sig)}"
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


def check_no_hard_geju(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
) -> list[str]:
    """硬性格局分类是红线(ADR-0006),命中即 fail,不打分。

    只扫"××格"整词;单独的"格局"二字是允许的中性表述。
    """
    failures: list[str] = []
    for leaf in _iter_text_leaves(parsed_output):
        for word in _HARD_GEJU_WORDS:
            if word in leaf:
                failures.append(
                    f"硬性格局:文本出现「{word}」(只准「命局呈现××倾向」"
                    f"模糊叙事,原文:{_clip(leaf)!r})"
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


# ---------- 聚合入口 ----------

def check_grounding(
    module: str,
    parsed_output: dict[str, Any],
    engine_result: dict[str, Any],
    chain_context: dict[str, Any] | None = None,
) -> list[str]:
    """L2 聚合:顺序跑五项并合并 failures(空 = 全过)。"""
    failures: list[str] = []
    failures += check_xiji_consistency(module, parsed_output, engine_result)
    failures += check_shensha_bounded(module, parsed_output, engine_result)
    failures += check_no_hard_geju(module, parsed_output, engine_result)
    failures += check_special_pattern_honesty(module, parsed_output, engine_result)
    failures += check_chain_consistency(
        module, parsed_output, engine_result, chain_context=chain_context)
    return failures
