"""分模块模型路由测试(2026-11-09,机制先行路由表留空)。

覆盖:router 单元语义(精确命中/缺省回落/translate 前缀剥解/非 router
透传)/config 解析 fail-fast(组不完整、非法 provider、MODULES 解析为
空、组号越界含前导零)/启动校验(未知模块、重复分配)/端到端(interpret
与 translate 双 Mock 路:响应身份与缓存行按 provider/model 分路,translate
按源模块路由)/health routes 形状。
"""

from __future__ import annotations

import importlib

import pytest

from app.ai.router import AIClientRouter, resolve_ai_client
from tests.fixtures.mock_ai import MockAIClient


def _mock(provider: str, model: str) -> MockAIClient:
    client = MockAIClient(provider=provider, model=model)
    client.set_response('{"structure_fingerprint": "fp-router"}')
    return client


# ===== router 单元 =====

def test_router_exact_hit_and_default_fallback():
    route = _mock("openai", "deepseek-chat")
    default = _mock("anthropic", "glm-5.3")
    router = AIClientRouter(
        default=default, routes={"m1_talent": route, "m2_high_low": route})
    assert router.client_for("m1_talent") is route
    assert router.client_for("m2_high_low") is route
    # 未命中回落默认(不猜、不降级)
    assert router.client_for("m7_manual") is default
    assert router.client_for("daily_fortune") is default
    # provider/model 属性 = 默认身份(启动日志/health 单一展示口径)
    assert (router.provider, router.model) == ("anthropic", "glm-5.3")


def test_router_translate_prefix_routes_by_source_module():
    """translate:{m} 剥前缀按源模块路由——长章翻译自动跟长章路由。"""
    route = _mock("openai", "deepseek-chat")
    default = _mock("anthropic", "glm-5.3")
    router = AIClientRouter(default=default, routes={"m1_talent": route})
    assert router.client_for("translate:m1_talent") is route
    assert router.client_for("translate:daily_fortune") is default


def test_resolve_passthrough_non_router():
    """非 Router(测试 Mock 直换 state 的既有模式)原样透传——
    Mock 旁路是既有全套测试零改的关键,锁定之。"""
    plain = _mock("anthropic", "glm-5.3")
    assert resolve_ai_client(plain, "m0_structure") is plain
    router = AIClientRouter(default=plain, routes={})
    assert resolve_ai_client(router, "m0_structure") is plain


# ===== config 解析 fail-fast =====

def _reload_config(monkeypatch, **env) -> object:
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    from app import config
    # reload 会按测试 env 重解析 AI_ROUTES;先用 monkeypatch 钉住旧值,
    # teardown 还原——否则解析出的测试路由(含 sk-test key)残留在
    # config 模块上外溢给同会话后续读者(monkeypatch 只清 env 不重解析)
    monkeypatch.setattr(config, "AI_ROUTES", config.AI_ROUTES)
    return importlib.reload(config)


def test_config_partial_route_group_raises(monkeypatch):
    """配了 MODEL 但缺 MODULES → 显式报错,不静默丢路由。"""
    with pytest.raises(ValueError, match="AI_ROUTE_1"):
        _reload_config(monkeypatch, AI_ROUTE_1_MODEL="deepseek-chat")


def test_config_invalid_route_provider_raises(monkeypatch):
    with pytest.raises(ValueError, match="AI_ROUTE_1_PROVIDER"):
        _reload_config(
            monkeypatch,
            AI_ROUTE_1_MODULES="m1_talent",
            AI_ROUTE_1_PROVIDER="groq",
            AI_ROUTE_1_MODEL="x")


def test_config_blank_modules_value_raises(monkeypatch):
    """MODULES 只含分隔符/空白 → 解析后零映射,显式报错不静默丢组。"""
    with pytest.raises(ValueError, match="解析后为空"):
        _reload_config(
            monkeypatch,
            AI_ROUTE_1_MODULES=" , ",
            AI_ROUTE_1_PROVIDER="openai",
            AI_ROUTE_1_MODEL="x")


