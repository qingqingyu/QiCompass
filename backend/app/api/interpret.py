"""POST /api/interpret — AI 命书解读(三模块共用)。

流程(最终方案 §7):
1. 取 prompt_version = PROMPT_VERSIONS[req.module](后端配置,不从客户端读)
2. validate_context + render_prompt(纯 CPU,留 event loop),计算 prompt_hash
3. 查后端缓存(同步 → run_in_threadpool)
   命中 → 返回 InterpretResponse(cached=True)
4. 调 Claude(同步 → run_in_threadpool)
5. 写缓存(同步 → run_in_threadpool)
6. 返回 InterpretResponse(cached=False)

线程池策略:
- validate_context + render_prompt 纯字符串操作,快,留在 event loop
- cache.get / cache.set / claude_client.interpret 各自 run_in_threadpool
  不合并:缓存命中时零 Claude 线程池开销
- Claude 调用失败时不写缓存(步骤 4 抛异常中断流程)

错误显式传播:
- Claude 失败 → ClaudeAPIError(503),不吞不返回假文本
- SQLite 失败 → InterpretationCacheError(500),不降级为 Claude 调用
"""

from __future__ import annotations

import hashlib
import logging
import time
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Request
from starlette.concurrency import run_in_threadpool

from ..ai.cache import InterpretationCache
from ..ai.forbidden_words import scan as scan_forbidden_words
from ..ai.forbidden_words import validate_interpretation
from ..ai.prompts import PROMPT_VERSIONS, render_prompt, validate_context
from ..config import CLAUDE_MODEL
from ..errors import (
    ClaudeAPIError,
    InterpretationCacheError,
    InterpretationForbiddenError,
    InvalidInputError,
)
from ..models.interpret import InterpretRequest, InterpretResponse

router = APIRouter()
logger = logging.getLogger(__name__)


@router.post("/api/interpret", response_model=InterpretResponse)
async def interpret(req: InterpretRequest, request: Request) -> InterpretResponse:
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    # 1. 取 prompt_version(后端配置,不从客户端读)
    prompt_version = PROMPT_VERSIONS[req.module]
    target_date_str = str(req.target_date) if req.target_date else None

    # 2. 校验 context + 渲染 prompt。缓存键必须覆盖 prompt 内容,否则同一
    # content_hash 携带不同 context 会污染跨用户缓存。
    try:
        validate_context(req.module, req.context)
        prompt = render_prompt(req.module, req.context)
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

    prompt_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()

    log_ctx = {
        "request_id": request_id,
        "content_hash": req.content_hash,
        "module": req.module,
        "prompt_version": prompt_version,
        "target_date": target_date_str,
        "prompt_hash": prompt_hash,
        "model": CLAUDE_MODEL,
    }
    logger.info("interpret.start %s", log_ctx)

    cache: InterpretationCache = request.app.state.cache
    claude_client = request.app.state.claude_client

    # 3. 查后端缓存
    try:
        cached_row = await run_in_threadpool(
            cache.get,
            content_hash=req.content_hash,
            module=req.module,
            prompt_version=prompt_version,
            target_date=target_date_str,
            prompt_hash=prompt_hash,
        )
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
            await _invalidate_poisoned_cache(cache, log_ctx,
                content_hash=req.content_hash,
                module=req.module,
                prompt_version=prompt_version,
                target_date=target_date_str,
                prompt_hash=prompt_hash,
            )
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
        )

    # 4. 调 Claude(同步 → 线程池)
    logger.info("interpret.claude_called %s", log_ctx)
    try:
        interpretation = await run_in_threadpool(claude_client.interpret, prompt)
    except ClaudeAPIError as e:
        elapsed_ms = (time.perf_counter() - start) * 1000
        logger.exception(
            "interpret.claude_failed elapsed_ms=%.1f %s error=%s",
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
            cache.set,
            content_hash=req.content_hash,
            module=req.module,
            prompt_version=prompt_version,
            target_date=target_date_str,
            prompt_hash=prompt_hash,
            model=CLAUDE_MODEL,
            interpretation=interpretation,
            generated_at=now_iso,
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
    )


async def _invalidate_poisoned_cache(
    cache: InterpretationCache,
    log_ctx: dict,
    **key_kwargs,
) -> None:
    """删除被禁词污染的缓存条目,失败只 log 不抛(不掩盖禁词拦截本身)。"""
    try:
        await run_in_threadpool(cache.delete, **key_kwargs)
    except Exception as e:
        logger.exception(
            "interpret.cache_delete_failed %s error=%s "
            "cached entry remains poisoned, manual cleanup may be needed",
            log_ctx, e,
        )
