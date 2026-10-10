"""FastAPI 应用:路由注册 + 异常 handler + request_id middleware。"""

from __future__ import annotations

import logging
import os
import uuid
from contextlib import asynccontextmanager
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware

from .ai.cache import InterpretationCache
from .ai.image_cache import DailyImageCache
from .ai.image_client import ImageGenClient
from .ai.client import create_ai_client
from .ai.singleflight import SingleflightCoalescer
from .api import bazi as bazi_api
from .api import compatibility as compatibility_api
from .api import daily_fortune as daily_fortune_api
from .api import daily_image as daily_image_api
from .api import entitlement as entitlement_api
from .api import health as health_api
from .api import interpret as interpret_api
from .api import webhooks as webhooks_api
from .api import auth as auth_api
from .api import sync as sync_api
from .config import (
    AI_PROVIDER,
    ANTHROPIC_API_KEY,
    ANTHROPIC_BASE_URL,
    ANTHROPIC_MODEL,
    APP_STORE_APP_APPLE_ID,
    APP_STORE_BUNDLE_ID,
    APP_STORE_ENVIRONMENT,
    APP_STORE_ISSUER_ID,
    APP_STORE_KEY_ID,
    IMAGE_API_BASE_URL,
    IMAGE_API_KEY,
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


def _ensure_tzdata_available() -> None:
    """S02 时区解释前置自检:系统 tzdata 缺失 → 启动即失败(错误显式归因部署)。

    否则 stdlib zoneinfo 对所有合法 IANA 时区名抛 ZoneInfoNotFoundError,
    会被 validate_timezone 误判为客户端 422「非法时区名」——部署故障伪装成
    用户输入错误。Alpine 容器需 apk add tzdata(见 backend/README.md)。
    """
    try:
        ZoneInfo("Asia/Shanghai")
    except (ZoneInfoNotFoundError, ValueError, OSError) as e:
        # ValueError/OSError = tzdb 文件损坏等,同属部署层故障,统一归因
        raise RuntimeError(
            "系统 tzdata 不可用(zoneinfo 找不到 Asia/Shanghai):"
            "Alpine 容器请 apk add tzdata(backend/README.md 部署备忘)"
        ) from e


# 模块加载即自检(对齐下方 store 模块级初始化策略:测试 ASGITransport
# 不触发 lifespan,缺失时测试也应立即失败而非逐请求 422)
_ensure_tzdata_available()


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
    app.state.llm_singleflight = SingleflightCoalescer()

    # 每日运势插画(S2):状态缓存 + 生图客户端 + 生图 singleflight。
    # key/base 缺失也构造,调用端点时显式 503(对齐 ai_client 策略)。
    daily_image_cache = DailyImageCache(DB_PATH)
    daily_image_cache.init_schema()
    app.state.daily_image_cache = daily_image_cache
    app.state.image_client = ImageGenClient(
        api_key=IMAGE_API_KEY, base_url=IMAGE_API_BASE_URL,
    )
    app.state.image_singleflight = SingleflightCoalescer()

    # M2a 新增:EntitlementStore(与 InterpretationCache 共用同一 SQLite 文件,
    # 不同表:entitlement vs interpretation_cache)
    entitlement_store = EntitlementStore(DB_PATH)
    entitlement_store.init_schema()
    app.state.entitlement_store = entitlement_store

    # 2026-10-07:免费 LLM 生成每日配额 store(lifespan 正式实例,
    # 覆盖模块级 fallback;ASGITransport 单测由 conftest fixture 替换)
    from app.quota.store import FreeLLMQuotaStore
    free_quota_store = FreeLLMQuotaStore(DB_PATH)
    free_quota_store.init_schema()
    app.state.free_quota_store = free_quota_store

    # M2b:Apple Server API 切换
    # - env 配齐(5 个 Apple env)+ SDK 已装 → AppleServerAPIClient(真调 Apple)
    # - 否则 → MockAppleServerAPI(dev/test,iOS 用 mock transaction_id 走通链路)
    # M6 TestFlight 阶段才需要真 SDK;M2b 骨架阶段用户未 pip install
    app.state.apple_server_api = _build_apple_server_api()

    # 2026-10-09 监控闭环 A 档:LLM 调用结果计数 + 失败率告警。
    # store 与配额 store 同库共表空间;client 包一层 MeteredAIClient
    # (计数/告警只旁观,协议与行为零变化)。
    from app.monitoring.store import LLMOutcomeStore
    llm_metrics_store = LLMOutcomeStore(DB_PATH)
    llm_metrics_store.init_schema()
    app.state.llm_metrics_store = llm_metrics_store
    from app.monitoring.metered import MeteredAIClient
    app.state.ai_client = MeteredAIClient(
        _build_ai_client(), llm_metrics_store)
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
    # 后台计数任务收尾(2026-10-10 监控后台化):优雅停机时 join 在飞的
    # LLM 计数/告警任务,末尾几条监控不随进程退出丢失(暴力停机仍可能丢,
    # 监控本就是 best-effort,不因此阻塞停机——gather 无超时,任务只剩
    # SQLite 短连接操作,亚秒级)。
    from app.monitoring.metered import wait_for_pending_records
    await wait_for_pending_records()


def _build_apple_server_api():
    """根据 env + SDK 安装情况构造 Apple Server API。

    返回:
        AppleServerAPIClient(若 env 齐;构造失败直接向上抛,启动 fail-fast)
        MockAppleServerAPI(env 不齐,dev/test 模式)

    2026-08-23 修复:env 配齐时不再对 SDK/证书失败降级 Mock——Mock 验证
    全通过,生产降级 = entitlement 校验形同虚设(fail-open,比启动失败更糟)。
    对齐 CLAUDE.md 错误显式传播:该报错就报错。
    """
    if not apple_env_configured():
        # 2026-10-07 收口:生产缺配 = 任意 transaction_id 免费兑换付费权益
        # (PoC 实证)——fail-fast,不再静默挂会放行的 Mock。sandbox 缺配仍挂
        # Mock(dev/test),但 Mock 默认锁定(redeem 503),须显式
        # QICOMPASS_ALLOW_MOCK_APPLE=1 才放行(见 protocol.py)。
        if APP_STORE_ENVIRONMENT == "production":
            raise RuntimeError(
                "APP_STORE_ENVIRONMENT=production 但 5 个 APP_STORE_* env 未配齐"
                "(BUNDLE_ID/KEY_ID/ISSUER_ID/PRIVATE_KEY/APP_APPLE_ID)——"
                "生产缺配会静默挂 Mock = 任意交易免费兑换付费权益,拒绝启动。"
                "请配齐 env 或显式降回 sandbox"
            )
        logger.info(
            "apple_server_api=mock_locked reason=env_incomplete "
            "(sandbox 默认锁定,redeem 显式 503;dev 走通链路设 "
            "QICOMPASS_ALLOW_MOCK_APPLE=1;生产须配齐 5 个 APP_STORE_* env)"
        )
        return MockAppleServerAPI()

    # env 齐:构造真 SDK 客户端。SDK 未装 / 私钥格式不对 / Root CA 缺失
    # → RuntimeError 向上抛,lifespan 启动失败(不降级 Mock,理由见 docstring)
    from .entitlement.apple_client import AppleServerAPIClient
    return AppleServerAPIClient(
        bundle_id=APP_STORE_BUNDLE_ID,  # type: ignore[arg-type]
        key_id=APP_STORE_KEY_ID,  # type: ignore[arg-type]
        issuer_id=APP_STORE_ISSUER_ID,  # type: ignore[arg-type]
        private_key=APP_STORE_PRIVATE_KEY,  # type: ignore[arg-type]
        environment=APP_STORE_ENVIRONMENT,  # type: ignore[arg-type]
        app_apple_id=APP_STORE_APP_APPLE_ID,  # type: ignore[arg-type]
    )


def _build_ai_client():
    return create_ai_client(
        provider=AI_PROVIDER,
        anthropic_api_key=ANTHROPIC_API_KEY,
        anthropic_model=ANTHROPIC_MODEL,
        anthropic_base_url=ANTHROPIC_BASE_URL,
        openai_api_key=OPENAI_API_KEY,
        openai_model=OPENAI_MODEL,
        openai_base_url=OPENAI_BASE_URL,
    )


app = FastAPI(title="QiCompass Bazi Backend", version=MODEL_ID, lifespan=lifespan)
# ASGITransport 单测不触发 lifespan;先挂默认实例,启动时再重建一次。
# entitlement_store / apple_server_api 也挂 fallback(测试 fixture 可覆盖)。
# ai_client 默认实例在下方 DB 目录就绪后统一挂 MeteredAIClient 包装版。
# 模块加载时确保 DB 目录存在(对齐 lifespan 内 makedirs,fix CI 全新 checkout
# 没有 data/ 目录导致 sqlite3 open 失败)。lifespan 内同名调用保留作 production
# startup 的 defense-in-depth。
_db_dir = os.path.dirname(DB_PATH)
if _db_dir:
    os.makedirs(_db_dir, exist_ok=True)
_default_entitlement_store = EntitlementStore(DB_PATH)
_default_entitlement_store.init_schema()
app.state.entitlement_store = _default_entitlement_store
# PR2.5:UserStore(同 DB_PATH,共用 SQLite 文件,不同表 qicompass_user)
from app.auth.user_store import UserStore  # noqa: E402
_default_user_store = UserStore(DB_PATH)
_default_user_store.init_schema()
app.state.user_store = _default_user_store
# PR3.1:UserChartSyncStore(命盘跨设备同步,同 DB_PATH)
from app.sync.store import UserChartSyncStore  # noqa: E402
_default_chart_sync_store = UserChartSyncStore(DB_PATH)
_default_chart_sync_store.init_schema()
app.state.user_chart_sync_store = _default_chart_sync_store
# 2026-10-07:免费 LLM 生成每日配额 store(同 DB_PATH,多 worker 共库计数)
from app.quota.store import FreeLLMQuotaStore  # noqa: E402
_default_free_quota_store = FreeLLMQuotaStore(DB_PATH)
_default_free_quota_store.init_schema()
app.state.free_quota_store = _default_free_quota_store
# 2026-10-09 监控:metrics store 默认实例 + 默认 ai_client 包 MeteredAIClient
# (ASGITransport 单测不触发 lifespan 也有监控;测试 fixture 整体替换
# app.state.ai_client 为裸 mock 时计数自然旁路,不影响行为断言)
from app.monitoring.metered import MeteredAIClient  # noqa: E402
from app.monitoring.store import LLMOutcomeStore  # noqa: E402
_default_llm_metrics_store = LLMOutcomeStore(DB_PATH)
_default_llm_metrics_store.init_schema()
app.state.llm_metrics_store = _default_llm_metrics_store
app.state.ai_client = MeteredAIClient(
    _build_ai_client(), _default_llm_metrics_store)
app.state.apple_server_api = MockAppleServerAPI()
# 测试环境 fallback:ASGITransport 单测不触发 lifespan,挂默认 singleflight 实例
# 避免路由层 AttributeError(与 cache / entitlement_store 同策略)
app.state.llm_singleflight = SingleflightCoalescer()
# S2 每日运势插画:同策略挂默认(测试 fixture 可覆盖 image_client 为 Mock)
_default_daily_image_cache = DailyImageCache(DB_PATH)
_default_daily_image_cache.init_schema()
app.state.daily_image_cache = _default_daily_image_cache
app.state.image_client = ImageGenClient(
    api_key=IMAGE_API_KEY, base_url=IMAGE_API_BASE_URL,
)
app.state.image_singleflight = SingleflightCoalescer()
app.add_middleware(RequestIdMiddleware)

app.include_router(health_api.router)
app.include_router(bazi_api.router)
app.include_router(compatibility_api.router)
app.include_router(daily_fortune_api.router)
app.include_router(daily_image_api.router)
app.include_router(interpret_api.router)
app.include_router(entitlement_api.router)
app.include_router(webhooks_api.router)
app.include_router(auth_api.router)
app.include_router(sync_api.router)


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
