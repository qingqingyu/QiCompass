"""GET /api/health 测试。"""

from __future__ import annotations

from httpx import ASGITransport, AsyncClient

from app.config import LUNAR_PYTHON_VERSION, MODEL_ID
from app.main import app


async def test_health_returns_ok():
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        resp = await ac.get("/api/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["lunar_python_version"] == LUNAR_PYTHON_VERSION
    assert body["model"] == MODEL_ID


async def test_health_has_request_id_header():
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        resp = await ac.get("/api/health")
    assert "X-Request-ID" in resp.headers
