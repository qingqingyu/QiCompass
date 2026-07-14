"""POST /api/interpret 缓存行为测试。

验收用例(最终方案 §10):
1. test_cache_hit_zero_claude_calls(主验收):同请求两次,第二次 cached=True + Claude 只调一次
5. test_daily_fortune_target_date_in_cache_key:同 hash 不同 target_date 各调一次;同 target_date 第二次命中
6. test_claude_failure_propagates:Claude 失败 → 503,不写缓存
7. test_cache_failure_propagates:cache 异常 → 500,不静默走 Claude
"""

from __future__ import annotations

import sqlite3
import hashlib

from httpx import ASGITransport, AsyncClient

from app.ai.prompts import render_prompt
from app.main import app
from tests.fixtures.interpret_cases import BAZI_DEEP_CONTEXT, DAILY_FORTUNE_CONTEXT


async def _post_interpret(ac: AsyncClient, payload: dict) -> tuple[int, dict]:
    resp = await ac.post("/api/interpret", json=payload)
    return resp.status_code, resp.json()


# ===== 1. 主验收:缓存命中 = 零 Claude 调用 =====


async def test_cache_hit_zero_claude_calls(interpret_client, mock_claude_client):
    """同 content_hash + module 请求两次:
    - 第二次 response.cached == True
    - mock_claude_client.call_count == 1(只调一次 Claude)
    """
    payload = {
        "content_hash": "test-hash-bazi-deep-001",
        "module": "bazi_deep",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
    }

    # 第一次:miss → 调 Claude
    code1, body1 = await _post_interpret(interpret_client, payload)
    assert code1 == 200, body1
    assert body1["cached"] is False
    assert body1["interpretation"]
    assert mock_claude_client.call_count == 1

    # 第二次:hit → 不调 Claude
    code2, body2 = await _post_interpret(interpret_client, payload)
    assert code2 == 200, body2
    assert body2["cached"] is True
    assert body2["interpretation"] == body1["interpretation"]
    assert mock_claude_client.call_count == 1, "缓存命中不应再调 Claude"


async def test_same_content_hash_different_context_does_not_hit_cache(
    interpret_client, mock_claude_client,
):
    """同 content_hash 但 context 不同必须重新生成,避免污染跨用户缓存。"""
    payload = {
        "content_hash": "test-hash-context-poisoning",
        "module": "bazi_deep",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
    }
    changed_context = {
        **BAZI_DEEP_CONTEXT,
        "favorable_elements": "木, 水",
    }
    changed_payload = {**payload, "context": changed_context}

    code1, body1 = await _post_interpret(interpret_client, payload)
    assert code1 == 200, body1
    assert body1["cached"] is False

    code2, body2 = await _post_interpret(interpret_client, changed_payload)
    assert code2 == 200, body2
    assert body2["cached"] is False
    assert mock_claude_client.call_count == 2

    code3, body3 = await _post_interpret(interpret_client, payload)
    assert code3 == 200, body3
    assert body3["cached"] is True
    assert mock_claude_client.call_count == 2


# ===== 5. daily_fortune 的 target_date 进缓存键 =====


async def test_daily_fortune_target_date_in_cache_key(interpret_client,
                                                       mock_claude_client):
    """同 content_hash 不同 target_date → 两次都调 Claude;
    同 target_date 第二次命中。
    """
    base = {
        "content_hash": "test-hash-daily-001",
        "module": "daily_fortune",
        "context": DAILY_FORTUNE_CONTEXT,
    }

    # 不同 target_date → 都 miss
    p1 = {**base, "target_date": "2026-07-12"}
    p2 = {**base, "target_date": "2026-07-13"}
    code1, b1 = await _post_interpret(interpret_client, p1)
    code2, b2 = await _post_interpret(interpret_client, p2)
    assert code1 == 200 and code2 == 200
    assert b1["cached"] is False
    assert b2["cached"] is False
    assert mock_claude_client.call_count == 2

    # 同 target_date → hit
    code3, b3 = await _post_interpret(interpret_client, p1)
    assert code3 == 200
    assert b3["cached"] is True
    assert mock_claude_client.call_count == 2, "同 target_date 应命中缓存"


