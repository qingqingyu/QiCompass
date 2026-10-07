"""根级 conftest:共享 fixtures。"""

from __future__ import annotations

import json
import os
import uuid
from datetime import datetime, timedelta, timezone

# PR2.5:测试默认设 JWT_SECRET_KEY(必须在 import app.config 之前;
# app.config 模块加载时校验缺失会启动失败)
os.environ.setdefault("JWT_SECRET_KEY", "test-secret-fixed-for-pytest-do-not-use-in-prod")
# 2026-10-07:Mock Apple 默认放行(测试环境;生产缺 env = 锁定 503,
# 见 entitlement/protocol.py);context_token 密钥从 JWT_SECRET_KEY 派生
os.environ.setdefault("QICOMPASS_ALLOW_MOCK_APPLE", "1")

import pytest  # noqa: E402


async def _auto_context_token_hook(request) -> None:
    """测试自动签发钩子(2026-10-07 P0 收口配套,**仅测试环境**)。

    对 POST /api/interpret(+/translate、/api/bazi/compatibility、
    /api/bazi/daily-fortune)缺 context_token 的请求体自动补一枚按其
    context/payload 签发的合法 token——等价「合法客户端存档回传」,
    存量行为测试无需逐处改造。已显式携带 token 的请求不动(安全测试
    传伪造/篡改 token 不受影响);**缺 token 的 403 行为测试须用
    raw_interpret_client**(无本钩子)。AsyncClient 的 request 钩子须为
    async callable。
    """
    try:
        body = json.loads(request.content.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return
    if not isinstance(body, dict) or "context_token" in body:
        return
    from tests.fixtures.context_token_helper import (
        payload_token_for, token_for_context,
    )
    path = request.url.path
    try:
        if path in ("/api/interpret", "/api/interpret/translate"):
            if "module" not in body or "context" not in body:
                return
            td = body.get("target_date")
            body["context_token"] = token_for_context(
                content_hash=body["content_hash"], module=body["module"],
                context=body["context"],
                target_date_iso=(
                    td if isinstance(td, str) else td.isoformat()
                ) if td else None)
        elif path == "/api/bazi/compatibility":
            if "chart_payload_a" not in body or "context_token_a" in body:
                return
            body["context_token_a"] = payload_token_for(
                content_hash=body["person_a_hash"],
                chart_payload=body["chart_payload_a"])
            if body.get("person_b_hash") and body.get("chart_payload_b"):
                body["context_token_b"] = payload_token_for(
                    content_hash=body["person_b_hash"],
                    chart_payload=body["chart_payload_b"])
        elif path == "/api/bazi/daily-fortune":
            if "chart_payload" not in body:
                return
            body["context_token"] = payload_token_for(
                content_hash=body["chart_hash"],
                chart_payload=body["chart_payload"])
        else:
            return
    except (KeyError, ValueError, json.JSONDecodeError):
        return  # 缺关键要素的请求留给端点按原语义报错(422 等)
    from httpx._content import ByteStream
    request._content = json.dumps(body).encode("utf-8")
    request.stream = ByteStream(request._content)
    request.headers["content-length"] = str(len(request._content))


@pytest.fixture
def fixed_now() -> datetime:
    """固定「当前时间」(2026-07-12 12:00 +08:00),供 current_*_pillar 测试。

    选 7 月 12 日确保 current_year_pillar = 丙午(2026 立春后)稳定。
    """
    tz = timezone(timedelta(hours=8))
    return datetime(2026, 7, 12, 12, 0, tzinfo=tz)


@pytest.fixture
def request_id() -> str:
    """固定 request_id,便于断言错误响应。"""
    return "test-req-fixed-0001"


@pytest.fixture
def tz8():
    return timezone(timedelta(hours=8))


# ---------- /api/interpret 测试 fixtures ----------

from tests.fixtures.mock_ai import MockAIClient  # noqa: E402


@pytest.fixture
def mock_ai_client() -> MockAIClient:
    """默认 mock:返回固定文本,计数调用次数。"""
    return MockAIClient()


@pytest.fixture
def tmp_cache(tmp_path) -> "InterpretationCache":
    """临时 SQLite 缓存(用 tmp_path,测完即弃)。

    Returns:
        已 init_schema 的 InterpretationCache
    """
    from app.ai.cache import InterpretationCache
    cache = InterpretationCache(str(tmp_path / "test_interpret.db"))
    cache.init_schema()
    return cache


@pytest.fixture
def tmp_entitlement_store(tmp_path) -> "EntitlementStore":
    """临时 EntitlementStore(用 tmp_path,测完即弃)。

    与 tmp_cache 共用同一 tmp_path 目录但不同 db 文件,避免表锁冲突。
    """
    from app.entitlement import EntitlementStore
    store = EntitlementStore(str(tmp_path / "test_entitlement.db"))
    store.init_schema()
    return store


@pytest.fixture
def tmp_free_quota_store(tmp_path):
    """临时 FreeLLMQuotaStore(2026-10-07;每测试独立,互不污染计数)。"""
    from app.quota.store import FreeLLMQuotaStore
    store = FreeLLMQuotaStore(str(tmp_path / "test_free_quota.db"))
    store.init_schema()
    return store


@pytest.fixture(autouse=True)
def _isolated_free_quota_store(tmp_free_quota_store):
    """autouse:免费配额 store 全测试隔离(2026-10-07 review 轮发现)。

    裸 AsyncClient 测试(test_interpret_cache / test_interpret_prompt_version
    等自建 client)不经 interpret_client / raw_interpret_client fixture——
    若不在此兜底替换,免费 module 请求会打到模块级默认 store
    (data/qicompass.db):计数跨运行累积,当天满 30 后这些测试全量假红
    429,且污染 dev DB。autouse 保证无论测试用哪种 client 都不落真实库;
    显式 fixture(interpret_client 等)随后的替换在其之上,teardown 逆序
    恢复无冲突。
    """
    from app.main import app
    saved = getattr(app.state, "free_quota_store", None)
    app.state.free_quota_store = tmp_free_quota_store
    yield
    app.state.free_quota_store = saved


@pytest.fixture
async def interpret_client(mock_ai_client, tmp_cache, tmp_entitlement_store,
                           tmp_free_quota_store):
    """FastAPI TestClient(ASGITransport),app.state 替换为 mock + tmp_db。

    同时替换 cache + entitlement_store + free_quota_store + ai_client,
    确保测试隔离。

    用法:
        async with interpret_client as ac:
            resp = await ac.post("/api/interpret", json={...})
    """
    from httpx import ASGITransport, AsyncClient
    from app.main import app

    # 保存原始 state(测试后恢复,避免污染其他测试)
    saved_cache = getattr(app.state, "cache", None)
    saved_ai = getattr(app.state, "ai_client", None)
    saved_entitlement = getattr(app.state, "entitlement_store", None)
    saved_sf = getattr(app.state, "llm_singleflight", None)
    saved_quota = getattr(app.state, "free_quota_store", None)

    # 每个测试用独立 singleflight 实例,避免 inflight 跨测试残留
    from app.ai.singleflight import SingleflightCoalescer
    app.state.cache = tmp_cache
    app.state.ai_client = mock_ai_client
    app.state.entitlement_store = tmp_entitlement_store
    app.state.llm_singleflight = SingleflightCoalescer()
    app.state.free_quota_store = tmp_free_quota_store

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test",
                               event_hooks={"request": [_auto_context_token_hook]}
                               ) as ac:
            yield ac
    finally:
        app.state.cache = saved_cache
        app.state.ai_client = saved_ai
        app.state.entitlement_store = saved_entitlement
        app.state.llm_singleflight = saved_sf
        app.state.free_quota_store = saved_quota


