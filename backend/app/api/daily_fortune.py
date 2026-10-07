"""POST /api/bazi/daily-fortune

- chart_payload 模式:服务端无状态,不反推 birth,不持久化 ChartSnapshot(决策 §1.A)
- daily_fortune 引擎是同步 CPU-bound,用 run_in_threadpool 包,不阻塞 event loop
- 错误显式传播:ValueError → 422;引擎异常 → 500(全局 handler 已注册)
- 日志:request_id / chart_hash / target_date / elapsed_ms;失败带原始 exception
"""

from __future__ import annotations

import logging
import time
import uuid
from typing import NoReturn

from fastapi import APIRouter, Request
from starlette.concurrency import run_in_threadpool

from ..context_binding import daily_fields, issue_token, verify_payload_against_chart
from ..engine.daily_fortune import compute_daily_fortune
from ..errors import BaziError, ContextTokenRequiredError, InvalidInputError
from ..models.daily_fortune import DailyFortuneRequest, DailyFortuneResponse

router = APIRouter()
logger = logging.getLogger(__name__)


@router.post("/api/bazi/daily-fortune", response_model=DailyFortuneResponse)
async def daily_fortune(
    req: DailyFortuneRequest, request: Request,
) -> DailyFortuneResponse:
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    input_log = {
        "request_id": request_id,
        "chart_hash": req.chart_hash,
        "target_date": req.target_date.isoformat(),
    }
    logger.info("daily.fortune.start %s", input_log)

    # 2026-10-07 P0 收口:per-chart token 对账先行(chart_payload 客户端自持,
    # 不可复算;伪造 payload 不进引擎)。schema 层可 None(生图端点复用模型
    # 且不需要 token),本端点显式强制。ContextToken*Error 走全局 handler(403)。
    if not req.context_token:
        raise ContextTokenRequiredError(
            "daily-fortune 请求须携带 context_token"
            "(该盘排盘响应的 context_tokens.payload)",
            content_hash=req.chart_hash)
    chart_claims = verify_payload_against_chart(
        req.context_token,
        chart_hash=req.chart_hash, chart_payload=req.chart_payload)

    try:
        result = await run_in_threadpool(
            compute_daily_fortune,
            chart_hash=req.chart_hash,
            target_date=req.target_date,
            chart_payload=req.chart_payload,
        )
    except BaziError as e:
        e.request_id = request_id
        _log_and_reraise(e, input_log, start, chart_hash=req.chart_hash)
    except ValueError as e:
        # chart_payload 字段非法 → 转 BaziError(走全局 handler)
        wrapped = InvalidInputError(
            f"chart_payload 字段非法: {e}",
        )
        wrapped.request_id = request_id
        _log_and_reraise(wrapped, input_log, start, chart_hash=req.chart_hash)

    # 签发 daily 族 token(claims 含 target_date,同盘不同日不可互用)
    result.context_token = issue_token(
        content_hash=req.chart_hash, family="daily",
        fields=daily_fields(
            claims=chart_claims, response=result,
            target_date_iso=req.target_date.isoformat()))

    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info(
        "daily.fortune.ok request_id=%s chart_hash=%s target_date=%s elapsed_ms=%.1f",
        request_id, req.chart_hash, req.target_date.isoformat(), elapsed_ms,
    )
    return result


def _log_and_reraise(e: Exception, input_log: dict, start: float,
                      chart_hash: str) -> NoReturn:
    """记错误日志后重新抛出(全局 handler 接管响应)。"""
    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.exception(
        "daily.fortune.failed elapsed_ms=%.1f input=%s chart_hash=%s",
        elapsed_ms, input_log, chart_hash,
    )
    raise e
