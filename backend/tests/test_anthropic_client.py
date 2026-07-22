"""AnthropicClient 外部请求/响应边界测试。

注:`interpret` 是 async(client 走 httpx.AsyncClient),所有用例需 await。
monkeypatch 策略:替换 `anthropic_module.httpx.AsyncClient` 为 fake 类,
其 `.post()` 直接调测试注入的 handler,不真发网络请求。
"""

from __future__ import annotations

import pytest

from app.ai import anthropic_client as anthropic_module
from app.ai.anthropic_client import AnthropicClient
from app.errors import AIProviderError


class _FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self):
        return self._payload


def _install_fake_async_client(monkeypatch, handler):
    """把 anthropic_module.httpx.AsyncClient 替换成走 handler 的假 client。

    handler: (url, **kwargs) -> _FakeResponse 或 raise 异常
    """

    class _FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            pass  # 忽略 timeout 等参数(测试不关心)

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def post(self, url, **kwargs):
            return handler(url, **kwargs)

    monkeypatch.setattr(anthropic_module.httpx, "AsyncClient", _FakeAsyncClient)


async def test_anthropic_client_request_contract(monkeypatch):
    captured = {}

    def handler(url, **kwargs):
        captured.update(url=url, **kwargs)
        return _FakeResponse({"content": [{"type": "text", "text": "命书"}]})

    _install_fake_async_client(monkeypatch, handler)
    client = AnthropicClient(api_key="secret", model="claude-test")

    assert await client.interpret("prompt") == "命书"
    assert client.provider == "anthropic"
    assert client.model == "claude-test"
    assert captured["url"] == "https://api.anthropic.com/v1/messages"
    assert captured["headers"]["x-api-key"] == "secret"
    assert captured["json"]["messages"] == [
        {"role": "user", "content": "prompt"}
    ]


@pytest.mark.parametrize("payload,match", [
    ([], "JSON 顶层不是 object"),
    ({"content": {"text": "bad"}}, "空 content"),
    ({"content": [{"type": "text", "text": "   "}]}, "无 text 字段"),
    ({"content": [{"type": "text", "text": 123}]}, "无 text 字段"),
])
async def test_anthropic_client_rejects_malformed_payload(
    monkeypatch, payload, match,
):
    _install_fake_async_client(
        monkeypatch,
        lambda url, **kwargs: _FakeResponse(payload),
    )
    with pytest.raises(AIProviderError, match=match):
        await AnthropicClient(api_key="test-key").interpret("prompt")


async def test_anthropic_client_uses_first_non_empty_text_block(monkeypatch):
    _install_fake_async_client(
        monkeypatch,
        lambda url, **kwargs: _FakeResponse({
            "content": [
                {"type": "thinking"},
                {"type": "text", "text": "命书文本"},
            ],
        }),
    )
    assert await AnthropicClient(api_key="test-key").interpret("prompt") == "命书文本"


async def test_anthropic_client_missing_key_is_explicit():
    with pytest.raises(AIProviderError, match="ANTHROPIC_API_KEY not configured"):
        await AnthropicClient(api_key=None).interpret("prompt")
