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
        openai_base_url="https://api.openai.com/v1",
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


async def test_missing_selected_key_does_not_use_other_provider_key():
    client = create_ai_client(
        provider="openai",
        anthropic_api_key="available-but-must-not-fallback",
        anthropic_model="claude-test",
        openai_api_key=None,
        openai_model="gpt-test",
        openai_base_url="https://api.openai.com/v1",
    )
    with pytest.raises(AIProviderError, match="OPENAI_API_KEY not configured"):
        await client.interpret("prompt")


# ===== v1 prompt 系统:MODULE_TEMPERATURES / resolve_temperature =====


from app.ai.prompts import PROMPT_VERSIONS  # noqa: E402
from app.config import (  # noqa: E402
    AI_DEFAULT_TEMPERATURE,
    MODULE_TEMPERATURES,
    resolve_temperature,
)


# Stage 2 前瞻:MODULE_TEMPERATURES 已铺到 m0-m7(待 Stage 5 在 PROMPT_VERSIONS 补上)
# 当 PROMPT_VERSIONS 加上 m0-m7 后,这两个集合应相等,本测试自动转为严格双向对齐。
_V1_NEW_MODULES = (
    "m0_structure", "m1_talent", "m2_high_low",
    "m3_system", "m4_health", "m5_wealth",
    "m6_dynamics", "m7_manual",
)


def test_module_temperatures_covers_all_known_modules():
    """MODULE_TEMPERATURES 必须覆盖 PROMPT_VERSIONS 所有 key + v1 新 module 前瞻清单。

    单一事实源:PROMPT_VERSIONS 的 key 直接读出来做断言(不手抄老模块名),
    再补 v1 新 module 前瞻清单(Stage 5 在 PROMPT_VERSIONS 加上前这层是显式声明的)。

    漂移检测:
    - PROMPT_VERSIONS 加新 module 但 MODULE_TEMPERATURES 漏 → 运行时静默走默认值
    - v1 新 module 清单扩张但 MODULE_TEMPERATURES 漏 → 同上
    """
    missing_from_prompt = set(PROMPT_VERSIONS.keys()) - set(MODULE_TEMPERATURES.keys())
    assert not missing_from_prompt, (
        f"MODULE_TEMPERATURES 缺 PROMPT_VERSIONS 里的 module: {sorted(missing_from_prompt)}"
    )
    missing_from_v1 = set(_V1_NEW_MODULES) - set(MODULE_TEMPERATURES.keys())
    assert not missing_from_v1, (
        f"MODULE_TEMPERATURES 缺 v1 新 module: {sorted(missing_from_v1)}"
    )


def test_resolve_temperature_m0_to_m2_is_0_3():
    """v1 §1 设计:M0-M2 结构层 temperature=0.3(低创造性,稳结构判断)。"""
    for m in ("m0_structure", "m1_talent", "m2_high_low"):
        assert resolve_temperature(m) == 0.3, f"{m} 应为 0.3"


def test_resolve_temperature_m3_to_m7_is_0_6():
    """v1 §1 设计:M3-M7 叙述层 temperature=0.6(适度创造性,有质感)。"""
    for m in ("m3_system", "m4_health", "m5_wealth", "m6_dynamics", "m7_manual"):
        assert resolve_temperature(m) == 0.6, f"{m} 应为 0.6"


def test_resolve_temperature_old_modules_use_default():
    """老模块(bazi_deep_*/compatibility_*/daily_fortune)统一 0.6,向后兼容。"""
    for m in (
        "bazi_deep", "bazi_deep_free", "bazi_deep_paid",
        "compatibility", "compatibility_free", "compatibility_paid",
        "daily_fortune",
    ):
        assert resolve_temperature(m) == AI_DEFAULT_TEMPERATURE


def test_resolve_temperature_unknown_module_falls_back_to_default():
    """未知 module 不抛错,静默走 AI_DEFAULT_TEMPERATURE(向后兼容扩展)。"""
    assert resolve_temperature("nonexistent_module_xyz") == AI_DEFAULT_TEMPERATURE


def test_all_temperatures_in_valid_anthropic_range():
    """Anthropic temperature 范围 0.0-1.0,所有值必须在此范围内。

    OpenAI 范围 0.0-2.0 更宽,所以以 Anthropic 为约束下限。
    """
    for module, temp in MODULE_TEMPERATURES.items():
        assert 0.0 <= temp <= 1.0, (
            f"{module} temperature {temp} 超出 Anthropic 合法范围 [0.0, 1.0]"
        )
