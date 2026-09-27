"""POST /api/interpret — AI 命书解读(三模块共用)。

流程(最终方案 §7):
1. 取 prompt_version = PROMPT_VERSIONS[req.module](后端配置,不从客户端读)
2. validate_context + render_prompt(纯 CPU,留 event loop),计算 prompt_hash
3. 查后端缓存(同步 → run_in_threadpool)
   命中 → 返回 InterpretResponse(cached=True)
   命中但 v1 坏 JSON(截断时代遗留)→ 删除中毒行后落穿重新生成(自愈,2026-09-27)
4. 调用选中的 AI provider(async httpx,直接 await,不走线程池)
4.4 v1 JSON 契约校验:M0-M7 输出必须完整 JSON 对象,否则 AIProviderError(503)
    不进禁词扫描、不写缓存、不返回(截断半截 JSON 一旦入缓存会被 iOS 当散文渲染)
5. 写缓存(同步 → run_in_threadpool)
6. 返回 InterpretResponse(cached=False)

线程池策略:
- validate_context + render_prompt 纯字符串操作,快,留在 event loop
- ai_client.interpret 走 async httpx 直接 await(不再占线程池,根除并发瓶颈)
- cache.get / cache.set 仍走 run_in_threadpool(SQLite 同步)
  不与 provider 调用合并:缓存命中时零 LLM 调用
- provider 调用失败时不写缓存(步骤 4 抛异常中断流程)

错误显式传播:
- provider 失败 → AIProviderError(503),不吞不返回假文本
- SQLite 失败 → InterpretationCacheError(500),不降级调用 provider
"""

from __future__ import annotations

import hashlib
import json
import logging
import re
import time
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Request
from starlette.concurrency import run_in_threadpool

from ..ai.cache import InterpretationCache
from ..ai.cache_key import CacheKey
from ..ai.forbidden_words import scan as scan_forbidden_words
from ..ai.forbidden_words import validate_interpretation
from ..ai.prompts import (
    COMPATIBILITY_MODULES,
    PROMPT_VERSIONS,
    render_prompt,
    validate_context,
)
from ..ai.singleflight import SingleflightCoalescer
from ..auth.dependencies import get_current_user_id
from ..config import resolve_temperature
from ..engine.term_translations import ChartJSONDecodeError, translate_context
from ..entitlement import EntitlementStore
from ..errors import (
    AIProviderError,
    BaziCalculationFailedError,
    EntitlementNotFoundError,
    InterpretationCacheError,
    InterpretationForbiddenError,
    InvalidInputError,
)
from ..models.interpret import (
    InterpretRequest,
    InterpretResponse,
    PAID_MODULES,
    V1_MODULES,
    V1_NEEDS_USER_INPUT,
    entitlement_base_module,
)
from .language import resolve_language

router = APIRouter()
logger = logging.getLogger(__name__)


def _hash_parent_fingerprint(fingerprint: str | None) -> str:
    """M0 structure_fingerprint → sha256 hex(作 CacheKey.parent_hash)。

    None / 空串 → 空串(M0 自身 + 老模块无 parent,缓存键维度退化为 8 维)。
    用于 v1 链式调用:M0 重算后 fingerprint 变,M1-M7 缓存自动隔离。
    """
    if not fingerprint:
        return ""
    return hashlib.sha256(fingerprint.encode("utf-8")).hexdigest()


