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
    assert body["ai_provider"] == app.state.ai_client.provider
    assert body["ai_model"] == app.state.ai_client.model
    assert resp.headers["Cache-Control"] == "no-store"


async def test_health_has_request_id_header():
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        resp = await ac.get("/api/health")
    assert "X-Request-ID" in resp.headers


async def test_health_returns_prompt_versions():
    """prompt_versions 快照(2026-10-08 外评 #4):iOS 读本地解读缓存前的
    health 强校验顺带取得各模块当前版本——本地行只认服务端当前版本,封掉
    「prompt bump 只失效后端缓存,客户端 24h 旧版行照常命中」的失防窗口。
    """
    from app.ai.prompts import PROMPT_VERSIONS
    async with AsyncClient(transport=ASGITransport(app=app),
                           base_url="http://test") as ac:
        resp = await ac.get("/api/health")
    assert resp.status_code == 200
    assert resp.json()["prompt_versions"] == dict(PROMPT_VERSIONS)
