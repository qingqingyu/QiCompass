"""FastAPI 应用:路由注册 + 异常 handler + request_id middleware。"""

from __future__ import annotations

import logging
import uuid

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from .api import bazi as bazi_api
from .api import health as health_api
from .config import MODEL_ID
from .errors import BaziError
from .models.bazi import ErrorBody, ErrorResponse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)


class RequestIdMiddleware(BaseHTTPMiddleware):
    """每请求生成 request_id,挂到 request.state + 响应头 X-Request-ID。"""

    async def dispatch(self, request: Request, call_next):
        request_id = request.headers.get("X-Request-ID") or str(uuid.uuid4())
        request.state.request_id = request_id
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        return response


app = FastAPI(title="QiCompass Bazi Backend", version=MODEL_ID)
app.add_middleware(RequestIdMiddleware)

app.include_router(health_api.router)
app.include_router(bazi_api.router)


# ---------- 异常 handler(错误显式传播,统一响应结构)----------


@app.exception_handler(BaziError)
async def bazi_error_handler(request: Request, exc: BaziError) -> JSONResponse:
    request_id = getattr(request.state, "request_id", None) or exc.request_id
    body = ErrorBody(
        code=exc.code,
        message=exc.message,
        request_id=request_id,
        content_hash=exc.content_hash,
    )
    return JSONResponse(
        status_code=exc.http_status,
        content=ErrorResponse(error=body).model_dump(),
    )


@app.exception_handler(RequestValidationError)
async def validation_error_handler(
    request: Request, exc: RequestValidationError,
) -> JSONResponse:
    """Pydantic 422 → 结构化错误(含 detail)。"""
    request_id = getattr(request.state, "request_id", None)
    details = exc.errors()
    msg = "; ".join(
        f"{'.'.join(str(x) for x in e.get('loc', []))}: {e.get('msg', '')}"
        for e in details
    )
    body = ErrorBody(
        code="INVALID_INPUT",
        message=msg or "请求参数校验失败",
        request_id=request_id,
    )
    return JSONResponse(
        status_code=422,
        content=ErrorResponse(error=body).model_dump(),
    )


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception) -> JSONResponse:
    """兜底:任何未捕获异常 → 500 结构化错误(不裸露 stack 给客户端)。"""
    request_id = getattr(request.state, "request_id", None)
    logging.exception(
        "unhandled exception request_id=%s: %s", request_id, exc,
    )
    body = ErrorBody(
        code="INTERNAL_ERROR",
        message=f"服务内部错误: {type(exc).__name__}",
        request_id=request_id,
    )
    return JSONResponse(
        status_code=500,
        content=ErrorResponse(error=body).model_dump(),
    )
