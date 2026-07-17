"""OpenAIClient Chat Completions API 请求/响应边界测试。"""

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
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": text},
            "finish_reason": "stop",
        }],
    }


def test_openai_client_request_contract(monkeypatch):
    captured = {}

    def fake_post(url, **kwargs):
        captured.update(url=url, **kwargs)
        return _FakeResponse(_completed())

    monkeypatch.setattr(openai_module.httpx, "post", fake_post)
    client = OpenAIClient(
        api_key="secret",
        model="gpt-test",
        base_url="https://api.example.com/v1",
    )

    assert client.interpret("完整 prompt") == "命书文本"
    assert client.provider == "openai"
    assert client.model == "gpt-test"
    assert captured["url"] == "https://api.example.com/v1/chat/completions"
    assert captured["headers"]["Authorization"] == "Bearer secret"
    assert captured["json"] == {
        "model": "gpt-test",
        "messages": [{"role": "user", "content": "完整 prompt"}],
        "max_tokens": 1024,
    }


def test_openai_client_strips_trailing_slash_from_base_url(monkeypatch):
    captured = {}

    def fake_post(url, **kwargs):
        captured.update(url=url)
        return _FakeResponse(_completed())

    monkeypatch.setattr(openai_module.httpx, "post", fake_post)
    client = OpenAIClient(
        api_key="k",
        model="m",
        base_url="https://api.example.com/v1/",
    )
    client.interpret("p")
    # 末尾斜杠必须被去掉,避免 //chat/completions
    assert captured["url"] == "https://api.example.com/v1/chat/completions"


@pytest.mark.parametrize("payload,match", [
    ([], "JSON 顶层不是 object"),
    ({}, "空 choices"),
    ({"choices": []}, "空 choices"),
    ({"choices": [{}]}, "message 不是 object"),  # message 默认 None
    ({"choices": [{"message": {}}]}, "message.content 为空"),
    (_completed("   "), "message.content 为空"),
    (_completed(123), "message.content 为空"),
    ({"choices": [{
        "index": 0,
        "message": {"role": "assistant", "content": "部分文本"},
        "finish_reason": "content_filter",
    }]}, "content_filter"),
])
def test_openai_client_rejects_non_success_payload(monkeypatch, payload, match):
    monkeypatch.setattr(
        openai_module.httpx,
        "post",
        lambda *args, **kwargs: _FakeResponse(payload),
    )
    with pytest.raises(AIProviderError, match=match):
        OpenAIClient(api_key="test-key").interpret("prompt")


def test_openai_client_treats_length_truncation_as_success(monkeypatch):
    # finish_reason=length 表示被 max_tokens 截断,但已有文本应正常返回
    monkeypatch.setattr(
        openai_module.httpx,
        "post",
        lambda *args, **kwargs: _FakeResponse({
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "截断的部分命书"},
                "finish_reason": "length",
            }],
        }),
    )
    assert OpenAIClient(api_key="test-key").interpret("prompt") == "截断的部分命书"


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
    request = httpx.Request("POST", "https://api.openai.com/v1/chat/completions")
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


def test_openai_client_rejects_blank_base_url():
    with pytest.raises(ValueError, match="base_url"):
        OpenAIClient(api_key="k", model="m", base_url="   ")
