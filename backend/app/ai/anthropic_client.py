"""Anthropic Messages API 同步客户端(httpx)。

支持自定义 base_url(Anthropic 协议中转,如 z.ai /api/anthropic)。
"""

from __future__ import annotations

import httpx

from ..config import AI_MAX_OUTPUT_TOKENS, AI_TIMEOUT_SECONDS, ANTHROPIC_MODEL
from ..errors import AIProviderError


class AnthropicClient:
    """Anthropic Messages API 适配器。"""

    provider = "anthropic"
    _DEFAULT_BASE_URL = "https://api.anthropic.com"

    def __init__(
        self,
        api_key: str | None,
        model: str = ANTHROPIC_MODEL,
        base_url: str | None = None,
    ):
        if not model.strip():
            raise ValueError("Anthropic model must not be blank")
        if base_url is not None and not base_url.strip():
            raise ValueError("Anthropic base_url must not be blank")
        self._api_key = api_key
        self._model = model
        # 中转 endpoint 传根地址(如 https://api.z.ai/api/anthropic),
        # /v1/messages 由本类拼接,与官方 URL 形状保持一致。
        self._base_url = (base_url or self._DEFAULT_BASE_URL).rstrip("/")

    @property
    def model(self) -> str:
        return self._model

    async def interpret(
        self, prompt: str, *, temperature: float = 0.6,
        max_tokens: int | None = None,
        timeout: float | None = None,
        module: str | None = None,
    ) -> str:
        """调 Anthropic Messages API,返回第一个非空文本块。

        Args:
            prompt: 用户 prompt 文本
            temperature: 0.0-1.0(Anthropic 范围);v1 prompt 系统按 module 分级,
                M0-M2 结构层 0.3,M3-M7 叙述层 0.6。调用方通过
                config.resolve_temperature(module) 取值后传入。
            max_tokens: 输出 token 上限;None 用 config.AI_MAX_OUTPUT_TOKENS(App 8192)。
                长文调用方(如 promo-site 加长版)按需放大。
            timeout: 请求超时秒数;None 用 config.AI_TIMEOUT_SECONDS(App 150s)。
                长 max_tokens 生成耗时更长,调用方应同步放大。
            module: 发起调用的业务 module(监控计数维度)。真实 client 不
                消费,由 MeteredAIClient 包装层读取;None 计 "unknown"。
        """
        if not self._api_key:
            raise AIProviderError(
                "ANTHROPIC_API_KEY not configured"
                "(后端未设置 API key,无法调用 Anthropic)",
                reason="no_api_key",
            )
        if max_tokens is not None and max_tokens <= 0:
            raise ValueError(
                f"max_tokens must be a positive integer (got {max_tokens})"
            )
        if timeout is not None and timeout <= 0:
            raise ValueError(
                f"timeout must be a positive number of seconds (got {timeout})"
            )

        try:
            async with httpx.AsyncClient(
                timeout=timeout if timeout is not None else AI_TIMEOUT_SECONDS,
            ) as client:
                resp = await client.post(
                    f"{self._base_url}/v1/messages",
                    headers={
                        "x-api-key": self._api_key,
                        "anthropic-version": "2023-06-01",
                        "content-type": "application/json",
                    },
                    json={
                        "model": self._model,
                        "max_tokens": max_tokens if max_tokens is not None else AI_MAX_OUTPUT_TOKENS,
                        "temperature": temperature,
                        "messages": [{"role": "user", "content": prompt}],
                    },
                )
                resp.raise_for_status()
        except httpx.TimeoutException as e:
            raise AIProviderError(
                f"Anthropic API 超时({type(e).__name__}): {e}",
                reason="timeout",
            ) from e
        except httpx.HTTPStatusError as e:
            status_code = e.response.status_code
            if status_code == 429:
                raise AIProviderError(
                    f"Anthropic API 限流({type(e).__name__}): HTTP {status_code}",
                    reason="rate_limit",
                ) from e
            if status_code == 401:
                raise AIProviderError(
                    "Anthropic API key 无效或未授权(HTTP 401),"
                    "请检查 ANTHROPIC_API_KEY 配置",
                    reason="auth",
                ) from e
            raise AIProviderError(
                f"Anthropic API HTTP {status_code}({type(e).__name__})",
                reason="http_error",
            ) from e
        except httpx.RequestError as e:
            raise AIProviderError(
                f"Anthropic API 调用失败({type(e).__name__}): {e}",
                reason="network",
            ) from e

        try:
            payload = resp.json()
        except ValueError as e:
            raise AIProviderError(
                f"Anthropic 返回非 JSON 响应({type(e).__name__}): {e}",
                reason="bad_response",
            ) from e

        if not isinstance(payload, dict):
            raise AIProviderError(
                "Anthropic 返回 JSON 顶层不是 object"
                f"(type={type(payload).__name__})",
                reason="bad_response",
            )

        content = payload.get("content")
        if not isinstance(content, list) or not content:
            raise AIProviderError(
                "Anthropic 返回空 content(无文本块)",
                reason="bad_response",
            )

        # 截断显式报错(2026-09-27):stop_reason=max_tokens 时文本必然不完整,
        # v1 模块契约是完整 JSON,半截 JSON 一旦入缓存会被 iOS 当散文渲染
        # (真机 m1_talent 实证)。此处拦截 = 错误显式传播,不静默返回截断文本。
        # 只拦显式 max_tokens;字段缺失/其他值(end_turn 等)照常放行。
        if payload.get("stop_reason") == "max_tokens":
            raise AIProviderError(
                "Anthropic 输出被 max_tokens 截断(stop_reason=max_tokens,"
                f"文本不完整,model={self._model})",
                reason="truncated",
            )

        for block in content:
            text = block.get("text") if isinstance(block, dict) else None
            if isinstance(text, str) and text.strip():
                return text

        first = content[0]
        first_type = first.get("type", "?") if isinstance(first, dict) else "?"
        raise AIProviderError(
            "Anthropic 返回 content 无 text 字段"
            f"(first_type={first_type})",
            reason="bad_response",
        )
