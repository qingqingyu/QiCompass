"""LLM 监控闭环测试(2026-10-09 A 档):reason 分型 / store / MeteredAIClient
/ 失败率告警 / GET /api/health/llm。

六块:
1. client reason 分型(anthropic/openai 全 raise 点,mirror
   test_anthropic_client.py 的 fake AsyncClient 注入法)
2. LLMOutcomeStore 单元(小时桶计数/滚动窗口/last_error 覆盖与截断)
3. MeteredAIClient(计数旁路不改写异常;success/unexpected 分型)
4. 告警节流 + 恢复(caplog;含 2026-10-10 开机首警不被吞,monotonic 钉死)
5. /api/health/llm 聚合(空库/种子/provider 过滤/告警态)+ Bearer token
   鉴权(2026-10-10:未配置 404 / 缺头错值畸形 401)
6. 翻译监控维度 translate: 前缀(2026-10-10 外评:与生成分桶)
"""

from __future__ import annotations

import types

import httpx
import pytest

from app.errors import AIProviderError
from app.monitoring import metered as metered_module
from app.monitoring.metered import MeteredAIClient
from app.monitoring.store import LLMOutcomeStore, hour_key


@pytest.fixture
def tmp_metrics_store(tmp_path):
    """临时 LLMOutcomeStore(每测试独立 DB)。"""
    store = LLMOutcomeStore(str(tmp_path / "test_llm_metrics.db"))
    store.init_schema()
    return store


@pytest.fixture(autouse=True)
def _clear_alert_state():
    """告警节流态是进程级 module 变量,跨测试必须清零。"""
    metered_module._last_alert_emit.clear()
    yield
    metered_module._last_alert_emit.clear()


# ===== 1. client reason 分型 =====


class _FakeResponse:
    """最小 response 桩:可控 raise_for_status / json。"""

    def __init__(self, payload=None, status_code=None):
        self._payload = payload
        self.status_code = status_code

    def raise_for_status(self) -> None:
        if self.status_code is None or self.status_code < 400:
            return
        request = httpx.Request("POST", "https://fake.local")
        response = httpx.Response(self.status_code, request=request)
        raise httpx.HTTPStatusError(
            f"HTTP {self.status_code}", request=request, response=response)

    def json(self):
        if self._payload is None:
            raise ValueError("no json")
        return self._payload


def _install_fake_async_client(monkeypatch, target_module, handler):
    """替换 target_module.httpx.AsyncClient 为走 handler 的假 client。"""

    class _FakeAsyncClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def post(self, url, **kwargs):
            return handler(url, **kwargs)

    monkeypatch.setattr(target_module.httpx, "AsyncClient", _FakeAsyncClient)


@pytest.mark.parametrize("handler,expected_reason", [
    # timeout:handler 抛 httpx.TimeoutException
    (lambda url, **kw: (_ for _ in ()).throw(httpx.ConnectTimeout("t")),
     "timeout"),
    # 429 / 401 / 500
    (lambda url, **kw: _FakeResponse(status_code=429), "rate_limit"),
    (lambda url, **kw: _FakeResponse(status_code=401), "auth"),
    (lambda url, **kw: _FakeResponse(status_code=500), "http_error"),
    # 网络错误(非超时的 RequestError)
    (lambda url, **kw: (_ for _ in ()).throw(httpx.ConnectError("refused")),
     "network"),
    # 响应形状非法
    (lambda url, **kw: _FakeResponse(payload=None), "bad_response"),
    # 截断
    (lambda url, **kw: _FakeResponse(payload={
        "stop_reason": "max_tokens",
        "content": [{"type": "text", "text": "半截"}],
    }), "truncated"),
])
async def test_anthropic_reason_classification(
        monkeypatch, handler, expected_reason):
    """AnthropicClient 全失败路径 reason 分型(机器可读,监控计数维度)。"""
    from app.ai import anthropic_client as anthropic_module
    from app.ai.anthropic_client import AnthropicClient
    _install_fake_async_client(monkeypatch, anthropic_module, handler)
    with pytest.raises(AIProviderError) as exc_info:
        await AnthropicClient(api_key="test-key").interpret("prompt")
    assert exc_info.value.reason == expected_reason


async def test_anthropic_no_api_key_reason():
    """key 未配置:零网络往返即失败,reason=no_api_key。"""
    from app.ai.anthropic_client import AnthropicClient
    with pytest.raises(AIProviderError) as exc_info:
        await AnthropicClient(api_key=None).interpret("prompt")
    assert exc_info.value.reason == "no_api_key"


