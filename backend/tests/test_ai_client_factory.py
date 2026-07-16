"""AI client factory 选择与 no-fallback 测试。"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from app.ai.anthropic_client import AnthropicClient
from app.ai.client import create_ai_client
from app.ai.openai_client import OpenAIClient
from app.errors import AIProviderError


BACKEND_ROOT = Path(__file__).resolve().parents[1]


def _create(provider: str):
    return create_ai_client(
        provider=provider,
        anthropic_api_key="anthropic-key",
        anthropic_model="claude-test",
        openai_api_key="openai-key",
        openai_model="gpt-test",
    )


def test_factory_selects_anthropic_only():
    client = _create("anthropic")
    assert isinstance(client, AnthropicClient)
    assert client.provider == "anthropic"
    assert client.model == "claude-test"


def test_factory_selects_openai_only():
    client = _create("openai")
    assert isinstance(client, OpenAIClient)
    assert client.provider == "openai"
    assert client.model == "gpt-test"


def test_factory_rejects_unknown_provider():
    with pytest.raises(ValueError, match="anthropic, openai"):
        _create("unknown")


def test_config_defaults_to_anthropic_when_provider_is_absent():
    env = os.environ.copy()
    env.pop("AI_PROVIDER", None)
    result = subprocess.run(
        [sys.executable, "-c", "from app.config import AI_PROVIDER; print(AI_PROVIDER)"],
        check=True,
        capture_output=True,
        text=True,
        env=env,
        cwd=BACKEND_ROOT,
    )
    assert result.stdout.strip() == "anthropic"


def test_config_rejects_invalid_provider_at_import_time():
    env = {**os.environ, "AI_PROVIDER": "invalid-provider"}
    result = subprocess.run(
        [sys.executable, "-c", "import app.config"],
        check=False,
        capture_output=True,
        text=True,
        env=env,
        cwd=BACKEND_ROOT,
    )
    assert result.returncode != 0
    assert "AI_PROVIDER must be one of: anthropic, openai" in result.stderr


def test_missing_selected_key_does_not_use_other_provider_key():
    client = create_ai_client(
        provider="openai",
        anthropic_api_key="available-but-must-not-fallback",
        anthropic_model="claude-test",
        openai_api_key=None,
        openai_model="gpt-test",
    )
    with pytest.raises(AIProviderError, match="OPENAI_API_KEY not configured"):
        client.interpret("prompt")