# ===== 6. Claude 失败 → 503 + 不写缓存 =====


async def test_claude_failure_propagates(tmp_cache):
    """mock Claude 抛 ClaudeAPIError → 503,且缓存中无条目。"""
    from tests.fixtures.mock_claude import FailingClaudeClient

    failing = FailingClaudeClient()
    saved_cache = getattr(app.state, "cache", None)
    saved_claude = getattr(app.state, "claude_client", None)
    app.state.cache = tmp_cache
    app.state.claude_client = failing

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            payload = {
                "content_hash": "test-hash-claude-fail",
                "module": "bazi_deep",
                "context": BAZI_DEEP_CONTEXT,
                "target_date": None,
            }
            code, body = await _post_interpret(ac, payload)
        assert code == 503, body
        assert body["error"]["code"] == "CLAUDE_API_ERROR"
        assert "mock Claude failure" in body["error"]["message"]
        # 不写缓存
        prompt_hash = hashlib.sha256(
            render_prompt("bazi_deep", BAZI_DEEP_CONTEXT).encode("utf-8")
        ).hexdigest()
        row = tmp_cache.get(content_hash="test-hash-claude-fail",
                            module="bazi_deep", prompt_version=1,
                            target_date=None, prompt_hash=prompt_hash)
        assert row is None, "Claude 失败时不应写缓存"
    finally:
        app.state.cache = saved_cache
        app.state.claude_client = saved_claude


# ===== 7. cache 异常 → 500 + 不静默走 Claude =====


async def test_cache_get_failure_propagates(tmp_cache, mock_claude_client):
    """cache.get 抛 sqlite3 异常 → 500,不降级为 Claude 调用。"""
    saved_cache = getattr(app.state, "cache", None)
    saved_claude = getattr(app.state, "claude_client", None)
    app.state.cache = tmp_cache
    app.state.claude_client = mock_claude_client

    # 让 cache.get 抛异常
    def boom_get(**kwargs):
        raise sqlite3.OperationalError("forced cache read failure")

    original_get = tmp_cache.get
    tmp_cache.get = boom_get

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            payload = {
                "content_hash": "test-hash-cache-fail",
                "module": "bazi_deep",
                "context": BAZI_DEEP_CONTEXT,
                "target_date": None,
            }
            code, body = await _post_interpret(ac, payload)
        assert code == 500, body
        assert body["error"]["code"] == "INTERPRETATION_CACHE_ERROR"
        # 不应调 Claude(缓存读失败应直接报错,不降级)
        assert mock_claude_client.call_count == 0, "缓存读失败不应降级走 Claude"
    finally:
        tmp_cache.get = original_get
        app.state.cache = saved_cache
        app.state.claude_client = saved_claude


async def test_cache_set_failure_propagates(tmp_cache):
    """cache.set 抛 sqlite3 异常 → 500,不返回"成功但没缓存"。"""
    from tests.fixtures.mock_claude import MockClaudeClient

    mock = MockClaudeClient()
    saved_cache = getattr(app.state, "cache", None)
    saved_claude = getattr(app.state, "claude_client", None)
    app.state.cache = tmp_cache
    app.state.claude_client = mock

    # cache.get 正常返回 None(miss),但 cache.set 抛异常
    def boom_set(**kwargs):
        raise sqlite3.OperationalError("forced cache write failure")

    original_set = tmp_cache.set
    tmp_cache.set = boom_set

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            payload = {
                "content_hash": "test-hash-cache-set-fail",
                "module": "bazi_deep",
                "context": BAZI_DEEP_CONTEXT,
                "target_date": None,
            }
            code, body = await _post_interpret(ac, payload)
        assert code == 500, body
        assert body["error"]["code"] == "INTERPRETATION_CACHE_ERROR"
        assert "写失败" in body["error"]["message"]
    finally:
        tmp_cache.set = original_set
        app.state.cache = saved_cache
        app.state.claude_client = saved_claude