@pytest.fixture
async def raw_interpret_client(mock_ai_client, tmp_cache,
                               tmp_entitlement_store, tmp_free_quota_store):
    """无自动签发钩子的 interpret client(安全测试专用:缺 token / 伪 token 行为)。

    与 interpret_client 同构(app.state 全替换),唯一差别:请求体缺
    context_token 不自动补——用于断言 403 CONTEXT_TOKEN_REQUIRED /
    CONTEXT_TOKEN_INVALID 的真实攻击面。
    """
    from httpx import ASGITransport, AsyncClient
    from app.main import app

    saved_cache = getattr(app.state, "cache", None)
    saved_ai = getattr(app.state, "ai_client", None)
    saved_entitlement = getattr(app.state, "entitlement_store", None)
    saved_sf = getattr(app.state, "llm_singleflight", None)
    saved_quota = getattr(app.state, "free_quota_store", None)

    from app.ai.singleflight import SingleflightCoalescer
    app.state.cache = tmp_cache
    app.state.ai_client = mock_ai_client
    app.state.entitlement_store = tmp_entitlement_store
    app.state.llm_singleflight = SingleflightCoalescer()
    app.state.free_quota_store = tmp_free_quota_store

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            yield ac
    finally:
        app.state.cache = saved_cache
        app.state.ai_client = saved_ai
        app.state.entitlement_store = saved_entitlement
        app.state.llm_singleflight = saved_sf
        app.state.free_quota_store = saved_quota
