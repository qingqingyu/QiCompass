"""OpenAIClient Chat Completions API 请求/响应边界测试。

注:`interpret` 是 async(client 走 httpx.AsyncClient),所有用例需 await。
monkeypatch 策略:替换 `openai_module.httpx.AsyncClient` 为 fake 类,
其 `.post()` 直接调测试注入的 handler,不真发网络请求。
"""

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


def _install_fake_async_client(monkeypatch, handler):
    """把 openai_module.httpx.AsyncClient 替换成走 handler 的假 client。

    handler: (url, **kwargs) -> _FakeResponse 或 raise 异常
    """

    class _FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            pass  # 忽略 timeout / trust_env(测试不关心)

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def post(self, url, **kwargs):
            return handler(url, **kwargs)

    monkeypatch.setattr(openai_module.httpx, "AsyncClient", _FakeAsyncClient)


async def test_openai_client_request_contract(monkeypatch):
    captured = {}

    def handler(url, **kwargs):
        captured.update(url=url, **kwargs)
        return _FakeResponse(_completed())

    _install_fake_async_client(monkeypatch, handler)
    client = OpenAIClient(
        api_key="secret",
        model="gpt-test",
        base_url="https://api.example.com/v1",
    )

    assert await client.interpret("完整 prompt") == "命书文本"
    assert client.provider == "openai"
    assert client.model == "gpt-test"
    assert captured["url"] == "https://api.example.com/v1/chat/completions"
    assert captured["headers"]["Authorization"] == "Bearer secret"
    assert captured["json"] == {
        "model": "gpt-test",
        "messages": [{"role": "user", "content": "完整 prompt"}],
        "max_tokens": 1024,
        "temperature": 0.6,  # v1 prompt 系统默认值(老模块向后兼容)
    }


async def test_openai_client_strips_trailing_slash_from_base_url(monkeypatch):
    captured = {}

    def handler(url, **kwargs):
        captured.update(url=url)
        return _FakeResponse(_completed())

    _install_fake_async_client(monkeypatch, handler)
    client = OpenAIClient(
        api_key="k",
        model="m",
        base_url="https://api.example.com/v1/",
    )
    await client.interpret("p")
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
async def test_openai_client_rejects_non_success_payload(monkeypatch, payload, match):
    _install_fake_async_client(
        monkeypatch,
        lambda url, **kwargs: _FakeResponse(payload),
    )
    with pytest.raises(AIProviderError, match=match):
        await OpenAIClient(api_key="test-key").interpret("prompt")


async def test_openai_client_treats_length_truncation_as_success(monkeypatch):
    # finish_reason=length 表示被 max_tokens 截断,但已有文本应正常返回
    _install_fake_async_client(
        monkeypatch,
        lambda url, **kwargs: _FakeResponse({
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "截断的部分命书"},
                "finish_reason": "length",
            }],
        }),
    )
    assert await OpenAIClient(api_key="test-key").interpret("prompt") == "截断的部分命书"


async def test_openai_client_rejects_non_json(monkeypatch):
    _install_fake_async_client(
        monkeypatch,
        lambda url, **kwargs: _FakeResponse(ValueError("bad json")),
    )
    with pytest.raises(AIProviderError, match="非 JSON"):
        await OpenAIClient(api_key="test-key").interpret("prompt")


@pytest.mark.parametrize("status,match", [
    (401, "OPENAI_API_KEY"),
    (429, "限流"),
    (500, "HTTP 500"),
])
async def test_openai_client_maps_http_errors(monkeypatch, status, match):
    request = httpx.Request("POST", "https://api.openai.com/v1/chat/completions")
    response = httpx.Response(status, request=request)

    def handler(*args, **kwargs):
        raise httpx.HTTPStatusError("upstream", request=request, response=response)

    _install_fake_async_client(monkeypatch, handler)
    with pytest.raises(AIProviderError, match=match):
        await OpenAIClient(api_key="test-key").interpret("prompt")


async def test_openai_client_maps_timeout_and_preserves_cause(monkeypatch):
    timeout = httpx.ReadTimeout("slow")
    _install_fake_async_client(
        monkeypatch,
        lambda *args, **kwargs: (_ for _ in ()).throw(timeout),
    )
    with pytest.raises(AIProviderError, match="超时") as exc_info:
        await OpenAIClient(api_key="test-key").interpret("prompt")
    assert exc_info.value.__cause__ is timeout


async def test_openai_client_missing_key_is_explicit():
    with pytest.raises(AIProviderError, match="OPENAI_API_KEY not configured"):
        await OpenAIClient(api_key=None).interpret("prompt")


def test_openai_client_rejects_blank_base_url():
    with pytest.raises(ValueError, match="base_url"):
        OpenAIClient(api_key="k", model="m", base_url="   ")


# ===== v1 prompt 系统:temperature 分级 =====


async def test_openai_client_default_temperature_is_0_6(monkeypatch):
    """默认 temperature=0.6(老模块向后兼容)。"""
    captured = _capture_request(monkeypatch)
    client = OpenAIClient(api_key="test-key")
    await client.interpret("prompt")
    assert captured["json"]["temperature"] == 0.6


async def test_openai_client_passes_temperature_to_payload(monkeypatch):
    """显式 temperature=0.3(M0-M2 结构层)被正确传入 json payload。"""
    captured = _capture_request(monkeypatch)
    client = OpenAIClient(api_key="test-key")
    await client.interpret("prompt", temperature=0.3)
    assert captured["json"]["temperature"] == 0.3


def _capture_request(monkeypatch):
    """安装 fake client 并返回 captured dict,handler 写入请求字段。"""
    captured: dict = {}

    def handler(url, **kwargs):
        captured.update(url=url, **kwargs)
        return _FakeResponse(_completed())

    _install_fake_async_client(monkeypatch, handler)
    return captured
