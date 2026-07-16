"""POST /api/interpret 缓存行为测试。

验收用例(最终方案 §10):
1. test_cache_hit_zero_provider_calls(主验收):同请求两次,第二次 cached=True + provider 只调一次
5. test_daily_fortune_target_date_in_cache_key:同 hash 不同 target_date 各调一次;同 target_date 第二次命中
6. test_provider_failure_propagates:provider 失败 → 503,不写缓存
7. test_cache_failure_propagates:cache 异常 → 500,不静默走 provider
"""

from __future__ import annotations

import sqlite3
import hashlib
import logging

from httpx import ASGITransport, AsyncClient

from app.ai.prompts import render_prompt
from app.main import app
from tests.fixtures.interpret_cases import BAZI_DEEP_CONTEXT, DAILY_FORTUNE_CONTEXT


async def _post_interpret(ac: AsyncClient, payload: dict) -> tuple[int, dict]:
    resp = await ac.post("/api/interpret", json=payload)
    return resp.status_code, resp.json()


# ===== 1. 主验收:缓存命中 = 零 provider 调用 =====


async def test_cache_hit_zero_provider_calls(interpret_client, mock_ai_client):
    """同 content_hash + module 请求两次:
    - 第二次 response.cached == True
    - mock_ai_client.call_count == 1(只调一次 provider)
    """
    payload = {
        "content_hash": "test-hash-bazi-deep-001",
        "module": "bazi_deep",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
    }

    # 第一次:miss → 调 provider
    code1, body1 = await _post_interpret(interpret_client, payload)
    assert code1 == 200, body1
    assert body1["cached"] is False
    assert body1["interpretation"]
    assert body1["provider"] == mock_ai_client.provider
    assert body1["model"] == mock_ai_client.model
    assert mock_ai_client.call_count == 1

    # 第二次:hit → 不调 provider
    code2, body2 = await _post_interpret(interpret_client, payload)
    assert code2 == 200, body2
    assert body2["cached"] is True
    assert body2["interpretation"] == body1["interpretation"]
    assert body2["provider"] == mock_ai_client.provider
    assert body2["model"] == mock_ai_client.model
    assert mock_ai_client.call_count == 1, "缓存命中不应再调 provider"


async def test_provider_and_model_switch_do_not_reuse_cache(
    interpret_client, mock_ai_client,
):
    """同一业务键切换 provider/model 后必须重新生成。"""
    from tests.fixtures.mock_ai import MockAIClient

    payload = {
        "content_hash": "test-hash-provider-switch",
        "module": "bazi_deep",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
    }
    code1, first = await _post_interpret(interpret_client, payload)
    assert code1 == 200 and first["cached"] is False

    openai = MockAIClient(provider="openai", model="gpt-test")
    app.state.ai_client = openai
    try:
        code2, second = await _post_interpret(interpret_client, payload)
        assert code2 == 200, second
        assert second["cached"] is False
        assert second["provider"] == "openai"
        assert second["model"] == "gpt-test"
        assert openai.call_count == 1

        code3, third = await _post_interpret(interpret_client, payload)
        assert code3 == 200 and third["cached"] is True
        assert openai.call_count == 1
    finally:
        app.state.ai_client = mock_ai_client


