"""POST /api/bazi/calculate

S02 契约(docs/城市搜索设计决策.md Q4/Q5):
- 客户端发物理真值(longitude/latitude/timezone/place_name),后端零城市表
- birth_datetime 为裸钟面时间,此处用 zoneinfo 解释成绝对时刻
  (历史夏令时规则自动套用;歧义/跳过小时降级 boundary_warning)
- BaziEngine.calculate 是同步 CPU-bound,用 run_in_threadpool 包,不阻塞 event loop
- 错误显式传播:非法时区/带 offset 时间 → Pydantic 422;引擎异常 → 500
"""

from __future__ import annotations

import logging
import time
import uuid
from typing import NoReturn

from fastapi import APIRouter, Request
from starlette.concurrency import run_in_threadpool

from ..core.tz_resolution import resolve_wall_time
from ..engine.bazi_engine import BaziEngine, hour_unknown_placeholder
from ..errors import BaziError
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
        "timezone": req.timezone,
        "gender": req.gender,
        "longitude": req.longitude,
        "latitude": req.latitude,
        "place_name": req.place_name,
        "geoname_id": req.geoname_id,
        "zi_hour_rule": req.zi_hour_rule,
        "hour_known": req.hour_known,
        "late_night": req.late_night,
    }
    logger.info("bazi.calculate.start %s", input_log)

    # 1. 钟面 → 绝对时刻(timezone 合法性已由 Pydantic validator 保证;
    #    此处再验是双保险,触发即 invariant 破坏 → 500 暴露 bug,不静默)
    #    时辰未知:先归一 12:00 再解释时区 —— 未知时辰下 dst 边角
    #    (歧义/跳过/切换附近)对任意的时辰噪声毫无意义,归一后
    #    「同日期任意时辰输入 → 同一输出」自然成立
    effective_wall = (
        req.birth_datetime if req.hour_known
        else hour_unknown_placeholder(req.birth_datetime)
    )
    resolved = resolve_wall_time(effective_wall, req.timezone)

    # 2. 引擎排盘(同步 CPU-bound → 线程池)
    engine = BaziEngine()
    try:
        result = await run_in_threadpool(
            engine.calculate,
            birth=resolved.aware,
            gender=req.gender,
            longitude=req.longitude,
            zi_hour_rule=req.zi_hour_rule,
            dst_flags=resolved.dst_flags,
            birth_timezone=req.timezone,
            hour_known=req.hour_known,
            late_night=req.late_night,
        )
    except BaziError as e:
        e.request_id = request_id
        _log_and_reraise(e, {**input_log, "content_hash": e.content_hash}, start,
                         content_hash=e.content_hash)

    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.info(
        "bazi.calculate.ok request_id=%s content_hash=%s dst_flags=%s elapsed_ms=%.1f",
        request_id, result["content_hash"], sorted(resolved.dst_flags), elapsed_ms,
    )
    return BaziCalculateResponse(**result)


def _log_and_reraise(e: Exception, input_log: dict, start: float,
                      content_hash: str | None) -> NoReturn:
    """记错误日志后重新抛出(全局 handler 接管响应)。"""
    elapsed_ms = (time.perf_counter() - start) * 1000
    logger.exception(
        "bazi.calculate.failed elapsed_ms=%.1f input=%s content_hash=%s",
        elapsed_ms, input_log, content_hash,
    )
    raise e