def _hash_user_input(req: InterpretRequest) -> str:
    """M4/M5 用户输入 → sha256 hex(作 CacheKey.user_input_hash)。

    非 M4/M5 module → 空串(老模块 + M0-M3/M6/M7 无用户输入维度)。
    用于 v1 按需模块:同 chart 同 fingerprint 但不同用户输入,M4/M5 缓存隔离。

    schema 层 m4_health_requires_user_inputs / m5_wealth_requires_user_inputs
    已保证 M4/M5 时各字段非空。此处显式 invariant 校验:若 schema 校验后
    字段仍为 None 即代码 bug,RuntimeError 显式暴露比 f-string 静默产出
    "age=None|..." 污染 hash 更安全(对齐 CLAUDE.md 错误显式传播)。
    """
    if req.module not in V1_NEEDS_USER_INPUT:
        return ""
    if req.module == "m4_health":
        if req.m4_age is None or req.m4_current_concern is None:
            raise RuntimeError(
                f"_hash_user_input invariant violated: m4_health with "
                f"age={req.m4_age!r} concern={req.m4_current_concern!r} "
                f"(schema validator should have caught this)")
        payload = f"age={req.m4_age}|concern={req.m4_current_concern}"
    elif req.module == "m5_wealth":
        if req.m5_assets_summary is None or req.m5_preference is None:
            raise RuntimeError(
                f"_hash_user_input invariant violated: m5_wealth with "
                f"assets={req.m5_assets_summary!r} "
                f"preference={req.m5_preference!r} "
                f"(schema validator should have caught this)")
        payload = (
            f"assets={req.m5_assets_summary}"
            f"|preference={req.m5_preference}"
        )
    else:
        # V1_NEEDS_USER_INPUT 扩展时漏加 handler 会显式暴露,
        # 避免新 module 被静默当 m5_wealth 处理导致缓存隔离失效
        raise RuntimeError(
            f"_hash_user_input invariant violated: module={req.module!r} "
            f"in V1_NEEDS_USER_INPUT but no hash handler "
            f"(需在 _hash_user_input 加 elif 分支)")
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _strip_code_fences(text: str) -> str:
    """剥 LLM 违约附加的 ```json 围栏(prompt 已禁,防御性容忍)。

    精确镜像 iOS OrderedJSONParser.stripCodeFences 的算法:去 ```,
    再去语言标记(连续字母),再去空白/换行,最后剥末尾围栏。
    必须逐字符对齐而非「剥首行」:若后端比 iOS 宽(如 "``` json\\n{...}"
    围栏后带空格),后端会放行入缓存,而 iOS drop-letters 遇空格即停、
    留下 "json" 前缀 parse 失败 → 退散文 = 事故形态复发。校验层只能比
    渲染层严或同等,不能更宽。非围栏开头(正常契约输出)原样返回。
    """
    t = text.strip()
    if not t.startswith("```"):
        return t
    t = t[3:]
    i = 0
    while i < len(t) and t[i].isalpha():
        i += 1
    t = t[i:].lstrip()
    fence_end = t.rfind("```")
    if fence_end != -1:
        t = t[:fence_end]
    return t.strip()


def _is_renderable_top_level(value: object) -> bool:
    """顶层值是否可被 iOS ChapterContent.node 渲染(镜像其 nil 规则)。

    iOS 口径:string/number/bool → 节点;object → 恒成节;null → nil;
    array → 仅全 null / 空数组才 nil(arrayNode 的 nonNull 过滤)。
    校验层只能比渲染层严或同等,不能更宽(更宽 = 放行渲染层退散文的
    内容入缓存 = JSON 裸奔事故复发通道)。
    """
    if value is None:
        return False
    if isinstance(value, list):
        return any(item is not None for item in value)
    return True


def _validate_v1_module_json(module: str, interpretation: str) -> None:
    """v1 深度模块(M0-M7)输出契约 = 完整 JSON 对象(2026-09-27)。

    背景:真机 m1_talent 实证——LLM 输出在 max_tokens 截断 → 半截 JSON
    通过禁词扫描入缓存 → iOS ChapterContent.parse 失败退回散文,正文
    JSON 裸奔。此校验把「非合法 JSON」从「静默成功」改为显式 AIProviderError,
    截断/违约内容不写缓存、不返回。

    口径与 iOS 渲染层对齐:容忍围栏(剥后校验),顶层必须是对象
    (iOS `guard case .object` 同款),且至少一个顶层值可渲染
    (iOS `nodes.isEmpty → nil` 退散文的同款规则,空对象/全 null 同样拒绝)。

    Raises:
        AIProviderError: 非 JSON / 顶层非对象 / 顶层无可渲染值
            (疑似截断或违约)
    """
    if module not in V1_MODULES:
        return
    text = _strip_code_fences(interpretation)
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as e:
        raise AIProviderError(
            f"v1 模块 {module} 输出非合法 JSON(疑似 max_tokens 截断或"
            f"格式违约):{e}"
        ) from e
    if not isinstance(parsed, dict):
        raise AIProviderError(
            f"v1 模块 {module} 输出 JSON 顶层非对象"
            f"(type={type(parsed).__name__},契约要求对象)"
        )
    if not any(_is_renderable_top_level(v) for v in parsed.values()):
        raise AIProviderError(
            f"v1 模块 {module} 输出 JSON 顶层无可渲染值"
            f"(空对象或全 null,iOS 渲染层会退回散文导致 JSON 裸奔)"
        )


