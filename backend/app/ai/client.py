"""AI provider-neutral 协议与工厂。"""

from __future__ import annotations

from typing import Literal, Protocol

from .anthropic_client import AnthropicClient
from .openai_client import OpenAIClient

AIProvider = Literal["anthropic", "openai"]


class AIClient(Protocol):
    """路由层依赖的最小 AI client 契约。"""

    @property
    def provider(self) -> AIProvider: ...

    @property
    def model(self) -> str: ...

    async def interpret(
        self, prompt: str, *, temperature: float = 0.6,
        max_tokens: int | None = None,
        timeout: float | None = None,
    ) -> str: ...


def create_ai_client(
    *,
    provider: str,
    anthropic_api_key: str | None,
    anthropic_model: str,
    openai_api_key: str | None,
    openai_model: str,
    openai_base_url: str = "https://api.openai.com/v1",
    anthropic_base_url: str | None = None,
) -> AIClient:
    """只构造配置选中的 provider;另一家不作 fallback。"""
    normalized = provider.strip().lower()
    if normalized == "anthropic":
        return AnthropicClient(
            api_key=anthropic_api_key,
            model=anthropic_model,
            base_url=anthropic_base_url,
        )
    if normalized == "openai":
        return OpenAIClient(
            api_key=openai_api_key,
            model=openai_model,
            base_url=openai_base_url,
        )
    raise ValueError(
        "AI provider must be one of: anthropic, openai "
        f"(got {provider!r})"
    )
