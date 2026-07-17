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

    def interpret(self, prompt: str) -> str: ...


def create_ai_client(
    *,
    provider: str,
    anthropic_api_key: str | None,
    anthropic_model: str,
    openai_api_key: str | None,
    openai_model: str,
    openai_base_url: str = "https://api.openai.com/v1",
) -> AIClient:
    """只构造配置选中的 provider;另一家不作 fallback。"""
    normalized = provider.strip().lower()
    if normalized == "anthropic":
        return AnthropicClient(
            api_key=anthropic_api_key,
            model=anthropic_model,
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