@pytest.mark.parametrize("handler,expected_reason", [
    (lambda url, **kw: _FakeResponse(status_code=429), "rate_limit"),
    (lambda url, **kw: _FakeResponse(payload={
        "choices": [{"message": {"content": "x"}, "finish_reason":
                     "content_filter"}],
    }), "content_filter"),
    (lambda url, **kw: _FakeResponse(payload={
        "choices": [{"message": {"content": "半截"}, "finish_reason":
                     "length"}],
    }), "truncated"),
    (lambda url, **kw: (_ for _ in ()).throw(httpx.ReadTimeout("t")),
     "timeout"),
])
async def test_openai_reason_classification(
        monkeypatch, handler, expected_reason):
    """OpenAIClient 分型与 anthropic 对称(截断/内容过滤为独有分型)。"""
    from app.ai import openai_client as openai_module
    from app.ai.openai_client import OpenAIClient
    _install_fake_async_client(monkeypatch, openai_module, handler)
    with pytest.raises(AIProviderError) as exc_info:
        await OpenAIClient(api_key="test-key").interpret("prompt")
    assert exc_info.value.reason == expected_reason


async def test_reason_defaults_to_unknown():
    """不带 reason 构造(interpret.py pipeline 失败)→ unknown 默认值,
    契约向后兼容(既有 raise 点零改动)。"""
    assert AIProviderError("x").reason == "unknown"


# ===== 2. LLMOutcomeStore 单元 =====


def test_store_record_and_window(tmp_metrics_store):
    """计数落正确小时桶;get_counts 闭区间聚合;跨桶不串。"""
    s = tmp_metrics_store
    for _ in range(3):
        s.record(hour="2026-10-09T10", provider="anthropic",
                 module="m0_structure", outcome="success")
    s.record(hour="2026-10-09T10", provider="anthropic",
             module="m0_structure", outcome="timeout")
    s.record(hour="2026-10-09T09", provider="anthropic",
             module="m0_structure", outcome="timeout")
    s.record(hour="2026-10-09T10", provider="openai",
             module="m0_structure", outcome="success")

    counts = s.get_counts(start_hour="2026-10-09T10", end_hour="2026-10-09T10")
    assert counts[("anthropic", "m0_structure", "success")] == 3
    assert counts[("anthropic", "m0_structure", "timeout")] == 1
    assert counts[("openai", "m0_structure", "success")] == 1

    # 滚动窗口(闭区间,含两端)
    counts_2h = s.get_counts(
        start_hour="2026-10-09T09", end_hour="2026-10-09T10")
    assert counts_2h[("anthropic", "m0_structure", "timeout")] == 2

    # 窗口外不串
    assert ("anthropic", "m0_structure", "timeout") not in s.get_counts(
        start_hour="2026-10-09T11", end_hour="2026-10-09T11")


def test_store_init_schema_idempotent(tmp_metrics_store):
    """重复 init_schema 幂等(老库零迁移口径)。"""
    tmp_metrics_store.init_schema()
    tmp_metrics_store.record(hour="2026-10-09T10", provider="anthropic",
                             module="m0_structure", outcome="success")
    tmp_metrics_store.init_schema()
    assert tmp_metrics_store.get_counts(
        start_hour="2026-10-09T10", end_hour="2026-10-09T10")[
            ("anthropic", "m0_structure", "success")] == 1


def test_store_last_error_overwrite_and_truncate(tmp_metrics_store, tmp_path):
    """last_error 单行覆盖写;message 超长截断(防异常文本撑大单行)。"""
    s = tmp_metrics_store
    s.record_last_error(occurred_at="2026-10-09T10:00:00+00:00",
                        provider="anthropic", module="m4_health",
                        reason="timeout", message="first")
    s.record_last_error(occurred_at="2026-10-09T10:05:00+00:00",
                        provider="anthropic", module="m5_wealth",
                        reason="rate_limit", message="x" * 2000)
    got = s.get_last_error()
    assert got["reason"] == "rate_limit"
    assert got["module"] == "m5_wealth"
    assert got["message"] == "x" * 500, "截断到 500 字符"
    # 无失败快照的全新库(store 契约为文件库短连接,同 FreeLLMQuotaStore;
    # :memory: 每次连接即新库,init_schema 建表即丢,不支持)
    fresh = LLMOutcomeStore(str(tmp_path / "fresh_metrics.db"))
    fresh.init_schema()
    assert fresh.get_last_error() is None


