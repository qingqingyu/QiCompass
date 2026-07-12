"""POST /api/interpret prompt_version 失效 + 请求校验测试。

验收用例(最终方案 §10):
2. test_prompt_version_invalidation(主验收):bump version → 老缓存失效重调 Claude
8. test_target_date_module_mismatch:bazi_deep + target_date 非空 → 422
9. test_context_missing_fields:context 缺字段 → 422,错误信息含字段名
10. test_api_key_not_configured:api_key=None → 503
"""

from __future__ import annotations

from httpx import ASGITransport, AsyncClient

from app.ai.prompts import PROMPT_VERSIONS
from app.main import app
from app.models.interpret import InterpretRequest
from tests.fixtures.interpret_cases import BAZI_DEEP_CONTEXT


async def _post_interpret(ac: AsyncClient, payload: dict) -> tuple[int, dict]:
    resp = await ac.post("/api/interpret", json=payload)
    return resp.status_code, resp.json()


# ===== 2. 主验收:prompt_version 失效 =====


async def test_prompt_version_invalidation(interpret_client, mock_claude_client,
                                            monkeypatch):
    """bump prompt_version → 老缓存失效重调 Claude;新版本再请求命中。"""
    payload = {
        "content_hash": "test-hash-version-001",
        "module": "bazi_deep",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
    }

    # 第一次:v1 miss → 调 Claude
    assert PROMPT_VERSIONS["bazi_deep"] == 1
    code1, b1 = await _post_interpret(interpret_client, payload)
    assert code1 == 200, b1
    assert b1["cached"] is False
    assert b1["prompt_version"] == 1
    assert mock_claude_client.call_count == 1

    # bump version 1 → 2
    monkeypatch.setitem(PROMPT_VERSIONS, "bazi_deep", 2)

    # 同 content_hash 再请求:v2 miss(老 v1 缓存不命中)→ 重调 Claude
    code2, b2 = await _post_interpret(interpret_client, payload)
    assert code2 == 200, b2
    assert b2["cached"] is False
    assert b2["prompt_version"] == 2
    assert mock_claude_client.call_count == 2

    # 再请求一次:v2 hit
    code3, b3 = await _post_interpret(interpret_client, payload)
    assert code3 == 200, b3
    assert b3["cached"] is True
    assert b3["prompt_version"] == 2
    assert mock_claude_client.call_count == 2, "v2 缓存命中不应再调 Claude"


# ===== 8. target_date 与 module 不匹配 → 422 =====


async def test_target_date_module_mismatch(interpret_client):
    """module=bazi_deep + target_date 非空 → 422。"""
    payload = {
        "content_hash": "test-hash-mismatch",
        "module": "bazi_deep",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": "2026-07-12",  # bazi_deep 不应有 target_date
    }
    code, body = await _post_interpret(interpret_client, payload)
    assert code == 422, body
    assert body["error"]["code"] == "INVALID_INPUT"


async def test_daily_fortune_without_target_date_returns_422(interpret_client):
    """module=daily_fortune + target_date=null → 422。"""
    from tests.fixtures.interpret_cases import DAILY_FORTUNE_CONTEXT
    payload = {
        "content_hash": "test-hash-no-date",
        "module": "daily_fortune",
        "context": DAILY_FORTUNE_CONTEXT,
        "target_date": None,  # daily_fortune 必须有 target_date
    }
    code, body = await _post_interpret(interpret_client, payload)
    assert code == 422, body
    assert body["error"]["code"] == "INVALID_INPUT"


# ===== 9. context 缺字段 → 422,错误信息含字段名 =====


async def test_context_missing_fields(interpret_client):
    """bazi_deep context 缺 favorable_elements → 422,message 含缺失字段名。"""
    incomplete_context = {k: v for k, v in BAZI_DEEP_CONTEXT.items()
                         if k != "favorable_elements"}
    payload = {
        "content_hash": "test-hash-missing-fields",
        "module": "bazi_deep",
        "context": incomplete_context,
        "target_date": None,
    }
    code, body = await _post_interpret(interpret_client, payload)
    assert code == 422, body
    assert body["error"]["code"] == "INVALID_INPUT"
    assert "favorable_elements" in body["error"]["message"], \
        "错误信息必须含缺失字段名"


async def test_blank_content_hash_returns_422(interpret_client):
    """content_hash 不能为空白,否则缓存键无意义。"""
    payload = {
        "content_hash": "   ",
        "module": "bazi_deep",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
    }
    code, body = await _post_interpret(interpret_client, payload)
    assert code == 422, body
    assert body["error"]["code"] == "INVALID_INPUT"
    assert "content_hash" in body["error"]["message"]


def test_content_hash_is_stripped_before_cache_key():
    """content_hash 首尾空白应规范化,避免无意义缓存键差异。"""
    req = InterpretRequest(
        content_hash="  test-hash-strip  ",
        module="bazi_deep",
        context=BAZI_DEEP_CONTEXT,
        target_date=None,
    )
    assert req.content_hash == "test-hash-strip"


# ===== 10. ANTHROPIC_API_KEY 未配置 → 503 =====


async def test_api_key_not_configured(tmp_cache):
    """ClaudeClient(api_key=None) → 调 /api/interpret 返回 503。"""
    from app.ai.claude_client import ClaudeClient

    no_key_client = ClaudeClient(api_key=None)
    saved_cache = getattr(app.state, "cache", None)
    saved_claude = getattr(app.state, "claude_client", None)
    app.state.cache = tmp_cache
    app.state.claude_client = no_key_client

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            payload = {
                "content_hash": "test-hash-no-key",
                "module": "bazi_deep",
                "context": BAZI_DEEP_CONTEXT,
                "target_date": None,
            }
            code, body = await _post_interpret(ac, payload)
        assert code == 503, body
        assert body["error"]["code"] == "CLAUDE_API_ERROR"
        assert "ANTHROPIC_API_KEY not configured" in body["error"]["message"]
    finally:
        app.state.cache = saved_cache
        app.state.claude_client = saved_claude


async def test_interpret_generated_at_no_microseconds(interpret_client,
                                                       mock_claude_client):
    """generated_at 序列化不含微秒(iOS .iso8601 dateDecodingStrategy 不支持小数秒)。"""
    payload = {
        "content_hash": "test-hash-no-microseconds",
        "module": "bazi_deep",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
    }
    code, body = await _post_interpret(interpret_client, payload)
    assert code == 200, body
    ga = body["generated_at"]
    assert "." not in ga, f"generated_at 含微秒(iOS 解码会失败): {ga}"
