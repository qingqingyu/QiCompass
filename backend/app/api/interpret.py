"""POST /api/interpret — AI 命书解读(三模块共用)。

流程(最终方案 §7):
1. 取 prompt_version = PROMPT_VERSIONS[req.module](后端配置,不从客户端读)
2. validate_context + render_prompt(纯 CPU,留 event loop),计算 prompt_hash
3. 查后端缓存(同步 → run_in_threadpool)
   命中 → 返回 InterpretResponse(cached=True)
4. 调用选中的 AI provider(async httpx,直接 await,不走线程池)
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
import logging
import time
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Request
from starlette.concurrency import run_in_threadpool

from ..ai.cache import InterpretationCache
from ..ai.cache_key import CacheKey
from ..ai.forbidden_words import scan as scan_forbidden_words
from ..ai.forbidden_words import validate_interpretation
from ..ai.prompts import PROMPT_VERSIONS, render_prompt, validate_context
from ..ai.singleflight import SingleflightCoalescer
from ..auth.dependencies import get_current_user_id
from ..config import resolve_temperature
from ..engine.term_translations import translate_context
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
    V1_NEEDS_USER_INPUT,
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
    # PAID_MODULES 替代老 endswith("_paid"):v1 m2-m7 无 _paid 后缀但都是付费
    if req.module in PAID_MODULES:
        # 老 module:bazi_deep_paid → bazi_deep(entitlement 存 base module 名,去 _paid 后缀)
        # v1 module:m2_high_low 等直接用原名(entitlement 不去后缀)
        if req.module.endswith("_paid"):
            base_module = req.module.removesuffix("_paid")
        else:
            base_module = req.module
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
    """删除被禁词污染的缓存条目。失败抛 InterpretationCacheError(不吞,避免坏缓存无限循环)。

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