# ===== 3. MeteredAIClient =====


class _StubInner:
    """受控 inner:按指令返回或抛,module 形参被捕获。"""

    provider = "anthropic"
    model = "stub-model"

    def __init__(self):
        self.last_module = "unset"
        self.action = ("return", "命书")

    async def interpret(self, prompt, *, temperature=0.6,
                        max_tokens=None, timeout=None, module=None):
        self.last_module = module
        kind, value = self.action
        if kind == "return":
            return value
        raise value


async def test_metered_success_records_outcome(tmp_metrics_store):
    """成功 → (hour, provider, module, success) +1,module 透传给 inner。"""
    from datetime import datetime, timezone
    inner = _StubInner()
    client = MeteredAIClient(inner, tmp_metrics_store)

    text = await client.interpret("prompt", module="m0_structure")
    await metered_module.wait_for_pending_records()

    assert text == "命书"
    assert inner.last_module == "m0_structure"
    assert client.provider == "anthropic" and client.model == "stub-model"
    hour = hour_key(datetime.now(timezone.utc))
    counts = tmp_metrics_store.get_counts(
        start_hour=hour, end_hour=hour)
    assert counts.get(("anthropic", "m0_structure", "success")) == 1
    assert tmp_metrics_store.get_last_error() is None, "成功不写失败快照"


async def test_metered_failure_records_reason_and_reraises(
        tmp_metrics_store):
    """AIProviderError → reason 计数 + last_error 快照;**同一异常对象**
    原样上抛(监控只旁观,不改写不包装)。"""
    from datetime import datetime, timezone
    inner = _StubInner()
    boom = AIProviderError("Anthropic API 超时", reason="timeout")
    inner.action = ("raise", boom)
    client = MeteredAIClient(inner, tmp_metrics_store)

    with pytest.raises(AIProviderError) as exc_info:
        await client.interpret("prompt", module="m4_health")
    await metered_module.wait_for_pending_records()

    assert exc_info.value is boom, "异常对象必须原样上抛"
    hour = hour_key(datetime.now(timezone.utc))
    counts = tmp_metrics_store.get_counts(start_hour=hour, end_hour=hour)
    assert counts.get(("anthropic", "m4_health", "timeout")) == 1
    last_error = tmp_metrics_store.get_last_error()
    assert last_error["reason"] == "timeout"
    assert last_error["module"] == "m4_health"


async def test_metered_unexpected_exception_bucket(tmp_metrics_store):
    """client 未包到的异常 → outcome=unexpected 可用性兜底,原样上抛。"""
    from datetime import datetime, timezone
    inner = _StubInner()
    boom = RuntimeError("包修漏了")
    inner.action = ("raise", boom)
    client = MeteredAIClient(inner, tmp_metrics_store)

    with pytest.raises(RuntimeError) as exc_info:
        await client.interpret("prompt")
    await metered_module.wait_for_pending_records()
    assert exc_info.value is boom
    hour = hour_key(datetime.now(timezone.utc))
    counts = tmp_metrics_store.get_counts(start_hour=hour, end_hour=hour)
    # module=None → "unknown" 桶
    assert counts.get(("anthropic", "unknown", "unexpected")) == 1


async def test_metered_store_failure_does_not_break_call(tmp_metrics_store):
    """store 写失败只记日志,不反噬主路径(对齐退款失败先例);
    成功文本照常返回。"""
    def _boom(*args, **kwargs):
        raise RuntimeError("sqlite gone")

    inner = _StubInner()
    client = MeteredAIClient(inner, tmp_metrics_store)
    # record / last_error / 告警评估读全炸:调用仍成功
    tmp_metrics_store.record = _boom
    tmp_metrics_store.record_last_error = _boom
    tmp_metrics_store.get_counts = _boom
    text = await client.interpret("prompt", module="m0_structure")
    await metered_module.wait_for_pending_records()
    assert text == "命书"


# ===== 4. 失败率告警 =====