def test_config_out_of_range_route_index_raises(monkeypatch):
    """组号越界(N∉1..8)的组会被静默忽略 → 启动期显式报错。"""
    with pytest.raises(ValueError, match="越界"):
        _reload_config(
            monkeypatch,
            AI_ROUTE_9_MODULES="m1_talent",
            AI_ROUTE_9_PROVIDER="openai",
            AI_ROUTE_9_MODEL="x")


def test_config_leading_zero_route_index_raises(monkeypatch):
    """前导零组号(AI_ROUTE_01_*)解析循环读不到 → 显式报错。"""
    with pytest.raises(ValueError, match="前导零"):
        _reload_config(
            monkeypatch,
            AI_ROUTE_01_MODULES="m1_talent",
            AI_ROUTE_01_PROVIDER="openai",
            AI_ROUTE_01_MODEL="x")


def test_config_valid_route_parses(monkeypatch):
    config = _reload_config(
        monkeypatch,
        AI_ROUTE_1_MODULES="m1_talent, m2_high_low",
        AI_ROUTE_1_PROVIDER="openai",
        AI_ROUTE_1_MODEL="deepseek-chat",
        AI_ROUTE_1_BASE_URL="https://api.deepseek.com/v1/",
        AI_ROUTE_1_API_KEY="sk-test",
    )
    assert len(config.AI_ROUTES) == 1
    route = config.AI_ROUTES[0]
    assert route.modules == ("m1_talent", "m2_high_low")
    assert route.provider == "openai"
    assert route.model == "deepseek-chat"
    assert route.base_url == "https://api.deepseek.com/v1"  # 尾斜杠剥除
    assert route.api_key == "sk-test"


# ===== 启动校验(main._build_ai_router) =====

def _build_router(monkeypatch, routes):
    from app import main
    from app.config import AIRouteConfig
    monkeypatch.setattr(main, "AI_ROUTES", routes)
    default = _mock("anthropic", "glm-5.3")
    return main._build_ai_router(default, metrics_store=object()), default


def test_build_router_unknown_module_fails_fast(monkeypatch):
    from app.config import AIRouteConfig
    with pytest.raises(RuntimeError, match="未知模块"):
        _build_router(monkeypatch, [AIRouteConfig(
            index=1, modules=("m9_nonexistent",), provider="openai",
            model="x", base_url=None, api_key=None)])


def test_build_router_duplicate_module_fails_fast(monkeypatch):
    from app.config import AIRouteConfig
    with pytest.raises(RuntimeError, match="重复"):
        _build_router(monkeypatch, [
            AIRouteConfig(index=1, modules=("m1_talent",), provider="openai",
                          model="a", base_url=None, api_key=None),
            AIRouteConfig(index=2, modules=("m1_talent",), provider="openai",
                          model="b", base_url=None, api_key=None)])


def test_build_router_empty_table_returns_default(monkeypatch):
    """表留空:原样返回 default(零路由零行为变化)。"""
    router, default = _build_router(monkeypatch, [])
    assert router is default


# ===== 端到端:双 Mock 路,身份与缓存行分路 =====

async def test_e2e_routed_module_identity_and_cache_row(
        raw_interpret_client, monkeypatch):
    """m0 走路由 B、默认路不被触碰;响应身份与缓存行 provider/model=B。"""
    import json as _json

    from app.main import app
    from app.context_binding import _build_v1_chart_mirror, build_chart_tokens
    from tests.test_context_binding import _calculate_result

    route_b = _mock("openai", "deepseek-chat")
    route_b.set_response(_json.dumps(
        {"structure_fingerprint": "fp-routed", "main_axis": "印",
         "core_loop": "印→比"}, ensure_ascii=False))
    default_a = _mock("anthropic", "glm-5.3")
    monkeypatch.setattr(
        app.state, "ai_client",
        AIClientRouter(default=default_a, routes={"m0_structure": route_b}),
        raising=False)

    result = _calculate_result()
    canonical = _json.dumps(_build_v1_chart_mirror(result), ensure_ascii=False)
    resp = await raw_interpret_client.post("/api/interpret", json={
        "content_hash": result["content_hash"], "module": "m0_structure",
        "context": {"chart": canonical}, "target_date": None,
        "context_token": build_chart_tokens(result)["v1"],
    })
    assert resp.status_code == 200, resp.json()
    assert resp.json()["provider"] == "openai"
    assert resp.json()["model"] == "deepseek-chat"
    assert route_b.call_count == 1
    assert default_a.call_count == 0
    rows = app.state.cache.get_module_rows(
        result["content_hash"], "m0_structure", "zh")
    assert rows and rows[0][0].provider == "openai"
    assert rows[0][0].model == "deepseek-chat"


