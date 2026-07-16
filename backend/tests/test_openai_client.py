"""OpenAIClient Responses API 请求/响应边界测试。"""

from __future__ import annotations

import httpx
import pytest

from app.ai import openai_client as openai_module
from app.ai.openai_client import OpenAIClient
from app.errors import AIProviderError


class _FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self):
        if isinstance(self._payload, Exception):
            raise self._payload
        return self._payload


def _completed(text: object = "命书文本") -> dict:
    return {
        "status": "completed",
        "output": [{
            "type": "message",
            "content": [{"type": "output_text", "text": text}],
        }],
    }


def test_openai_client_request_contract(monkeypatch):
    captured = {}

    def fake_post(url, **kwargs):
        captured.update(url=url, **kwargs)
        return _FakeResponse(_completed())

    monkeypatch.setattr(openai_module.httpx, "post", fake_post)
    client = OpenAIClient(api_key="secret", model="gpt-test")

    assert client.interpret("完整 prompt") == "命书文本"
    assert client.provider == "openai"
    assert client.model == "gpt-test"
    assert captured["url"] == "https://api.openai.com/v1/responses"
    assert captured["headers"]["Authorization"] == "Bearer secret"
    assert captured["json"] == {
        "model": "gpt-test",
        "input": "完整 prompt",
        "max_output_tokens": 1024,
        "store": False,
    }


@pytest.mark.parametrize("payload,match", [
    ([], "JSON 顶层不是 object"),
    ({"status": "incomplete", "output": []}, "status=incomplete"),
    ({"status": "failed", "output": []}, "status=failed"),
    ({"status": "completed", "output": []}, "空 output"),
    ({"status": "completed", "output": [{}]}, "无非空 output_text"),
    (_completed("   "), "无非空 output_text"),
    (_completed(123), "无非空 output_text"),
    ({
        "status": "completed",
        "output": [{
            "type": "message",
            "content": [{"type": "refusal", "refusal": "blocked"}],
        }],
    }, "refusal"),
    ({
        "status": "completed",
        "output": [{
            "type": "message",
            "content": [
                {"type": "output_text", "text": "不得返回的部分文本"},
                {"type": "refusal", "refusal": "blocked"},
            ],
        }],
    }, "refusal"),
])
def test_openai_client_rejects_non_success_payload(monkeypatch, payload, match):
    monkeypatch.setattr(
        openai_module.httpx,
        "post",
        lambda *args, **kwargs: _FakeResponse(payload),
    )
    with pytest.raises(AIProviderError, match=match):
        OpenAIClient(api_key="test-key").interpret("prompt")


def test_openai_client_rejects_non_json(monkeypatch):
    monkeypatch.setattr(
        openai_module.httpx,
        "post",
        lambda *args, **kwargs: _FakeResponse(ValueError("bad json")),
    )
    with pytest.raises(AIProviderError, match="非 JSON"):
        OpenAIClient(api_key="test-key").interpret("prompt")


@pytest.mark.parametrize("status,match", [
    (401, "OPENAI_API_KEY"),
    (429, "限流"),
    (500, "HTTP 500"),
])
def test_openai_client_maps_http_errors(monkeypatch, status, match):
    request = httpx.Request("POST", "https://api.openai.com/v1/responses")
    response = httpx.Response(status, request=request)

    def fake_post(*args, **kwargs):
        raise httpx.HTTPStatusError("upstream", request=request, response=response)

    monkeypatch.setattr(openai_module.httpx, "post", fake_post)
    with pytest.raises(AIProviderError, match=match):
        OpenAIClient(api_key="test-key").interpret("prompt")


def test_openai_client_maps_timeout_and_preserves_cause(monkeypatch):
    timeout = httpx.ReadTimeout("slow")
    monkeypatch.setattr(
        openai_module.httpx,
        "post",
        lambda *args, **kwargs: (_ for _ in ()).throw(timeout),
    )
    with pytest.raises(AIProviderError, match="超时") as exc_info:
        OpenAIClient(api_key="test-key").interpret("prompt")
    assert exc_info.value.__cause__ is timeout


def test_openai_client_missing_key_is_explicit():
    with pytest.raises(AIProviderError, match="OPENAI_API_KEY not configured"):
        OpenAIClient(api_key=None).interpret("prompt")