async def test_alert_emits_when_threshold_crossed(
        tmp_metrics_store, monkeypatch, caplog):
    """当前小时桶 ≥min_calls 且失败率 ≥阈值 → ERROR ALERT 恰一次;
    持续失败受 10min 节流不再刷屏。monotonic 钉死在小值:告警判定不依赖
    机器开机时长(首告警被节流吞的回归锁,2026-10-10 外评 #1)。"""
    import logging
    monkeypatch.setattr(metered_module, "LLM_ALERT_MIN_CALLS", 3)
    monkeypatch.setattr(metered_module, "LLM_ALERT_FAILURE_RATE", 0.5)
    # 模拟刚开机 89 秒的机器:修复前 get(provider, 0.0) 把「从未告警」当
    # 「第 0 秒告警过」,89 < 600 → 首告警被吞(开机久的开发机测不出)。
    # 补丁打在 metered 命名空间的 time 引用上(而非 stdlib time 模块本体
    # ——那是全进程共享的,asyncio loop.time()/任何 sleep 都吃它,冻结后
    # 被测链路一旦引入定时器测试就从红变永久挂起)
    monkeypatch.setattr(
        metered_module, "time",
        types.SimpleNamespace(monotonic=lambda: 89.0))
    caplog.set_level(logging.ERROR, logger="app.monitoring.metered")

    inner = _StubInner()
    boom = AIProviderError("限流", reason="rate_limit")
    inner.action = ("raise", boom)
    client = MeteredAIClient(inner, tmp_metrics_store)

    for _ in range(5):  # 5 次全败,率 1.0 ≥ 0.5,total 5 ≥ 3
        with pytest.raises(AIProviderError):
            await client.interpret("prompt", module="m0_structure")
    await metered_module.wait_for_pending_records()

    alerts = [r for r in caplog.records
              if "ALERT llm_failure_rate" in r.message]
    assert len(alerts) == 1, "持续失败受 10min 节流,只发一次"
    assert "provider=anthropic" in alerts[0].message
    assert "rate=1.00" in alerts[0].message


async def test_alert_silent_below_min_calls(
        tmp_metrics_store, monkeypatch, caplog):
    """低流量不告警(1/2 = 50% 但 total 2 < min_calls=3)。"""
    import logging
    monkeypatch.setattr(metered_module, "LLM_ALERT_MIN_CALLS", 3)
    monkeypatch.setattr(metered_module, "LLM_ALERT_FAILURE_RATE", 0.5)
    caplog.set_level(logging.ERROR, logger="app.monitoring.metered")

    inner = _StubInner()
    inner.action = ("raise", AIProviderError("超时", reason="timeout"))
    client = MeteredAIClient(inner, tmp_metrics_store)
    for _ in range(2):
        with pytest.raises(AIProviderError):
            await client.interpret("prompt")
    await metered_module.wait_for_pending_records()
    assert not [r for r in caplog.records
                if "ALERT llm_failure_rate" in r.message]


async def test_alert_resolved_after_recovery(
        tmp_metrics_store, monkeypatch, caplog):
    """告警后转健康 → INFO ALERT_RESOLVED 留痕。"""
    import logging
    monkeypatch.setattr(metered_module, "LLM_ALERT_MIN_CALLS", 2)
    monkeypatch.setattr(metered_module, "LLM_ALERT_FAILURE_RATE", 0.5)
    caplog.set_level(logging.INFO, logger="app.monitoring.metered")

    inner = _StubInner()
    inner.action = ("raise", AIProviderError("超时", reason="timeout"))
    client = MeteredAIClient(inner, tmp_metrics_store)
    for _ in range(2):  # 2/2 全败 → ALERT
        with pytest.raises(AIProviderError):
            await client.interpret("prompt")
    await metered_module.wait_for_pending_records()
    assert [r for r in caplog.records
            if "ALERT llm_failure_rate" in r.message]

    inner.action = ("return", "恢复")
    for _ in range(3):  # 2 败 + 3 成 → 率 0.4 < 0.5
        await client.interpret("prompt")
    await metered_module.wait_for_pending_records()
    resolved = [r for r in caplog.records
                if "ALERT_RESOLVED llm_failure_rate" in r.message]
    assert len(resolved) == 1, "恢复恰留痕一次"


# ===== 5. GET /api/health/llm =====


class _HealthStubClient:
    provider = "anthropic"
    model = "stub-model"