# ---------- 合盘后置处理(2026-09-27:名字化 + 干支接地观测)----------

# A/B 代号替换覆盖的 module(alias + M4 拆分;老 iOS alias 请求无名字 →
# setdefault 兜底 "A"/"B",替换退化为恒等,无害)。
# 单一事实源 = prompts.COMPATIBILITY_MODULES,与 render_prompt 名字兜底共用。
_COMPAT_POSTPROCESS_MODULES: frozenset[str] = COMPATIBILITY_MODULES

# standalone「A」/「B」:前后都不是 ASCII 字母数字(误伤 Amanda / H1B / A4 这类词
# ——测试实证:H1B 的 B 前是数字,只挡字母挡不住);
# 吞掉代号后的一个半角空格(「A 倾向于」→「你倾向于」,中文排版无残留空格)
_STANDALONE_A = re.compile(r"(?<![A-Za-z0-9])A\s?(?![A-Za-z0-9])")
_STANDALONE_B = re.compile(r"(?<![A-Za-z0-9])B\s?(?![A-Za-z0-9])")


def _replace_ab_labels(text: str, name_a: str, name_b: str) -> str:
    """合盘解读里残留的 A/B 代号 → 两人称呼(确定性替换,prompt 之外的兜底)。

    prompt v4 已要求全文用 name_a/name_b 称呼,但 LLM 违约时叙述里仍可能冒出
    「A 倾向于先说结论」。用户要求不只依赖 prompt,此处后置替换。

    跳过条件(防替换自伤):名字为空,或**名字本身含该字母的 standalone 出现**
    (`_STANDALONE_A.search(name_a)` 命中,如「A先生」「阿B」「小 A」——文本里
    出现名字本身时,其中的字母会被再替换成整个名字,产出「阿阿B」类捣碎)。
    名字内部的非 standalone 字母由环视天然保护:「Bella」/「Amy」的字母前后是
    拉丁字母,不命中 standalone,替换照常进行且注入结果安全。
    """
    if name_a and not _STANDALONE_A.search(name_a):
        # 函数式替换(lambda):repl 按字面使用——字符串 repl 会解析 \ 转义
        # (别名以 \ 结尾抛 re.error bad escape、\1/\g 错插组引用,用户输入
        # 可触发 interpret 500;lambda 返回值零转义解析,彻底字面化)
        text = _STANDALONE_A.sub(lambda m: name_a, text)
    if name_b and not _STANDALONE_B.search(name_b):
        text = _STANDALONE_B.sub(lambda m: name_b, text)
    return text


# 天干地支全集(干支接地观测用;与 engine/pillars.py 的表同源字符集)
_TIANGAN_CHARS = frozenset("甲乙丙丁戊己庚辛壬癸")
_DIZHI_CHARS = frozenset("子丑寅卯辰巳午未申酉戌亥")
_GANZHI_CHARS = _TIANGAN_CHARS | _DIZHI_CHARS

# 允许引用的干支来源字段:两人四柱 + 流年同步表(含大运/流年干支)
_COMPAT_GANZHI_SOURCE_FIELDS: tuple[str, ...] = (
    "year_a", "month_a", "day_a", "hour_a",
    "year_b", "month_b", "day_b", "hour_b",
    "synced_fortune_table",
)


