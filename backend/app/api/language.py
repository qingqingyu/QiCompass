"""请求语言解析层(i18n 决策 2:方案 4 双 header 混合)。

策略:
1. 优先读 `X-QiCompass-Lang` header(产品显式覆盖,App 内语言切换用,D6)
2. Fallback 读标准 `Accept-Language` header(系统偏好,iOS URLSession 自动带)
3. 都没有或都未注册 → 默认 `zh`

语言规范化(D3,全小写 wire 格式):
- `zh-Hans-CN,zh;q=0.9` → `zh`
- `zh-Hant-TW,zh;q=0.9` → `zh-hant`
- `en-US,en;q=0.8` → `en`
- `ja-JP` → 暂未注册 → fallback `zh`

zh 变体解析(D4,i18n-zh-hant-plan.md):primary tag = `zh` 时看子 tag
(script 优先,再看 region)决定简繁,Accept-Language 与 X-QiCompass-Lang
都过同一逻辑——繁体系统用户零操作自动拿繁体:
- `zh-Hant` / `zh-Hant-TW` / `zh-TW` / `zh-HK` / `zh-MO` → `zh-hant`
- `zh-Hans` / `zh-CN` / `zh-SG` / 裸 `zh` → `zh`

严格使用 `is_language_supported` 判断,避免 Accept-Language 携带未注册语言时
静默走 en 分支。

i18n 决策 9 的事实源:`backend/app/engine/term_translations.py` 的 TERM_TRANSLATIONS
注册表决定"已支持"集合。
"""

from __future__ import annotations

import logging
from typing import Final

from fastapi import Request

from ..engine.term_translations import is_language_supported

logger = logging.getLogger(__name__)

DEFAULT_LANGUAGE: Final[str] = "zh"

# zh 变体 → 繁体的 script/region 子 tag(D4;script 4 字母,region 2 字母,
# 同层判断不区分长短,只要命中即繁体)
_ZH_HANT_SUBTAGS: Final[frozenset[str]] = frozenset({"hant", "tw", "hk", "mo"})


def resolve_language(request: Request) -> str:
    """从 HTTP 请求解析目标语言。

    解析顺序:
    1. `X-QiCompass-Lang` header(若存在且可解析到已注册语言)
    2. `Accept-Language` header 第一段完整 tag(若可解析到已注册语言)
    3. fallback `DEFAULT_LANGUAGE`("zh")

    Args:
        request: FastAPI Request(读 headers)

    Returns:
        规范化的语言代码("zh" / "zh-hant" / "en",未来扩展 "ja" / "es")

    Notes:
        - 不抛错(语言解析是 best-effort,header 缺失或未注册语言都走默认)
        - 但会在 logger.debug 留痕,便于排查"为什么用户拿到中文而非英文"
    """
    # 1. 优先读 X-QiCompass-Lang(App 内语言切换用;iOS 按 D6 发规范化值,
    #    但同样过 _match_language 的 zh 变体解析——header 写 zh-TW 也归 zh-hant)
    override = request.headers.get("x-qicompass-lang")
    if override:
        matched = _match_language(override.strip())
        if matched is not None and is_language_supported(matched):
            return matched
        # 显式覆盖但未注册 → 不静默 fallback,记录后继续尝试 Accept-Language
        logger.debug(
            "resolve_language.override_unregistered override=%r"
            "(继续尝试 Accept-Language)",
            override,
        )

    # 2. Fallback 读 Accept-Language(标准 HTTP,iOS URLSession 默认带)
    accept = request.headers.get("accept-language")
    if accept:
        tag = _extract_first_tag(accept)
        if tag:
            matched = _match_language(tag)
            if matched is not None and is_language_supported(matched):
                return matched
            logger.debug(
                "resolve_language.accept_unregistered tag=%r(继续 fallback 默认)",
                tag,
            )

    # 3. 默认 zh
    return DEFAULT_LANGUAGE


def _extract_first_tag(accept_language: str) -> str | None:
    """从 Accept-Language header 提取第一段的完整 tag(含子 tag)。

    例子:
    - "zh-Hans-CN,zh;q=0.9,en;q=0.8" → "zh-Hans-CN"
    - "en-US,en;q=0.8" → "en-US"
    - "zh-Hant-TW" → "zh-Hant-TW"(D4:子 tag 交给 _match_language 判简繁)
    - "" → None

    规范化规则:
    - 取逗号分隔的第一段
    - 去掉分号质量参数(q=0.9)
    - 保留完整 tag(primary + script + region),strip 首尾空白

    不依赖 babel/gettext 标准库,避免引入新依赖(CLAUDE.md 全局约束)。
    """
    if not accept_language:
        return None
    # 取第一段(逗号分隔)
    first_segment = accept_language.split(",")[0].strip()
    if not first_segment:
        return None
    # 去掉质量参数("en-US;q=0.8" → "en-US")
    tag = first_segment.split(";")[0].strip()
    return tag if tag else None


def _match_language(tag: str) -> str | None:
    """完整 BCP47-ish tag → 已注册语言代码;未注册返回 None。

    zh 变体解析(D4):primary = zh 时,任一子 tag 命中繁体集合
    (hant / tw / hk / mo)→ "zh-hant";hans / cn / sg / 裸 zh 及未知
    region → "zh"(简体为默认侧,未知 region 不猜繁体)。
    en 的任何 region 变体 → "en"。其余 primary(ja / fr / …)→ None,
    由调用方决定 fallback(不静默映射)。

    例子:
    - "zh" → "zh";"zh-CN" → "zh";"zh-Hans" → "zh"
    - "zh-Hant" → "zh-hant";"zh-TW" → "zh-hant";"zh-Hant-HK" → "zh-hant"
    - "zh-hant" → "zh-hant"(大小写不敏感)
    - "en-US" → "en";"en" → "en"
    - "ja-JP" → None;"fr" → None
    """
    subtags = [s for s in tag.lower().split("-") if s]
    if not subtags:
        return None
    primary = subtags[0]
    if primary == "zh":
        if any(s in _ZH_HANT_SUBTAGS for s in subtags[1:]):
            return "zh-hant"
        return "zh"
    if primary == "en":
        return "en"
    return None