async def _get_llm_health(store, ai_client=None, headers=None):
    """请求 /api/health/llm(鉴权 token 由调用方 monkeypatch health 模块
    的 LLM_HEALTH_TOKEN + 传 Authorization header;见鉴权测试)。"""
    from httpx import ASGITransport, AsyncClient
    from app.main import app
    saved_store = getattr(app.state, "llm_metrics_store", None)
    saved_client = getattr(app.state, "ai_client", None)
    app.state.llm_metrics_store = store
    if ai_client is not None:
        app.state.ai_client = ai_client
    try:
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="http://test",
        ) as ac:
            resp = await ac.get("/api/health/llm", headers=headers)
    finally:
        app.state.llm_metrics_store = saved_store
        app.state.ai_client = saved_client
    return resp


_TEST_LLM_HEALTH_TOKEN = "unit-test-llm-health-token"


@pytest.fixture
def llm_health_token(monkeypatch):
    """钉住 health 模块的鉴权 token(模块 import 时读 env,测试经属性注入)。"""
    from app.api import health as health_module
    monkeypatch.setattr(health_module, "LLM_HEALTH_TOKEN",
                        _TEST_LLM_HEALTH_TOKEN)
    return _TEST_LLM_HEALTH_TOKEN


async def test_health_llm_auth_fail_closed(tmp_metrics_store, monkeypatch):
    """鉴权 fail-closed:token 未配置 → 404(端点视为不存在,不暴露存在性);
    配置后缺 header / 错 token / 非 ASCII 畸形 token → 401;正确 Bearer → 200。"""
    from app.api import health as health_module
    monkeypatch.setattr(health_module, "LLM_HEALTH_TOKEN", "")

    resp = await _get_llm_health(tmp_metrics_store, _HealthStubClient())
    assert resp.status_code == 404, "未配置 token 不得暴露端点存在性"

    monkeypatch.setattr(health_module, "LLM_HEALTH_TOKEN",
                        _TEST_LLM_HEALTH_TOKEN)
    no_header = await _get_llm_health(tmp_metrics_store, _HealthStubClient())
    assert no_header.status_code == 401
    wrong = await _get_llm_health(
        tmp_metrics_store, _HealthStubClient(),
        headers={"Authorization": "Bearer wrong-token"})
    assert wrong.status_code == 401
    # 非 ASCII bearer(原始字节直发,httpx 的 str 头会先 ascii 编码拒绝,
    # 但攻击方不受 httpx 约束;服务端按 latin-1 decode 回非 ASCII str)
    # 会让 compare_digest 抛 TypeError——畸形输入只配 401,不得 500
    #(对齐 test_verify_non_ascii_token_rejected 的同类收口)。
    malformed = await _get_llm_health(
        tmp_metrics_store, _HealthStubClient(),
        headers={"Authorization": "Bearer 畸形-token".encode("utf-8")})
    assert malformed.status_code == 401, malformed.text
    ok = await _get_llm_health(
        tmp_metrics_store, _HealthStubClient(),
        headers={"Authorization": f"Bearer {_TEST_LLM_HEALTH_TOKEN}"})
    assert ok.status_code == 200, ok.text
    # scheme 大小写不敏感(RFC 7235,对齐 app/auth/dependencies.py 的 JWT
    # 侧 split+lower 解析):小写 bearer + 正确 token 不得 401——修复前
    # startswith("Bearer ") 严格匹配,curl 小写 bearer 在 JWT 端点可用、
    # 本端点却恒 401 的行为分叉。
    ok_lower = await _get_llm_health(
        tmp_metrics_store, _HealthStubClient(),
        headers={"Authorization": f"bearer {_TEST_LLM_HEALTH_TOKEN}"})
    assert ok_lower.status_code == 200, ok_lower.text


def test_llm_health_token_malformed_fails_fast_at_startup():
    """token 配置错误启动即崩(2026-10-10 fail-fast 家族,env 快照 + reload
    对齐 test_evalkit_config 模式):非 ASCII(Bearer 头 latin-1 传输 →
    compare_digest 恒 TypeError → 恒 401)与首尾空白(请求侧 strip 而配置
    侧不 strip → compare_digest 恒不匹配 → 恒 401)都属「端点静默永远
    不可用且无根因线索」,配置错误在启动时报,不留给运维猜。"""
    import importlib
    import os

    import app.config as cfg
    saved = os.environ.get("QICOMPASS_LLM_HEALTH_TOKEN")
    try:
        os.environ["QICOMPASS_LLM_HEALTH_TOKEN"] = "令牌-非ascii"
        with pytest.raises(ValueError, match="ASCII-only"):
            importlib.reload(cfg)
        os.environ["QICOMPASS_LLM_HEALTH_TOKEN"] = "trailing-newline\n"
        with pytest.raises(ValueError, match="首尾不得有空白"):
            importlib.reload(cfg)
    finally:
        # 恢复 env 后 reload 回进程初始状态(失败 reload 留下的部分绑定
        # 一并复位;其他模块 from-import 持有的是首轮对象,值相等无漂移)
        if saved is None:
            os.environ.pop("QICOMPASS_LLM_HEALTH_TOKEN", None)
        else:
            os.environ["QICOMPASS_LLM_HEALTH_TOKEN"] = saved
        importlib.reload(cfg)