async def test_e2e_translate_routes_by_source_module(
        interpret_client, monkeypatch):
    """红线锁定:translate 按源模块路由——zh 生成与 zh-hant 翻译同走
    路由 client,译后缓存行 provider/model = 路由身份(D10.1 键对齐)。"""
    from app.main import app
    from tests.test_interpret_translate import (
        M0_CHART,
        M0_HANT_JSON,
        M0_ZH_JSON,
        _m0_translate_payload,
    )

    route_b = _mock("openai", "deepseek-chat")
    route_b.set_response(M0_HANT_JSON)  # 翻译档位应答
    default_a = _mock("anthropic", "glm-5.3")
    monkeypatch.setattr(
        app.state, "ai_client",
        AIClientRouter(default=default_a, routes={"m0_structure": route_b}),
        raising=False)

    payload = _m0_translate_payload()
    gen = {
        "content_hash": payload["content_hash"], "module": "m0_structure",
        "context": payload["context"], "target_date": None,
    }
    # 1. zh 正常生成(m0 被路由 → route_b)——顺带为防伪落 source 行
    route_b.set_response(M0_ZH_JSON)
    resp = await interpret_client.post("/api/interpret", json=gen)
    assert resp.status_code == 200, resp.text
    assert resp.json()["provider"] == "openai"
    assert default_a.call_count == 0

    # 2. 翻译到 zh-hant:同模块 → 同一路由 client(剥 translate: 前缀语义)
    route_b.set_response(M0_HANT_JSON)
    resp = await interpret_client.post(
        "/api/interpret/translate", json=payload,
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["language"] == "zh-hant"
    assert body["provider"] == "openai"
    assert body["model"] == "deepseek-chat"
    assert route_b.call_count == 2  # 生成 1 + 翻译 1,全在路由路
    assert default_a.call_count == 0

    # 3. 译后缓存行身份 = 路由 client(缓存键 provider/model 维分路)
    rows = app.state.cache.get_module_rows(
        payload["content_hash"], "m0_structure", "zh-hant")
    assert rows and rows[0][0].provider == "openai"
    assert rows[0][0].model == "deepseek-chat"


async def test_health_llm_routes_shape(tmp_path, monkeypatch):
    from app.monitoring.store import LLMOutcomeStore
    store = LLMOutcomeStore(str(tmp_path / "router-metrics.db"))
    store.init_schema()
    """/api/health/llm 对 Router additive 透出 routes(默认/路由身份分组);
    非 Router 无该键(老消费者形状不变)。"""
    from app.api import health as health_module
    from tests.test_llm_monitoring import _get_llm_health

    monkeypatch.setattr(health_module, "LLM_HEALTH_TOKEN", "t-router")
    headers = {"Authorization": "Bearer t-router"}
    route = _mock("openai", "deepseek-chat")
    default = _mock("anthropic", "glm-5.3")
    router = AIClientRouter(
        default=default,
        routes={"m1_talent": route, "m2_high_low": route})

    resp = await _get_llm_health(store, router, headers)
    assert resp.status_code == 200, resp.json()
    body = resp.json()
    assert body["provider"] == "anthropic"          # 默认身份单一口径
    assert body["model"] == "glm-5.3"
    assert body["routes"] == [{
        "provider": "openai", "model": "deepseek-chat",
        "modules": ["m1_talent", "m2_high_low"]}]

    plain = await _get_llm_health(store, _mock("a", "b"), headers)
    assert "routes" not in plain.json()
