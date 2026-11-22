"""禁词守卫(Python 版,与客户端 ForbiddenWords 同步)。

设计理由(D10):**不做文本替换**,替换会掩盖 AI 故障,违反"错误显式传播"。
命中即拦截 + 日志 + 错误态,不返回文本。

与客户端 `ios/.../Services/CompatibilityOrchestrator.swift:ForbiddenWords` 保持词表同步。
演化时两边一起改(词表 / 扫描逻辑)。

US-COMP-04 验收标准 4:后端拦截"百分百/一定"等绝对化用语。
客户端保留二次扫描作防御性兜底,但后端是最终防线(客户端可被绕过)。
"""

from __future__ import annotations

import logging
import re

from ..errors import InterpretationForbiddenError

logger = logging.getLogger(__name__)

# 禁词清单:绝对结论类。LLM 必须用"倾向 / 较易 / 较难"等模糊叙事。
# 与客户端 ForbiddenWords.absoluteConclusions 保持一致。
# T9(2026-11-22 竞品差评对照):补繁体形(zh-Hant 输出的「一定會/絕對」等
# 此前不拦截)。review 发现任务书「其余词简繁同形」前提对 必破财 不成立
# (繁体作「必破財」),按任务意图一并补列(缓存全量扫描 0 命中,零翻转风险);
# 「註定」(台湾偶见异写,LLM 跟随概率低)未列,留拍板。
ABSOLUTE_CONCLUSIONS: list[str] = [
    "必成", "必分", "必破财", "必定", "一定会", "一定不会",
    "必然", "绝对", "百分之百", "铁定", "注定",
    "一定會", "一定不會", "鐵定", "絕對", "必破財", "註定",
]

# D2(2026-11-22 拍板「上,先测误杀率」):英文绝对结论短语,整词匹配
# (大小写不敏感,空格弹性 \s+)——中文式子串匹配对英文会误杀("will" 命中
# "willing")。误杀率已实测:evalkit en 全量输出 + 本地缓存 0 命中 0 误杀。
# 与客户端 ForbiddenWords.absoluteEnglishPhrases 保持一致。
ABSOLUTE_ENGLISH_PHRASES: list[str] = [
    "destined to", "doomed", "guaranteed to", "will definitely",
    "will certainly", "without a doubt", "100%",
]

# 英文短语预编译正则(模块级一次编译;词边界防误杀;空格弹性 \s+;分词
# re.escape——未来短语含正则元字符也不会改变语义,转义后恒可编译;
# 镜像 iOS 侧 escapedPattern(for:) 的逐词转义)。纯符号项("100%")
# 无词边界语义,单独走字面子串。
_EN_PHRASE_PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (
        p_,
        re.compile(
            r"\b" + r"\s+".join(re.escape(chunk) for chunk in p_.split(" ")) + r"\b",
            re.IGNORECASE,
        ),
    )
    for p_ in ABSOLUTE_ENGLISH_PHRASES if any(c.isalpha() for c in p_)
]
_EN_SUBSTRING_PHRASES: list[str] = [
    p_ for p_ in ABSOLUTE_ENGLISH_PHRASES if not any(c.isalpha() for c in p_)
]


def scan(text: str) -> list[str]:
    """扫描文本,返回所有命中禁词(去重保序)。

    空列表 = 通过;非空 = 拦截。

    与客户端 ForbiddenWords.scan 逻辑一致:中文词简单 `in` 检查;
    英文短语(D2)整词正则匹配(词边界防误杀)。
    """
    hits: list[str] = []
    for word in ABSOLUTE_CONCLUSIONS:
        if word in text and word not in hits:
            hits.append(word)
    # 英文短语:整词匹配(词边界防误杀,"willing" 不命中任何词表项);
    # 纯符号项("100%")无词边界语义,子串匹配。命中返回原词表串。
    for phrase, pattern in _EN_PHRASE_PATTERNS:
        if phrase not in hits and pattern.search(text):
            hits.append(phrase)
    for phrase in _EN_SUBSTRING_PHRASES:
        if phrase not in hits and phrase in text:
            hits.append(phrase)
    return hits


def validate_interpretation(
    text: str,
    *,
    request_id: str | None = None,
    content_hash: str | None = None,
    log_ctx: dict | None = None,
) -> None:
    """扫描文本,命中禁词则 raise InterpretationForbiddenError。

    纯逻辑(只读 text + 写日志 + raise),无 HTTP/缓存副作用。
    用于 interpret.py 两处禁词检查(缓存命中后 + provider 返回后)。

    可独立单元测试:``validate_interpretation("注定分手")`` → assert raises。
    """
    hits = scan(text)
    if hits:
        if log_ctx:
            logger.warning("forbidden_words.validate hits=%s %s", hits, log_ctx)
        raise InterpretationForbiddenError(
            f"AI 解读包含禁词,已拦截(命中: {', '.join(hits)})",
            request_id=request_id,
            content_hash=content_hash,
        )