async def test_health_llm_empty_store(tmp_metrics_store, llm_health_token):
    """空库:零计数、failure_rate=null(不是误导性的 0)、无 last_error、
    告警 inactive——新部署首查不 500。"""
    auth = {"Authorization": f"Bearer {llm_health_token}"}
    resp = await _get_llm_health(tmp_metrics_store, _HealthStubClient(),
                                 headers=auth)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["provider"] == "anthropic"
    for name in ("current_hour", "last_24h", "today"):
        w = body["windows"][name]
        assert w == {"success": 0, "failures": {}, "total": 0,
                     "failure_rate": None}, name
    assert body["last_error"] is None
    assert body["alert"]["active"] is False
    assert body["alert"]["min_calls"] >= 1


async def test_health_llm_aggregates_and_alert(tmp_metrics_store, monkeypatch,
                                                llm_health_token):
    """种子计数 → 三窗口聚合 / by_module / last_error / 告警态。
    阈值 monkeypatch 钉死(不吃环境变量):min_calls=5, rate=0.5,
    6 败 1 成 → total 7 ≥ 5、率 6/7 ≥ 0.5 → active。"""
    from datetime import datetime, timezone
    from app.api import health as health_module
    monkeypatch.setattr(health_module, "LLM_ALERT_MIN_CALLS", 5)
    monkeypatch.setattr(health_module, "LLM_ALERT_FAILURE_RATE", 0.5)
    now = datetime.now(timezone.utc)
    hour = hour_key(now)

    for _ in range(6):
        tmp_metrics_store.record(
            hour=hour, provider="anthropic", module="m4_health",
            outcome="timeout")
    tmp_metrics_store.record(
        hour=hour, provider="anthropic", module="m0_structure",
        outcome="success")
    tmp_metrics_store.record_last_error(
        occurred_at=now.isoformat(), provider="anthropic",
        module="m4_health", reason="timeout", message="Anthropic API 超时")
    # 其他 provider 的行:不得混入当前 provider 视图
    tmp_metrics_store.record(
        hour=hour, provider="openai", module="m0_structure",
        outcome="success")

    auth = {"Authorization": f"Bearer {llm_health_token}"}
    resp = await _get_llm_health(tmp_metrics_store, _HealthStubClient(),
                                 headers=auth)
    assert resp.status_code == 200, resp.text
    body = resp.json()

    w = body["windows"]["current_hour"]
    assert w["total"] == 7  # 6 timeout + 1 success(openai 行被过滤)
    assert w["success"] == 1
    assert w["failures"] == {"timeout": 6}
    assert w["failure_rate"] == round(6 / 7, 4)
    assert body["windows"]["today"]["total"] == 7
    assert body["windows"]["last_24h"]["total"] == 7

    by_module = body["today_by_module"]
    assert by_module["m4_health"]["failures"] == {"timeout": 6}
    assert by_module["m0_structure"]["success"] == 1

    assert body["last_error"]["reason"] == "timeout"
    assert body["alert"]["active"] is True
    assert body["alert"]["failure_rate"] == round(6 / 7, 4)


async def test_health_llm_last_error_other_provider_hidden(
        tmp_metrics_store, llm_health_token):
    """last_error 属旧 provider(切换后)→ 当前视图 null,不误导。"""
    from datetime import datetime, timezone
    tmp_metrics_store.record_last_error(
        occurred_at=datetime.now(timezone.utc).isoformat(),
        provider="openai", module="m4_health", reason="timeout",
        message="OpenAI API 超时")
    resp = await _get_llm_health(
        tmp_metrics_store, _HealthStubClient(),
        headers={"Authorization": f"Bearer {llm_health_token}"})
    assert resp.status_code == 200, resp.text
    assert resp.json()["last_error"] is None


