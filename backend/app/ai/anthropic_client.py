"""Anthropic Messages API 同步客户端(httpx)。"""

from __future__ import annotations

import httpx

from ..config import AI_MAX_OUTPUT_TOKENS, AI_TIMEOUT_SECONDS, ANTHROPIC_MODEL
from ..errors import AIProviderError


class AnthropicClient:
    """Anthropic Messages API 适配器。"""

    provider = "anthropic"

    def __init__(self, api_key: str | None, model: str = ANTHROPIC_MODEL):
        if not model.strip():
            raise ValueError("Anthropic model must not be blank")
        self._api_key = api_key
        self._model = model

    @property
    def model(self) -> str:
        return self._model

    def interpret(self, prompt: str) -> str:
        """调 Anthropic Messages API,返回第一个非空文本块。"""
        if not self._api_key:
            raise AIProviderError(
                "ANTHROPIC_API_KEY not configured"
                "(后端未设置 API key,无法调用 Anthropic)"
            )

        try:
            resp = httpx.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": self._api_key,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": self._model,
                    "max_tokens": AI_MAX_OUTPUT_TOKENS,
                    "messages": [{"role": "user", "content": prompt}],
                },
                timeout=AI_TIMEOUT_SECONDS,
            )
            resp.raise_for_status()
        except httpx.TimeoutException as e:
            raise AIProviderError(
                f"Anthropic API 超时({type(e).__name__}): {e}"
            ) from e
        except httpx.HTTPStatusError as e:
            status_code = e.response.status_code
            if status_code == 429:
                raise AIProviderError(
                    f"Anthropic API 限流({type(e).__name__}): HTTP {status_code}"
                ) from e
            if status_code == 401:
                raise AIProviderError(
                    "Anthropic API key 无效或未授权(HTTP 401),"
                    "请检查 ANTHROPIC_API_KEY 配置"
                ) from e
            raise AIProviderError(
                f"Anthropic API HTTP {status_code}({type(e).__name__})"
            ) from e
        except httpx.RequestError as e:
            raise AIProviderError(
                f"Anthropic API 调用失败({type(e).__name__}): {e}"
            ) from e

        try:
            payload = resp.json()
        except ValueError as e:
            raise AIProviderError(
                f"Anthropic 返回非 JSON 响应({type(e).__name__}): {e}"
            ) from e

        if not isinstance(payload, dict):
            raise AIProviderError(
                "Anthropic 返回 JSON 顶层不是 object"
                f"(type={type(payload).__name__})"
            )

        content = payload.get("content")
        if not isinstance(content, list) or not content:
            raise AIProviderError("Anthropic 返回空 content(无文本块)")

        for block in content:
            text = block.get("text") if isinstance(block, dict) else None
            if isinstance(text, str) and text.strip():
                return text

        first = content[0]
        first_type = first.get("type", "?") if isinstance(first, dict) else "?"
        raise AIProviderError(
            "Anthropic 返回 content 无 text 字段"
            f"(first_type={first_type})"
        )
