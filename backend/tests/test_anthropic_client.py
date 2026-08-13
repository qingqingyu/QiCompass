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


async def test_anthropic_client_custom_base_url(monkeypatch):
    """自定义 base_url(Anthropic 协议中转,如 z.ai):/v1/messages 拼在 base 后。

    默认(不传 base_url)仍走官方 endpoint,由
    test_anthropic_client_request_contract 覆盖。
    """
    captured = _capture_request(monkeypatch)
    client = AnthropicClient(
        api_key="secret", model="glm-5.2",
        base_url="https://api.z.ai/api/anthropic/",
    )

    await client.interpret("prompt")

    assert captured["url"] == "https://api.z.ai/api/anthropic/v1/messages"
    assert captured["headers"]["x-api-key"] == "secret"
    assert captured["json"]["model"] == "glm-5.2"


async def test_anthropic_client_blank_base_url_rejected():
    with pytest.raises(ValueError, match="base_url must not be blank"):
        AnthropicClient(api_key="secret", base_url="   ")


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


# ===== v1 prompt 系统:temperature 分级 =====


async def test_anthropic_client_default_temperature_is_0_6(monkeypatch):
    """默认 temperature=0.6(老模块向后兼容,不传 temperature 时走 0.6)。"""
    captured = _capture_request(monkeypatch)
    client = AnthropicClient(api_key="test-key")
    await client.interpret("prompt")
    assert captured["json"]["temperature"] == 0.6


async def test_anthropic_client_passes_temperature_to_payload(monkeypatch):
    """显式 temperature=0.3(M0-M2 结构层)被正确传入 json payload。"""
    captured = _capture_request(monkeypatch)
    client = AnthropicClient(api_key="test-key")
    await client.interpret("prompt", temperature=0.3)
    assert captured["json"]["temperature"] == 0.3


def _capture_request(monkeypatch):
    """安装 fake client 并返回 captured dict,handler 写入请求字段。"""
    captured: dict = {}

    def handler(url, **kwargs):
        captured.update(url=url, **kwargs)
        return _FakeResponse({"content": [{"type": "text", "text": "命书"}]})

    _install_fake_async_client(monkeypatch, handler)
    return captured
