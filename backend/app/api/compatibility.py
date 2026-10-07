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

from ..context_binding import (
    build_chart_tokens,
    compat_fields,
    issue_token,
    payload_fields,
    verify_payload_against_chart,
)
from ..engine.compatibility import compute_compatibility
from ..errors import (
    BaziError,
    ContextTokenRequiredError,
    InvalidInputError,
)
from ..models.compatibility import CompatibilityRequest, CompatibilityResponse

router = APIRouter()
logger = logging.getLogger(__name__)


@router.post("/api/bazi/compatibility", response_model=CompatibilityResponse)
async def compatibility(
    req: CompatibilityRequest, request: Request,
) -> CompatibilityResponse:
    request_id = getattr(request.state, "request_id", None) or str(uuid.uuid4())
    start = time.perf_counter()

    b_mode = "archived" if req.person_b_hash is not None else "temporary"
    input_log = {
        "request_id": request_id,
        "person_a_hash": req.person_a_hash,
        "person_b_hash": req.person_b_hash,
        "b_mode": b_mode,
        "context": req.context,
    }
    logger.info("compatibility.start %s", input_log)

    # 2026-10-07 P0 收口:per-chart token 对账先行(伪造 payload 不进引擎)。
    # chart_payload 与 hash 单向不可逆,服务端无法复算——token 是唯一锚;
    # schema 层可选(单测直接构造模型),端点显式强制。
    # ContextToken*Error 由全局 handler 接管(403)。
    if not req.context_token_a:
        raise ContextTokenRequiredError(
            "合盘请求须携带 context_token_a"
            "(A 盘排盘响应的 context_tokens.payload)",
            content_hash=req.person_a_hash)
    claims_a = verify_payload_against_chart(
        req.context_token_a,
        chart_hash=req.person_a_hash, chart_payload=req.chart_payload_a)
    claims_b: dict | None = None
    if req.person_b_hash is not None:
        if not req.context_token_b:
            raise ContextTokenRequiredError(
                "模式 A 合盘请求须携带 context_token_b"
                "(B 盘排盘响应的 context_tokens.payload)",
                content_hash=req.person_b_hash)
        claims_b = verify_payload_against_chart(
            req.context_token_b,
            chart_hash=req.person_b_hash, chart_payload=req.chart_payload_b)

    try:
        result = await run_in_threadpool(compute_compatibility, req=req)
    except BaziError as e:
        e.request_id = request_id
        _log_and_reraise(e, input_log, start)
    except ValueError as e:
        # chart_payload 字段非法(如未知天干)→ 转 BaziError(走全局 handler);
        # S02 后时区/经度校验已在 Pydantic 层 422,引擎不再有查表路径
        wrapped = InvalidInputError(
            f"合盘请求字段非法: {e}",
        )
        wrapped.request_id = request_id
        _log_and_reraise(wrapped, input_log, start)

    # 模式 B:B 盘服务端现排(受信源),从结果构建 claims
    if claims_b is None:
        b_dump = result.person_b_chart.model_dump()
        claims_b = payload_fields(b_dump)
        # 同源签发 B 盘 context_tokens(2026-10-07 P0 收口;分层修复后签名
        # 收口 API 层,与 /api/bazi/calculate 同款,引擎保持纯计算)。
        # iOS 把 person_b_chart 隐式落地为 ChartSnapshot 时存档 token——
        # 否则该盘的深度解析/每日/合盘-as-A 全部 403 且无补签入口。
        # 纯 CPU(镜像字段 + HMAC),留 event loop。
        result.person_b_chart.context_tokens = build_chart_tokens(b_dump)

    # 签发 compat 族 token(绑定核心字段子集;interpret/translate 验签)
    result.context_token = issue_token(
        content_hash=result.compatibility_hash, family="compat",
        fields=compat_fields(
            context=req.context, claims_a=claims_a, claims_b=claims_b,
            assessment=result.qualitative_assessment))

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
