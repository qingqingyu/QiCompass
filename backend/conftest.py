"""根级 conftest:共享 fixtures。"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest


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
async def interpret_client(mock_ai_client, tmp_cache):
    """FastAPI TestClient(ASGITransport),app.state 替换为 mock + tmp_db。

    用法:
        async with interpret_client as ac:
            resp = await ac.post("/api/interpret", json={...})
    """
    from httpx import ASGITransport, AsyncClient
    from app.main import app

    # 保存原始 state(测试后恢复,避免污染其他测试)
    saved_cache = getattr(app.state, "cache", None)
    saved_ai = getattr(app.state, "ai_client", None)

    app.state.cache = tmp_cache
    app.state.ai_client = mock_ai_client

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            yield ac
    finally:
        app.state.cache = saved_cache
        app.state.ai_client = saved_ai