# ===== 8. 禁词拦截:Claude 返回禁词 → 422 + 不写缓存 =====


async def test_claude_returns_forbidden_words_returns_422(tmp_cache):
    """mock Claude 返回含禁词的文本 → 422,且缓存中无条目。"""
    from tests.fixtures.mock_claude import MockClaudeClient

    mock = MockClaudeClient(response="你们必定会在一起,百分之百的")
    saved_cache = getattr(app.state, "cache", None)
    saved_claude = getattr(app.state, "claude_client", None)
    app.state.cache = tmp_cache
    app.state.claude_client = mock

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            payload = {
                "content_hash": "test-hash-forbidden-claude",
                "module": "bazi_deep",
                "context": BAZI_DEEP_CONTEXT,
                "target_date": None,
            }
            code, body = await _post_interpret(ac, payload)
        assert code == 422, body
        assert body["error"]["code"] == "INTERPRETATION_FORBIDDEN"
        assert "禁词" in body["error"]["message"]
        assert body["error"]["request_id"]
        assert body["error"]["content_hash"] == "test-hash-forbidden-claude"
        # 不写缓存
        prompt_hash = hashlib.sha256(
            render_prompt("bazi_deep", BAZI_DEEP_CONTEXT).encode("utf-8")
        ).hexdigest()
        row = tmp_cache.get(content_hash="test-hash-forbidden-claude",
                            module="bazi_deep", prompt_version=1,
                            target_date=None, prompt_hash=prompt_hash)
        assert row is None, "禁词命中时不应写缓存"
    finally:
        app.state.cache = saved_cache
        app.state.claude_client = saved_claude


# ===== 9. 禁词拦截:缓存命中禁词 → 422 + 删除坏缓存 =====


async def test_cache_hit_forbidden_words_returns_422_and_deletes(tmp_cache):
    """缓存中已有含禁词的条目 → 422,且该条目被删除(下次请求重新调 Claude)。"""
    from tests.fixtures.mock_claude import MockClaudeClient

    mock = MockClaudeClient(response="正常文本,无禁词")
    saved_cache = getattr(app.state, "cache", None)
    saved_claude = getattr(app.state, "claude_client", None)
    app.state.cache = tmp_cache
    app.state.claude_client = mock

    content_hash = "test-hash-forbidden-cache"
    prompt_hash = hashlib.sha256(
        render_prompt("bazi_deep", BAZI_DEEP_CONTEXT).encode("utf-8")
    ).hexdigest()

    # 预置含禁词的坏缓存
    tmp_cache.set(
        content_hash=content_hash,
        module="bazi_deep",
        prompt_version=1,
        target_date=None,
        prompt_hash=prompt_hash,
        model="test-model",
        interpretation="你们必定会在一起,注定如此",
        generated_at="2026-01-01T00:00:00+00:00",
    )

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            payload = {
                "content_hash": content_hash,
                "module": "bazi_deep",
                "context": BAZI_DEEP_CONTEXT,
                "target_date": None,
            }
            code, body = await _post_interpret(ac, payload)
        assert code == 422, body
        assert body["error"]["code"] == "INTERPRETATION_FORBIDDEN"
        assert body["error"]["content_hash"] == content_hash

        # 坏缓存应被删除
        row = tmp_cache.get(content_hash=content_hash,
                            module="bazi_deep", prompt_version=1,
                            target_date=None, prompt_hash=prompt_hash)
        assert row is None, "禁词命中的坏缓存应被删除"
    finally:
        app.state.cache = saved_cache
        app.state.claude_client = saved_claude
