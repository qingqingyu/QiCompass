"""POST /api/bazi/compatibility

- 模式 A (B 已存档): 客户端传 person_b_hash + chart_payload_b, 后端零排盘
- 模式 B (B 临时输入): 客户端传 person_b{...}, 后端现排 B
- compatibility 引擎是同步 CPU-bound, 用 run_in_threadpool 包, 不阻塞 event loop
- 错误显式传播: ValueError → InvalidInputError → 422; 引擎异常 → 500
- 日志: request_id / A hash / B hash / B 模式 / context / 耗时
"""

from __future__ import annotations

import logging
import time
import uuid
from typing import NoReturn

from fastapi import APIRouter, Request
from starlette.concurrency import run_in_threadpool

from ..engine.compatibility import compute_compatibility
from ..errors import BaziError, InvalidInputError
from ..models.compatibility import CompatibilityRequest, CompatibilityResponse

router = APIRouter()
logger = logging.getLogger(__name__)


@router.post("/api/bazi/compatibility", response_model=CompatibilityResponse)
async def compatibility(
    req: CompatibilityRequest, request: Request,
) -> CompatibilityResponse:
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    b_mode = "archived" if req.person_b_hash else "temporary"
    input_log = {
        "request_id": request_id,
        "person_a_hash": req.person_a_hash,
        "person_b_hash": req.person_b_hash,
        "b_mode": b_mode,
        "context": req.context,
    }
    logger.info("compatibility.start %s", input_log)

    try:
        result = await run_in_threadpool(compute_compatibility, req=req)
    except BaziError as e:
        e.request_id = request_id
        _log_and_reraise(e, input_log, start)
    except ValueError as e:
        # chart_payload 字段非法 / 查表缺失 → 转 BaziError(走全局 handler)
        wrapped = InvalidInputError(
            f"合盘请求字段非法: {e}",
        )
        wrapped.request_id = request_id
        _log_and_reraise(wrapped, input_log, start)

    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info(
        "compatibility.ok request_id=%s comp_hash=%s b_mode=%s context=%s "
        "elapsed_ms=%.1f",
        request_id, result.compatibility_hash, b_mode, req.context, elapsed_ms,
    )
    return result


def _log_and_reraise(e: Exception, input_log: dict, start: float) -> NoReturn:
    """记错误日志后重新抛出(全局 handler 接管响应)。"""
    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.exception(
        "compatibility.failed elapsed_ms=%.1f input=%s",
        elapsed_ms, input_log,
    )
    raise e
