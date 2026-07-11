"""POST /api/bazi/calculate

- city/longitude 解析(longitude 优先级高于 city)
- BaziEngine.calculate 是同步 CPU-bound,用 run_in_threadpool 包,不阻塞 event loop
- 错误显式传播:CityNotFound → 404;InvalidInput → 422;引擎异常 → 500
"""

from __future__ import annotations

import logging
import time
import uuid

from fastapi import APIRouter, Request
from starlette.concurrency import run_in_threadpool

from ..core.city_longitude import resolve_longitude
from ..engine.bazi_engine import BaziEngine
from ..errors import BaziError, CityNotFoundError, InvalidInputError
from ..models.bazi import BaziCalculateRequest, BaziCalculateResponse

router = APIRouter()
logger = logging.getLogger(__name__)


@router.post("/api/bazi/calculate", response_model=BaziCalculateResponse)
async def calculate_bazi(req: BaziCalculateRequest, request: Request) -> BaziCalculateResponse:
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    input_log = {
        "request_id": request_id,
        "birth_datetime": req.birth_datetime.isoformat(),
        "gender": req.gender,
        "city": req.city,
        "longitude": req.longitude,
        "zi_hour_rule": req.zi_hour_rule,
    }
    logger.info("bazi.calculate.start %s", input_log)

    # 1. 经度解析(longitude 优先级高于 city;二者至少传一个)
    try:
        longitude = resolve_longitude(req.city, req.longitude)
    except (CityNotFoundError, InvalidInputError) as e:
        e.request_id = request_id
        _log_and_reraise(e, input_log, start, content_hash=None)

    # 2. 引擎排盘(同步 CPU-bound → 线程池)
    engine = BaziEngine()
    try:
        result = await run_in_threadpool(
            engine.calculate,
            birth=req.birth_datetime,
            gender=req.gender,
            longitude=longitude,
            zi_hour_rule=req.zi_hour_rule,
        )
    except BaziError as e:
        e.request_id = request_id
        _log_and_reraise(e, {**input_log, "content_hash": e.content_hash}, start,
                         content_hash=e.content_hash)

    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info(
        "bazi.calculate.ok request_id=%s content_hash=%s elapsed_ms=%.1f",
        request_id, result["content_hash"], elapsed_ms,
    )
    return BaziCalculateResponse(**result)


def _log_and_reraise(e: Exception, input_log: dict, start: float,
                      content_hash: str | None) -> None:
    """记错误日志后重新抛出(全局 handler 接管响应)。"""
    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.exception(
        "bazi.calculate.failed elapsed_ms=%.1f input=%s content_hash=%s",
        elapsed_ms, input_log, content_hash,
    )
    raise e
