"""evalkit JUDGE_* 配置回落单测(S05)。

不设任何 JUDGE_* env 时,三个常量回落到 AI_* 对应值(现有部署零感知)。
用 env 快照 + importlib.reload 验证,teardown 恢复 env 并 reload 回原状态,
避免污染其他测试。
"""

from __future__ import annotations

import importlib
import os

import pytest

_ENV_KEYS = (
    "JUDGE_PROVIDER", "JUDGE_MODEL", "JUDGE_API_KEY",
    "AI_PROVIDER", "ANTHROPIC_API_KEY", "ANTHROPIC_MODEL",
    "OPENAI_API_KEY", "OPENAI_MODEL", "OPENAI_BASE_URL",
    "JWT_SECRET_KEY",
)


@pytest.fixture
def config_module():
    import app.config as cfg
    original = {k: os.environ.get(k) for k in _ENV_KEYS}
    yield cfg
    # 恢复 env 后 reload,让模块回到进程初始状态
    for key, value in original.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value
    importlib.reload(cfg)


def _reload(cfg):
    return importlib.reload(cfg)


def test_judge_defaults_fall_back_to_anthropic(config_module):
    cfg = config_module
    for key in ("JUDGE_PROVIDER", "JUDGE_MODEL", "JUDGE_API_KEY"):
        os.environ.pop(key, None)
    os.environ["AI_PROVIDER"] = "anthropic"
    os.environ["ANTHROPIC_API_KEY"] = "sk-ant-test"
    os.environ["ANTHROPIC_MODEL"] = "claude-test-model"
    reloaded = _reload(cfg)
    assert reloaded.JUDGE_PROVIDER == "anthropic"
    assert reloaded.JUDGE_MODEL == "claude-test-model"
    assert reloaded.JUDGE_API_KEY == "sk-ant-test"


def test_judge_defaults_fall_back_to_openai(config_module):
    cfg = config_module
    for key in ("JUDGE_PROVIDER", "JUDGE_MODEL", "JUDGE_API_KEY"):
        os.environ.pop(key, None)
    os.environ["AI_PROVIDER"] = "openai"
    os.environ["OPENAI_API_KEY"] = "sk-test"
    os.environ["OPENAI_MODEL"] = "gpt-test-model"
    reloaded = _reload(cfg)
    assert reloaded.JUDGE_PROVIDER == "openai"
    assert reloaded.JUDGE_MODEL == "gpt-test-model"
    assert reloaded.JUDGE_API_KEY == "sk-test"


def test_judge_explicit_env_overrides(config_module):
    cfg = config_module
    os.environ["AI_PROVIDER"] = "anthropic"
    os.environ["JUDGE_PROVIDER"] = "openai"
    os.environ["JUDGE_MODEL"] = "strong-judge-model"
    os.environ["JUDGE_API_KEY"] = "sk-judge-key"
    reloaded = _reload(cfg)
    assert reloaded.JUDGE_PROVIDER == "openai"   # 跨 provider 裁判可配
    assert reloaded.JUDGE_MODEL == "strong-judge-model"
    assert reloaded.JUDGE_API_KEY == "sk-judge-key"


def test_judge_invalid_provider_raises(config_module):
    cfg = config_module
    os.environ["JUDGE_PROVIDER"] = "deepseek"
    with pytest.raises(ValueError, match="JUDGE_PROVIDER"):
        _reload(cfg)


def test_judge_blank_model_raises(config_module):
    cfg = config_module
    os.environ["JUDGE_MODEL"] = "   "
    with pytest.raises(ValueError, match="JUDGE_MODEL"):
        _reload(cfg)
