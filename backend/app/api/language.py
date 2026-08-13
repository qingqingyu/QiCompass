"""请求语言解析层(i18n 决策 2:方案 4 双 header 混合)。

策略:
1. 优先读 `X-QiCompass-Lang` header(产品显式覆盖,v2 App 内语言切换用)
2. Fallback 读标准 `Accept-Language` header(系统偏好,v1 由 iOS URLSession 自动带)
3. 都没有或都未注册 → 默认 `zh`

语言规范化:
- `zh-Hans-CN,zh;q=0.9` → `zh`
- `en-US,en;q=0.8` → `en`
- `ja-JP` → 暂未注册 → fallback `zh`(Slice 1 只支持 zh/en)

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


def resolve_language(request: Request) -> str:
    """从 HTTP 请求解析目标语言。

    解析顺序:
    1. `X-QiCompass-Lang` header(若存在且已注册)
    2. `Accept-Language` header 第一段 primary tag(若已注册)
    3. fallback `DEFAULT_LANGUAGE`("zh")

    Args:
        request: FastAPI Request(读 headers)

    Returns:
        规范化的语言代码("zh" / "en",未来扩展 "ja" / "es")

    Notes:
        - 不抛错(语言解析是 best-effort,header 缺失或未注册语言都走默认)
        - 但会在 logger.debug 留痕,便于排查"为什么用户拿到中文而非英文"
    """
    # 1. 优先读 X-QiCompass-Lang(v2 用,v1 阶段 iOS 不发)
    override = request.headers.get("x-qicompass-lang")
    if override:
        normalized = override.strip().lower()
        if is_language_supported(normalized):
            return normalized
        # 显式覆盖但未注册 → 不静默 fallback,记录后继续尝试 Accept-Language
        logger.debug(
            "resolve_language.override_unregistered override=%r normalized=%r"
            "(继续尝试 Accept-Language)",
            override, normalized,
        )

    # 2. Fallback 读 Accept-Language(标准 HTTP,iOS URLSession 默认带)
    accept = request.headers.get("accept-language")
    if accept:
        primary = _extract_primary_tag(accept)
        if primary and is_language_supported(primary):
            return primary
        if primary:
            logger.debug(
                "resolve_language.accept_unregistered primary=%r(继续 fallback 默认)",
                primary,
            )

    # 3. 默认 zh
    return DEFAULT_LANGUAGE


def _extract_primary_tag(accept_language: str) -> str | None:
    """从 Accept-Language header 提取并规范化 primary language tag。

    例子:
    - "zh-Hans-CN,zh;q=0.9,en;q=0.8" → "zh"
    - "en-US,en;q=0.8" → "en"
    - "ja-JP" → "ja"
    - "" → None
    - "fr-FR" → "fr"(调用方判断是否已注册)

    规范化规则:
    - 取逗号分隔的第一段
    - 去掉分号质量参数(q=0.9)
    - 取连字符分隔的第一段(primary tag)
    - 转小写

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
    if not tag:
        return None
    # 取 primary tag("en-US" → "en";"zh-Hans-CN" → "zh")
    primary = tag.split("-")[0].strip().lower()
    return primary if primary else None
