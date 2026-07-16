"""AnthropicClient 外部请求/响应边界测试。"""

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


def test_anthropic_client_request_contract(monkeypatch):
    captured = {}

    def fake_post(url, **kwargs):
        captured.update(url=url, **kwargs)
        return _FakeResponse({"content": [{"type": "text", "text": "命书"}]})

    monkeypatch.setattr(anthropic_module.httpx, "post", fake_post)
    client = AnthropicClient(api_key="secret", model="claude-test")

    assert client.interpret("prompt") == "命书"
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
def test_anthropic_client_rejects_malformed_payload(monkeypatch, payload, match):
    monkeypatch.setattr(
        anthropic_module.httpx,
        "post",
        lambda *args, **kwargs: _FakeResponse(payload),
    )
    with pytest.raises(AIProviderError, match=match):
        AnthropicClient(api_key="test-key").interpret("prompt")


def test_anthropic_client_uses_first_non_empty_text_block(monkeypatch):
    monkeypatch.setattr(
        anthropic_module.httpx,
        "post",
        lambda *args, **kwargs: _FakeResponse({
            "content": [
                {"type": "thinking"},
                {"type": "text", "text": "命书文本"},
            ],
        }),
    )
    assert AnthropicClient(api_key="test-key").interpret("prompt") == "命书文本"


def test_anthropic_client_missing_key_is_explicit():
    with pytest.raises(AIProviderError, match="ANTHROPIC_API_KEY not configured"):
        AnthropicClient(api_key=None).interpret("prompt")