async def test_health_llm_cache_control_no_store(tmp_metrics_store, llm_health_token):
    """禁 HTTP 缓存(与 /api/health 同款,读的是即时监控值)。"""
    resp = await _get_llm_health(
        tmp_metrics_store, _HealthStubClient(),
        headers={"Authorization": f"Bearer {llm_health_token}"})
    assert resp.headers["Cache-Control"] == "no-store"


# ===== 6. 翻译监控维度 translate: 前缀(2026-10-10 外评建议) =====


async def test_translate_records_prefixed_module_dimension(
        interpret_client, mock_ai_client, tmp_cache):
    """翻译调 LLM 的 module 形参带 translate: 前缀(与生成分桶,失败率
    可分型是本次修复的全部目的)。module 形参仅 MeteredAIClient 消费,
    真实 client 不消费,前缀不影响缓存键/配额桶——但若有人改回裸
    module 或误伤其它维度,此测试红。

    复用 test_interpret_translate 的 payload 构造器(键对齐同源,杜绝
    测试种子与生产键算法漂移);走真实端点锁调用点接线,而非只测
    MeteredAIClient 透传(那锁不到 interpret.py 的 f-string)。
    """
    from tests.test_interpret_translate import (
        M0_HANT_JSON, M0_ZH_JSON, _m0_translate_payload, _seed_source_row,
    )
    payload = _m0_translate_payload()
    _seed_source_row(tmp_cache, payload, M0_ZH_JSON)
    mock_ai_client.set_response(M0_HANT_JSON)
    resp = await interpret_client.post(
        "/api/interpret/translate", json=payload,
        headers={"X-QiCompass-Lang": "zh-hant"},
    )
    assert resp.status_code == 200, resp.text
    assert mock_ai_client.last_module == "translate:m0_structure", (
        "翻译调 LLM 的监控维度必须与生成分桶(translate: 前缀)")


# ===== 7. last_error URL 脱敏(2026-10-10,鉴权之外的第二道纵深) =====


async def test_health_llm_last_error_urls_redacted(
        tmp_metrics_store, llm_health_token):
    """last_error.message 的 URL 脱敏(2026-10-10):httpx 异常文本带上游
    endpoint(如中转网关地址)时,出口只留 [url] 占位——鉴权之外的第二道
    纵深,令牌泄漏也不随之暴露中转拓扑。DB 存原文,仅出口层脱敏。"""
    from datetime import datetime, timezone
    tmp_metrics_store.record_last_error(
        occurred_at=datetime.now(timezone.utc).isoformat(),
        provider="anthropic", module="m4_health", reason="network",
        message="Anthropic API 调用失败(ConnectError): "
                "https://secret-gateway.example/api/anthropic 连接被拒")
    resp = await _get_llm_health(
        tmp_metrics_store, _HealthStubClient(),
        headers={"Authorization": f"Bearer {llm_health_token}"})
    assert resp.status_code == 200, resp.text
    message = resp.json()["last_error"]["message"]
    assert "secret-gateway.example" not in message
    assert "[url]" in message


# ===== 8. join 容忍被取消任务(2026-10-10 第二十轮外评 #7) =====


async def test_wait_for_pending_records_swallows_cancelled_task():
    """优雅停机 join 对被取消任务不炸(第二十轮外评 #7):cancel 已请求、
    CancelledError 尚未落地(未 done)的任务会进 gather——裸 gather 把
    CancelledError 抛进 lifespan shutdown 钩子,其余记录随之不被 join;
    return_exceptions 后取消结果被收编,健康任务照常等完。

    构造要点:cancel 后**不**让步(不 sleep(0))直接 join——一旦让步,
    取消落地、任务变 done,会在 join 头部的 done 过滤被剔除,测不到
    gather 路径(停机窗口的真实形态恰是「取消在途」)。"""
    import asyncio

    async def forever() -> None:
        await asyncio.sleep(3600)

    healthy = asyncio.ensure_future(asyncio.sleep(0.01))
    victim = asyncio.ensure_future(forever())
    metered_module._pending_records.update({healthy, victim})
    victim.cancel()
    try:
        await metered_module.wait_for_pending_records()
    finally:
        metered_module._pending_records.discard(healthy)
        metered_module._pending_records.discard(victim)
    assert not healthy.cancelled(), "健康记录任务必须被 join 到完成"
    assert victim.cancelled(), "前置自检:victim 确以取消收场(进过 gather)"
