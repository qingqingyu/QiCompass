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


def _install_fake_async_client(monkeypatch, handler, *, ctor_sink=None):
    """把 anthropic_module.httpx.AsyncClient 替换成走 handler 的假 client。

    handler: (url, **kwargs) -> _FakeResponse 或 raise 异常
    ctor_sink: 可选 dict;若提供,把 httpx.AsyncClient(...) 的 kwargs 写入
        (用于长文超时测试验证 timeout 透传)。
    """

    class _FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            if ctor_sink is not None:
                ctor_sink.update(kwargs)

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


def _capture_request(monkeypatch, *, ctor_sink=None):
    """安装 fake client 并返回 captured dict,handler 写入请求字段。

    ctor_sink: 可选 dict;若提供,同时捕获 httpx.AsyncClient 构造 kwargs。
    """
    captured: dict = {}

    def handler(url, **kwargs):
        captured.update(url=url, **kwargs)
        return _FakeResponse({"content": [{"type": "text", "text": "命书"}]})

    _install_fake_async_client(monkeypatch, handler, ctor_sink=ctor_sink)
    return captured


# ===== 长文调用方(promo-site 加长版):max_tokens / timeout 透传 =====


async def test_anthropic_client_defaults_are_config_values(monkeypatch):
    """不传 max_tokens/timeout 时用 config 默认(App 路径行为不变)。"""
    ctor: dict = {}
    captured = _capture_request(monkeypatch, ctor_sink=ctor)
    await AnthropicClient(api_key="test-key").interpret("prompt")
    assert captured["json"]["max_tokens"] == 1024
    assert ctor["timeout"] == 90.0


async def test_anthropic_client_passes_max_tokens_and_timeout(monkeypatch):
    """显式 max_tokens/timeout 透传到 payload 与 httpx 超时(promo 长文用)。"""
    ctor: dict = {}
    captured = _capture_request(monkeypatch, ctor_sink=ctor)
    await AnthropicClient(api_key="test-key").interpret(
        "prompt", max_tokens=16384, timeout=420.0,
    )
    assert captured["json"]["max_tokens"] == 16384
    assert ctor["timeout"] == 420.0


async def test_anthropic_client_rejects_non_positive_max_tokens():
    """max_tokens <= 0 显式报错,不静默发畸形 payload。"""
    with pytest.raises(ValueError, match="max_tokens"):
        await AnthropicClient(api_key="test-key").interpret("prompt", max_tokens=0)


async def test_anthropic_client_rejects_non_positive_timeout():
    """timeout <= 0 显式报错,不立即超时。"""
    with pytest.raises(ValueError, match="timeout"):
        await AnthropicClient(api_key="test-key").interpret("prompt", timeout=-1.0)