async def test_same_content_hash_different_context_does_not_hit_cache(
    interpret_client, mock_ai_client,
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
    assert mock_ai_client.call_count == 2

    code3, body3 = await _post_interpret(interpret_client, payload)
    assert code3 == 200, body3
    assert body3["cached"] is True
    assert mock_ai_client.call_count == 2


async def test_interpret_logs_context_without_prompt_or_secrets(
    interpret_client, mock_ai_client, caplog,
):
    """关键日志含身份/业务上下文/耗时,但不泄露 prompt 或认证信息。"""
    caplog.set_level(logging.INFO, logger="app.api.interpret")
    secret_marker = "PROMPT_SECRET_MARKER_DO_NOT_LOG"
    payload = {
        "content_hash": "test-hash-log-redaction",
        "module": "bazi_deep",
        "context": {**BAZI_DEEP_CONTEXT, "city": secret_marker},
        "target_date": None,
    }

    code, body = await _post_interpret(interpret_client, payload)

    assert code == 200, body
    logs = caplog.text
    for expected in (
        "request_id", "test-hash-log-redaction", "bazi_deep",
        "prompt_version", "prompt_hash", mock_ai_client.provider,
        mock_ai_client.model, "elapsed_ms",
    ):
        assert expected in logs
    assert secret_marker not in logs
    assert "Authorization" not in logs
    assert "ANTHROPIC_API_KEY" not in logs
    assert "OPENAI_API_KEY" not in logs

# ===== 5. daily_fortune 的 target_date 进缓存键 =====


async def test_daily_fortune_target_date_in_cache_key(interpret_client,
                                                       mock_ai_client):
    """同 content_hash 不同 target_date → 两次都调 provider;
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
    assert mock_ai_client.call_count == 2

    # 同 target_date → hit
    code3, b3 = await _post_interpret(interpret_client, p1)
    assert code3 == 200
    assert b3["cached"] is True
    assert mock_ai_client.call_count == 2, "同 target_date 应命中缓存"


# ===== 6. provider 失败 → 503 + 不写缓存 =====


async def test_provider_failure_propagates(tmp_cache):
    """mock provider 抛 AIProviderError → 503,且缓存中无条目。"""
    from tests.fixtures.mock_ai import FailingAIClient

    failing = FailingAIClient()
    saved_cache = getattr(app.state, "cache", None)
    saved_ai = getattr(app.state, "ai_client", None)
    app.state.cache = tmp_cache
    app.state.ai_client = failing

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            payload = {
                "content_hash": "test-hash-provider-fail",
                "module": "bazi_deep",
                "context": BAZI_DEEP_CONTEXT,
                "target_date": None,
            }
            code, body = await _post_interpret(ac, payload)
        assert code == 503, body
        assert body["error"]["code"] == "AI_PROVIDER_ERROR"
        assert "mock AI provider failure" in body["error"]["message"]
        # 不写缓存
        prompt_hash = hashlib.sha256(
            render_prompt("bazi_deep", BAZI_DEEP_CONTEXT).encode("utf-8")
        ).hexdigest()
        row = tmp_cache.get(content_hash="test-hash-provider-fail",
                            module="bazi_deep", prompt_version=1,
                            target_date=None, prompt_hash=prompt_hash,
                            provider=failing.provider, model=failing.model)
        assert row is None, "provider 失败时不应写缓存"
    finally:
        app.state.cache = saved_cache
        app.state.ai_client = saved_ai


# ===== 7. cache 异常 → 500 + 不静默走 provider =====


async def test_cache_get_failure_propagates(tmp_cache, mock_ai_client):
    """cache.get 抛 sqlite3 异常 → 500,不降级为 provider 调用。"""
    saved_cache = getattr(app.state, "cache", None)
    saved_ai = getattr(app.state, "ai_client", None)
    app.state.cache = tmp_cache
    app.state.ai_client = mock_ai_client

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
        # 不应调 provider(缓存读失败应直接报错,不降级)
        assert mock_ai_client.call_count == 0, "缓存读失败不应降级走 provider"
    finally:
        tmp_cache.get = original_get
        app.state.cache = saved_cache
        app.state.ai_client = saved_ai


async def test_cache_set_failure_propagates(tmp_cache):
    """cache.set 抛 sqlite3 异常 → 500,不返回"成功但没缓存"。"""
    from tests.fixtures.mock_ai import MockAIClient

    mock = MockAIClient()
    saved_cache = getattr(app.state, "cache", None)
    saved_ai = getattr(app.state, "ai_client", None)
    app.state.cache = tmp_cache
    app.state.ai_client = mock

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
        app.state.ai_client = saved_ai


# ===== 8. 禁词拦截:provider 返回禁词 → 422 + 不写缓存 =====


async def test_provider_returns_forbidden_words_returns_422(tmp_cache):
    """mock provider 返回含禁词的文本 → 422,且缓存中无条目。"""
    from tests.fixtures.mock_ai import MockAIClient

    mock = MockAIClient(response="你们必定会在一起,百分之百的")
    saved_cache = getattr(app.state, "cache", None)
    saved_ai = getattr(app.state, "ai_client", None)
    app.state.cache = tmp_cache
    app.state.ai_client = mock

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            payload = {
                "content_hash": "test-hash-forbidden-provider",
                "module": "bazi_deep",
                "context": BAZI_DEEP_CONTEXT,
                "target_date": None,
            }
            code, body = await _post_interpret(ac, payload)
        assert code == 422, body
        assert body["error"]["code"] == "INTERPRETATION_FORBIDDEN"
        assert "禁词" in body["error"]["message"]
        assert body["error"]["request_id"]
        assert body["error"]["content_hash"] == "test-hash-forbidden-provider"
        # 不写缓存
        prompt_hash = hashlib.sha256(
            render_prompt("bazi_deep", BAZI_DEEP_CONTEXT).encode("utf-8")
        ).hexdigest()
        row = tmp_cache.get(content_hash="test-hash-forbidden-provider",
                            module="bazi_deep", prompt_version=1,
                            target_date=None, prompt_hash=prompt_hash,
                            provider=mock.provider, model=mock.model)
        assert row is None, "禁词命中时不应写缓存"
    finally:
        app.state.cache = saved_cache
        app.state.ai_client = saved_ai


# ===== 9. 禁词拦截:缓存命中禁词 → 422 + 删除坏缓存 =====


async def test_cache_hit_forbidden_words_returns_422_and_deletes(tmp_cache):
    """缓存中已有含禁词的条目 → 422,且该条目被删除(下次请求重新调 provider)。"""
    from tests.fixtures.mock_ai import MockAIClient

    mock = MockAIClient(response="正常文本,无禁词")
    saved_cache = getattr(app.state, "cache", None)
    saved_ai = getattr(app.state, "ai_client", None)
    app.state.cache = tmp_cache
    app.state.ai_client = mock

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
        provider=mock.provider,
        model=mock.model,
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
                            target_date=None, prompt_hash=prompt_hash,
                            provider=mock.provider, model=mock.model)
        assert row is None, "禁词命中的坏缓存应被删除"
    finally:
        app.state.cache = saved_cache
        app.state.ai_client = saved_ai
