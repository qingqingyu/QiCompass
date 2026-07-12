"""ClaudeClient 外部响应边界测试。"""

from __future__ import annotations

import pytest

from app.ai import claude_client as claude_module
from app.ai.claude_client import ClaudeClient
from app.errors import ClaudeAPIError


class _FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self):
        return self._payload


def test_claude_client_rejects_non_object_payload(monkeypatch):
    """Claude 畸形 JSON 不应冒泡成内部错误。"""
    monkeypatch.setattr(
        claude_module.httpx,
        "post",
        lambda *args, **kwargs: _FakeResponse([]),
    )

    client = ClaudeClient(api_key="test-key")
    with pytest.raises(ClaudeAPIError, match="JSON 顶层不是 object"):
        client.interpret("prompt")


def test_claude_client_rejects_non_list_content(monkeypatch):
    """content 不是 list 时统一按 Claude API 失败处理。"""
    monkeypatch.setattr(
        claude_module.httpx,
        "post",
        lambda *args, **kwargs: _FakeResponse({"content": {"text": "bad"}}),
    )

    client = ClaudeClient(api_key="test-key")
    with pytest.raises(ClaudeAPIError, match="空 content"):
        client.interpret("prompt")


def test_claude_client_uses_first_non_empty_text_block(monkeypatch):
    """Claude 返回多个 content block 时取第一个非空 text。"""
    monkeypatch.setattr(
        claude_module.httpx,
        "post",
        lambda *args, **kwargs: _FakeResponse({
            "content": [
                {"type": "thinking"},
                {"type": "text", "text": "命书文本"},
            ],
        }),
    )

    client = ClaudeClient(api_key="test-key")
    assert client.interpret("prompt") == "命书文本"


def test_claude_client_rejects_blank_text(monkeypatch):
    """纯空白 text 等同空内容,不能返回成功。"""
    monkeypatch.setattr(
        claude_module.httpx,
        "post",
        lambda *args, **kwargs: _FakeResponse({
            "content": [{"type": "text", "text": "   "}],
        }),
    )

    client = ClaudeClient(api_key="test-key")
    with pytest.raises(ClaudeAPIError, match="无 text 字段"):
        client.interpret("prompt")


def test_claude_client_rejects_non_string_text(monkeypatch):
    """text 字段必须是字符串。"""
    monkeypatch.setattr(
        claude_module.httpx,
        "post",
        lambda *args, **kwargs: _FakeResponse({
            "content": [{"type": "text", "text": 123}],
        }),
    )

    client = ClaudeClient(api_key="test-key")
    with pytest.raises(ClaudeAPIError, match="无 text 字段"):
        client.interpret("prompt")