def _log_offchart_ganzhi(
    interpretation: str, context: dict, log_ctx: dict,
) -> None:
    """观测:输出提及了输入数据里不存在的干支字符(prompt 接地违约信号)。

    **log-only 不拦截**(2026-09-27 拍板):「子时」「申金」等泛指说明也会
    命中字符集,硬拦误伤正常生成;先收集违规率,高频再谈强校验。
    """
    allowed: set[str] = set()
    for field in _COMPAT_GANZHI_SOURCE_FIELDS:
        value = context.get(field)
        if isinstance(value, str):
            allowed |= {c for c in value if c in _GANZHI_CHARS}
    mentioned = {c for c in interpretation if c in _GANZHI_CHARS}
    # 两人称呼已由 _replace_ab_labels 注入正文;名字里恰含干支字(如「陈寅」
    # 「丁一」)属称呼本身而非 LLM 引用盘外干支,从观测集合剔除防污染信号
    # (log-only 拍板不变,此处只提升违约率统计的准确性)。
    name_chars = {
        c for c in (context.get("name_a") or "") + (context.get("name_b") or "")
        if c in _GANZHI_CHARS
    }
    offchart = mentioned - name_chars - allowed
    if offchart:
        logger.warning(
            "interpret.compat_offchart_ganzhi %s offchart=%s "
            "(输出提及但两盘四柱/大运/流年中不存在的干支字符,"
            "prompt 接地违约观测,不拦截)",
            log_ctx, sorted(offchart),
        )


