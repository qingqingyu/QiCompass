"""FastAPI 应用:路由注册 + 异常 handler + request_id middleware。"""

from __future__ import annotations

import logging
import os
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from .ai.cache import InterpretationCache
from .ai.client import create_ai_client
from .api import bazi as bazi_api
from .api import compatibility as compatibility_api
from .api import daily_fortune as daily_fortune_api
from .api import entitlement as entitlement_api
from .api import health as health_api
from .api import interpret as interpret_api
from .api import webhooks as webhooks_api
from .config import (
    AI_PROVIDER,
    ANTHROPIC_API_KEY,
    ANTHROPIC_MODEL,
    APP_STORE_APP_APPLE_ID,
    APP_STORE_BUNDLE_ID,
    APP_STORE_ENVIRONMENT,
    APP_STORE_ISSUER_ID,
    APP_STORE_KEY_ID,
    APP_STORE_PRIVATE_KEY,
    DB_PATH,
    MODEL_ID,
    OPENAI_API_KEY,
    OPENAI_BASE_URL,
    OPENAI_MODEL,
    apple_env_configured,
)
from .entitlement import EntitlementStore, MockAppleServerAPI
from .errors import BaziError
from .models.bazi import ErrorBody, ErrorResponse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)

logger = logging.getLogger(__name__)


class RequestIdMiddleware(BaseHTTPMiddleware):
    """每请求生成 request_id,挂到 request.state + 响应头 X-Request-ID。"""

    async def dispatch(self, request: Request, call_next):
        request_id = request.headers.get("X-Request-ID") or str(uuid.uuid4())
        request.state.request_id = request_id
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        return response


@asynccontextmanager
async def lifespan(app: FastAPI):
    """lifespan 启动:
    - mkdir -p data/ 目录
    - 初始化 SQLite 表(CREATE TABLE IF NOT EXISTS,幂等)
      - InterpretationCache(ai/cache.py)
      - EntitlementStore(entitlement/store.py,M2 新增)
    - 根据 AI_PROVIDER 构造单一 AIClient(key 缺失也构造,调用时显式报 503)
    - 构造 InterpretationCache + EntitlementStore 挂 app.state
    - M2a 阶段 apple_server_api 挂 Mock(M2b 切真 SDK 包装)
    """
    db_dir = os.path.dirname(DB_PATH)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)

    cache = InterpretationCache(DB_PATH)
    cache.init_schema()  # 幂等;失败则启动报错(不吞)
    app.state.cache = cache

    # M2a 新增:EntitlementStore(与 InterpretationCache 共用同一 SQLite 文件,
    # 不同表:entitlement vs interpretation_cache)
    entitlement_store = EntitlementStore(DB_PATH)
    entitlement_store.init_schema()
    app.state.entitlement_store = entitlement_store

    # M2b:Apple Server API 切换
    # - env 配齐(5 个 Apple env)+ SDK 已装 → AppleServerAPIClient(真调 Apple)
    # - 否则 → MockAppleServerAPI(dev/test,iOS 用 mock transaction_id 走通链路)
    # M6 TestFlight 阶段才需要真 SDK;M2b 骨架阶段用户未 pip install
    app.state.apple_server_api = _build_apple_server_api()

    app.state.ai_client = _build_ai_client()
    ai_client = app.state.ai_client
    selected_key_configured = (
        bool(ANTHROPIC_API_KEY)
        if ai_client.provider == "anthropic"
        else bool(OPENAI_API_KEY)
    )
    apple_kind = "mock" if isinstance(
        app.state.apple_server_api, MockAppleServerAPI) else "apple_sdk"
    logger.info(
        "startup ok db_path=%s ai_provider=%s ai_model=%s "
        "selected_api_key_configured=%s apple_server_api=%s",
        DB_PATH,
        ai_client.provider,
        ai_client.model,
        selected_key_configured,
        apple_kind,
    )
    yield
    # 无特殊清理(SQLite / httpx 均为短连接)


def _build_apple_server_api():
    """根据 env + SDK 安装情况构造 Apple Server API。

    返回:
        AppleServerAPIClient(若 env 齐 + SDK 装)
        MockAppleServerAPI(否则,dev/test 模式)
    """
    if not apple_env_configured():
        logger.info(
            "apple_server_api=mock reason=env_incomplete "
            "(M6 TestFlight 前正常,填齐 5 个 APP_STORE_* env 自动切真)"
        )
        return MockAppleServerAPI()

    # env 齐,尝试构造真 SDK 客户端
    try:
        from .entitlement.apple_client import AppleServerAPIClient
        return AppleServerAPIClient(
            bundle_id=APP_STORE_BUNDLE_ID,  # type: ignore[arg-type]
            key_id=APP_STORE_KEY_ID,  # type: ignore[arg-type]
            issuer_id=APP_STORE_ISSUER_ID,  # type: ignore[arg-type]
            private_key=APP_STORE_PRIVATE_KEY,  # type: ignore[arg-type]
            environment=APP_STORE_ENVIRONMENT,  # type: ignore[arg-type]
            app_apple_id=APP_STORE_APP_APPLE_ID,  # type: ignore[arg-type]
        )
    except RuntimeError as e:
        # SDK 未安装或初始化失败(私钥格式不对等)→ fallback Mock
        logger.warning(
            "apple_server_api=mock reason=sdk_init_failed error=%s", e)
        return MockAppleServerAPI()


def _build_ai_client():
    return create_ai_client(
        provider=AI_PROVIDER,
        anthropic_api_key=ANTHROPIC_API_KEY,
        anthropic_model=ANTHROPIC_MODEL,
        openai_api_key=OPENAI_API_KEY,
        openai_model=OPENAI_MODEL,
        openai_base_url=OPENAI_BASE_URL,
    )


app = FastAPI(title="QiCompass Bazi Backend", version=MODEL_ID, lifespan=lifespan)
# ASGITransport 单测不触发 lifespan;先挂默认实例,启动时再重建一次。
# entitlement_store / apple_server_api 也挂 fallback(测试 fixture 可覆盖)。
app.state.ai_client = _build_ai_client()
_default_entitlement_store = EntitlementStore(DB_PATH)
_default_entitlement_store.init_schema()
app.state.entitlement_store = _default_entitlement_store
app.state.apple_server_api = MockAppleServerAPI()
app.add_middleware(RequestIdMiddleware)

app.include_router(health_api.router)
app.include_router(bazi_api.router)
app.include_router(compatibility_api.router)
app.include_router(daily_fortune_api.router)
app.include_router(interpret_api.router)
app.include_router(entitlement_api.router)
app.include_router(webhooks_api.router)


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