@router.post("/api/interpret", response_model=InterpretResponse)
async def interpret(
    req: InterpretRequest,
    request: Request,
    current_user_id: str | None = Depends(get_current_user_id),
) -> InterpretResponse:
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    # 1. 取 prompt_version(后端配置,不从客户端读)
    # v1 prompt 系统:m0-m7 module 在 Stage 5 才注册到 PROMPT_VERSIONS;
    # Stage 4 期间 m0-m7 通过 Literal 但模板未挂,显式抛 InvalidInputError → 422
    # 比 KeyError → 500 更准确(告知客户端"module 尚未支持"而非"服务器内部错误")
    prompt_version = PROMPT_VERSIONS.get(req.module)
    if prompt_version is None:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.warning(
            "interpret.module_not_registered elapsed_ms=%.1f request_id=%s "
            "module=%s content_hash=%s",
            elapsed_ms, request_id, req.module, req.content_hash,
        )
        raise InvalidInputError(
            f"module={req.module} 尚未支持(PROMPT_VERSIONS 未注册,"
            f"Stage 5 prompt 模板落地后可用)",
            request_id=request_id,
        )
    target_date_str = str(req.target_date) if req.target_date else None

    # 1.5 i18n:解析目标语言(从 X-QiCompass-Lang / Accept-Language header)
    # 解析层见 backend/app/api/language.py(i18n 决策 2:方案 4 双 header 混合)
    language = resolve_language(request)

    # 2. 校验 context + 渲染 prompt。缓存键必须覆盖 prompt 内容,否则同一
    # content_hash 携带不同 context 会污染跨用户缓存。
    # translate_context 放在 try 内:未注册术语抛 KeyError 时,
    # 包成 BaziCalculationFailedError(500)而非裸 KeyError 栈(术语表是后端配置,
    # 不是用户输入错误)。
    try:
        # 1.6 i18n:context 数据翻译层(i18n 决策 1:方案 3b 后端翻译责任)
        # 把 lunar_python 输出的中文术语按 language 翻译,让 LLM 拿到全目标语言的 prompt
        translated_context = translate_context(req.context, language, req.module)
        validate_context(req.module, translated_context)
        prompt = render_prompt(req.module, translated_context, language=language)
    except InvalidInputError as e:
        e.request_id = request_id
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.warning(
            "interpret.validate_failed elapsed_ms=%.1f request_id=%s "
            "content_hash=%s module=%s target_date=%s error=%r",
            elapsed_ms, request_id, req.content_hash, req.module,
            target_date_str, e,
            exc_info=True,
        )
        raise
    except KeyError as e:
        # translate_context 术语未注册 → 500(后端配置问题,非用户错误)
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.error(
            "interpret.translate_context_failed elapsed_ms=%.1f request_id=%s "
            "content_hash=%s module=%s language=%s error=%r",
            elapsed_ms, request_id, req.content_hash, req.module,
            language, e,
            exc_info=True,
        )
        raise BaziCalculationFailedError(
            f"术语翻译失败({e}),需补齐 term_translations.py 翻译表",
            request_id=request_id, content_hash=req.content_hash,
        ) from e
    except ChartJSONDecodeError as e:
        # T1(i18n-trilingual)review 修复 + 09-23 收窄:_translate_deep_context
        # 对客户端提交的 chart 字段做 json.loads——非 JSON(坏客户端/被篡改
        # 请求)在翻译层包成 ChartJSONDecodeError(ValueError 子类),此处包装
        # 成结构化 500(对齐 KeyError/FileNotFoundError 口径)。
        # 只捕该子类:validate_context / render_prompt 的其他 ValueError
        # (如模板花括号写错)不再被误报成「chart 非合法 JSON」。
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.error(
            "interpret.translate_context_invalid_chart elapsed_ms=%.1f "
            "request_id=%s content_hash=%s module=%s language=%s error=%r",
            elapsed_ms, request_id, req.content_hash, req.module,
            language, e,
            exc_info=True,
        )
        raise BaziCalculationFailedError(
            f"context.chart 非合法 JSON({e}),"
            f"深度解析 chart 字段须为 JSON 字符串(v1 §1 schema)",
            request_id=request_id, content_hash=req.content_hash,
        ) from e
    except FileNotFoundError as e:
        # render_prompt 模板文件缺失 → 500(后端配置问题)
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.error(
            "interpret.template_missing elapsed_ms=%.1f request_id=%s "
            "content_hash=%s module=%s language=%s error=%r",
            elapsed_ms, request_id, req.content_hash, req.module,
            language, e,
            exc_info=True,
        )
        raise BaziCalculationFailedError(
            f"prompt 模板缺失({e}),需补齐 prompts/{{language}}/ 目录",
            request_id=request_id, content_hash=req.content_hash,
        ) from e

    prompt_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()

    # 2.5 Entitlement 检查(仅 PAID_MODULES;MONETIZATION.md M2 越狱保护核心防线)
    # 越狱设备绕过 iOS UI 直调 /api/interpret 付费 module → 此处拦下
    # base module 映射(entitlement_base_module 单一事实源):
    # bazi_deep_paid / v1 m2-m7 → "bazi_deep"(单 SKU 解锁该盘全部深度付费内容)
    # compatibility_paid / compatibility alias → "compatibility"
    # 2026-08-23 修复:v1 m2-m7 此前按原名查 entitlement,而 iOS redeem 恒写
    # "bazi_deep" → 已购用户点 M2-M7 也 403(跨层断链),统一映射后闭合
    if req.module in PAID_MODULES:
        base_module = entitlement_base_module(req.module)
        entitlement_store: EntitlementStore = request.app.state.entitlement_store
        try:
            entitlement = await run_in_threadpool(
                entitlement_store.get_active,
                content_hash=req.content_hash,
                module=base_module,
                user_local_id=req.user_local_id,  # type: ignore[arg-type]
                # user_local_id 由 Pydantic model_validator 保证非空(付费 module 必填)
                # PR2.5:登录用户优先按 user_id 查(老 iOS / 老 entitlement 行兜底 user_local_id)
                user_id=current_user_id,
            )
        except Exception as e:
            # sqlite3 异常不吞(对齐 ai/cache.py:11-14 错误显式传播)
            logger.exception(
                "interpret.entitlement_check_failed request_id=%s "
                "content_hash=%s module=%s error=%r",
                request_id, req.content_hash, req.module, e)
            raise InterpretationCacheError(
                f"entitlement 查询失败({type(e).__name__}): {e}",
                request_id=request_id, content_hash=req.content_hash,
            ) from e
        if entitlement is None:
            logger.warning(
                "interpret.entitlement_not_found request_id=%s "
                "content_hash=%s base_module=%s",
                request_id, req.content_hash, base_module)
            raise EntitlementNotFoundError(
                f"未找到有效 entitlement(module={base_module} "
                f"content_hash={req.content_hash})",
                request_id=request_id, content_hash=req.content_hash,
            )

    ai_client = request.app.state.ai_client

    # v1 prompt 系统:CacheKey 加 parent_hash(M0 fingerprint)+ user_input_hash(M4/M5)
    # 老模块两字段默认空串,行为零变化(向后兼容)
    parent_hash = _hash_parent_fingerprint(req.parent_fingerprint)
    user_input_hash = _hash_user_input(req)

    log_ctx = {
        "request_id": request_id,
        "content_hash": req.content_hash,
        "module": req.module,
        "prompt_version": prompt_version,
        "target_date": target_date_str,
        "prompt_hash": prompt_hash,
        "provider": ai_client.provider,
        "model": ai_client.model,
        "parent_hash": parent_hash,
        "user_input_hash": user_input_hash,
        "language": language,
    }
    logger.info("interpret.start %s", log_ctx)

    cache_key = CacheKey(
        content_hash=req.content_hash,
        module=req.module,
        prompt_version=prompt_version,
        target_date=target_date_str,
        prompt_hash=prompt_hash,
        provider=ai_client.provider,
        model=ai_client.model,
        parent_hash=parent_hash,
        user_input_hash=user_input_hash,
        language=language,
    )

    cache: InterpretationCache = request.app.state.cache

    # 3. 查后端缓存
    try:
        cached_row = await run_in_threadpool(cache.get, cache_key)
    except Exception as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.cache_get_failed elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        raise InterpretationCacheError(
            f"后端缓存读失败({type(e).__name__}): {e}") from e

    if cached_row is not None:
        # 禁词扫描(防止老缓存被污染,US-COMP-04)
        forbidden_hits = scan_forbidden_words(cached_row["interpretation"])
        if forbidden_hits:
            elapsed_ms = (time.perf_counter() - start) * 1000
            logger.warning(
                "interpret.cache_forbidden elapsed_ms=%.1f %s hits=%s",
                elapsed_ms, log_ctx, forbidden_hits,
            )
            # 删除坏缓存,避免同一 content_hash 永久不可用(失败只 log,不掩盖禁词拦截)
            await _invalidate_poisoned_cache(cache, cache_key, log_ctx)
            raise InterpretationForbiddenError(
                f"AI 解读包含禁词,已拦截(命中: {', '.join(forbidden_hits)})",
                request_id=request_id,
                content_hash=req.content_hash,
            )
        # v1 JSON 契约自愈(2026-09-27):坏 JSON 行命中时不返回,删除后落穿
        # 重新生成。注意:截断时代的坏行是 prompt_version=1 键,已被 D3A bump
        # 孤立(新键永不命中);本层是纵深防御——拦未来回归(校验被弱化后
        # 写入的行)与旁路写入(evalkit/手工落库),与禁词中毒同理:删除后
        # 走正常生成路径,用户无感(多等一次生成)。
        try:
            _validate_v1_module_json(req.module, cached_row["interpretation"])
        except AIProviderError as e:
            elapsed_ms = (time.perf_counter() - start) * 1000
            logger.warning(
                "interpret.cache_invalid_json elapsed_ms=%.1f %s error=%s "
                "— 删除中毒缓存,落穿重新生成",
                elapsed_ms, log_ctx, e,
            )
            await _invalidate_poisoned_cache(cache, cache_key, log_ctx)
            cached_row = None
        if cached_row is not None:
            elapsed_ms = (time.perf_counter() - start) * 1000
            logger.info(
                "interpret.cache_hit elapsed_ms=%.1f %s",
                elapsed_ms, log_ctx,
            )
            return InterpretResponse(
                interpretation=cached_row["interpretation"],
                prompt_version=prompt_version,
                cached=True,
                generated_at=cached_row["generated_at"],
                provider=cached_row["provider"],
                model=cached_row["model"],
                language=language,
            )

    # 4. 调用选中 provider(async httpx 直接 await,不走线程池)
    #    singleflight 合并:同 key 并发只调一次 LLM,所有等待者共享结果
    #    (成本 + 延迟双省;多 worker 下各自独立,跨进程合并是 v2 Redis 的事)
    # v1 prompt 系统:按 module 分级 temperature(M0-M2=0.3 稳结构,M3-M7=0.6
    # 重质感,老模块=0.6 向后兼容);Stage 2 已铺基础设施,此处接入路由
    logger.info("interpret.provider_called %s", log_ctx)
    sf: SingleflightCoalescer = request.app.state.llm_singleflight
    # CacheKey 是 frozen dataclass,自动 hashable,直接作 singleflight dict key
    # (语义对齐:同 cache key 的并发 LLM 调用合并为一次)
    sf_key = cache_key
    temperature = resolve_temperature(req.module)
    try:
        interpretation = await sf.coalesce(
            sf_key, lambda: ai_client.interpret(
                prompt, temperature=temperature,
            ),
        )
    except AIProviderError as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.provider_failed elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        e.request_id = request_id
        raise
    # 非预期异常(AttributeError/TypeError 等代码 bug)不包装,
    # 向上抛由全局 handler 处理为 500,避免用 503 掩盖代码缺陷

    # 4.2 合盘后置处理(2026-09-27):A/B 代号确定性替换 + 干支接地违约观测。
    # 在禁词扫描/写缓存之前——扫描与缓存看到的都是最终文本。
    # 名字从 translated_context 取(老客户端无名字 → render_prompt 已 setdefault
    # 兜底 "A"/"B",替换退化为恒等)。
    if req.module in _COMPAT_POSTPROCESS_MODULES:
        interpretation = _replace_ab_labels(
            interpretation,
            translated_context.get("name_a") or "A",
            translated_context.get("name_b") or "B",
        )
        _log_offchart_ganzhi(interpretation, translated_context, log_ctx)

    # 4.4 v1 JSON 契约校验(2026-09-27):M0-M7 输出必须是完整 JSON 对象。
    # 截断/违约 → AIProviderError(503),不进禁词扫描、不写缓存、不返回
    # (半截 JSON 一旦入缓存,iOS 渲染层 parse 失败退回散文 = 正文 JSON 裸奔,
    # 真机 m1_talent 实证)。失败 refund 由 iOS 端重试链路承接(重试不耗次数)。
    try:
        _validate_v1_module_json(req.module, interpretation)
    except AIProviderError as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        e.request_id = request_id
        logger.error(
            "interpret.v1_invalid_json elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        raise

    # 4.5 禁词扫描(LLM 输出守卫,US-COMP-04)
    # 命中即拦截:不替换文本,不写缓存,不返回原文,直接抛错让客户端进入 error 态
    validate_interpretation(
        interpretation,
        request_id=request_id,
        content_hash=req.content_hash,
        log_ctx=log_ctx,
    )

    # 5. 写缓存(同步 → 线程池)
    now_iso = datetime.now(timezone.utc).isoformat()
    try:
        await run_in_threadpool(
            cache.set, cache_key, interpretation, now_iso,
        )
    except Exception as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.cache_set_failed elapsed_ms=%.1f %s error=%s",
            elapsed_ms, log_ctx, e,
        )
        raise InterpretationCacheError(
            f"后端缓存写失败({type(e).__name__}): {e}") from e

    # 6. 返回
    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info(
        "interpret.ok elapsed_ms=%.1f cached=False %s",
        elapsed_ms, log_ctx,
    )
    return InterpretResponse(
        interpretation=interpretation,
        prompt_version=prompt_version,
        cached=False,
        generated_at=now_iso,
        provider=ai_client.provider,
        model=ai_client.model,
        language=language,
    )


async def _invalidate_poisoned_cache(
    cache: InterpretationCache,
    cache_key: CacheKey,
    log_ctx: dict,
) -> None:
    """删除被污染的缓存条目(禁词命中 / v1 坏 JSON)。失败抛 InterpretationCacheError(不吞,避免坏缓存无限循环)。

    设计决策:删除失败时不静默吞,因为吞掉会导致同一坏缓存被反复命中,
    用户每次重试都拿到同样的禁词错误,形成无限循环。抛 InterpretationCacheError
    让用户看到"缓存故障"(不同于"禁词拦截"),知道是基础设施问题。
    """
    try:
        await run_in_threadpool(cache.delete, cache_key)
    except Exception as e:
        logger.exception(
            "interpret.cache_delete_failed %s error=%s "
            "cached entry remains poisoned, manual cleanup may be needed",
            log_ctx, e,
        )
        raise InterpretationCacheError(
            f"删除被禁词污染的缓存失败({type(e).__name__}): {e}"
        ) from e
