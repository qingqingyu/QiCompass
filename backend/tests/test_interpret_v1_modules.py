"""POST /api/interpret v1 prompt 系统 m0-m7 module 行为测试(Stage 4)。

覆盖:
- Module Literal 接受 m0-m7 + 老 5 个 module
- PAID_MODULES 白名单含 m2-m7,不含 m0/m1
- M1-M7 缺 parent_fingerprint → 422(链式调用契约)
- M0 缺 parent_fingerprint 不报错(它是 fingerprint 产生者)
- M4 缺 m4_age / m4_current_concern → 422(按需模块契约)
- M5 缺 m5_assets_summary / m5_preference → 422
- m0-m7 在 PROMPT_VERSIONS 未注册 → 422 "尚未支持"(Stage 5 落地前保护)
- 路由层接入 resolve_temperature(MockAIClient.last_temperature 验证)
- CacheKey parent_hash / user_input_hash 正确计算(单元测)

注:Stage 5 落地 PROMPT_VERSIONS + 模板后,m0-m7 才能真正调通。
本测试文件重点验证 schema 层契约 + 路由层 v1 接入正确性。
"""

from __future__ import annotations

import hashlib

import pytest

from app.api.interpret import _hash_parent_fingerprint, _hash_user_input
from app.config import resolve_temperature
from app.models.interpret import (
    PAID_MODULES,
    V1_CHILDREN_MODULES,
    V1_MODULES,
    InterpretRequest,
)
from app.models.interpret import Module as ModuleType  # noqa: F401 (类型导出检查)
from tests.fixtures.interpret_cases import BAZI_DEEP_CONTEXT


# ===== Module Literal / 白名单常量 =====


def test_module_literal_accepts_v1_modules():
    """m0_structure ~ m7_manual 必须能被 InterpretRequest.module 接受。

    直接构造 InterpretRequest,绕开 FastAPI 验证,纯 Pydantic 层断言。
    所有必填字段都补齐(parent_fingerprint / user_local_id / 用户输入),
    避免 422 触发让 Literal 校验失败。
    """
    base_kwargs = dict(
        content_hash="hash-v1",
        context=BAZI_DEEP_CONTEXT,
        target_date=None,
    )
    # M0 不需要 parent,免费
    InterpretRequest(module="m0_structure", **base_kwargs)
    # M1 免费
    InterpretRequest(
        module="m1_talent", parent_fingerprint="fp", **base_kwargs,
    )
    # M2/M3/M6/M7 付费,需 user_local_id + parent_fingerprint
    for m in ("m2_high_low", "m3_system", "m6_dynamics", "m7_manual"):
        InterpretRequest(
            module=m, parent_fingerprint="fp",
            user_local_id="user-1", **base_kwargs,
        )
    # M4 付费 + 用户输入
    InterpretRequest(
        module="m4_health", parent_fingerprint="fp",
        user_local_id="user-1", m4_age=30, m4_current_concern="睡眠",
        **base_kwargs,
    )
    # M5 付费 + 用户输入
    InterpretRequest(
        module="m5_wealth", parent_fingerprint="fp",
        user_local_id="user-1", m5_assets_summary="中等",
        m5_preference="平衡", **base_kwargs,
    )


def test_paid_modules_includes_v1_m2_to_m7_excludes_m0_m1():
    """PAID_MODULES 必须:含 m2-m7,不含 m0/m1。

    v1 设计决策:M0+M1 免费,M2-M7 付费。
    """
    assert "m0_structure" not in PAID_MODULES, "M0 应免费"
    assert "m1_talent" not in PAID_MODULES, "M1 应免费"
    for m in ("m2_high_low", "m3_system", "m4_health",
              "m5_wealth", "m6_dynamics", "m7_manual"):
        assert m in PAID_MODULES, f"{m} 应在 PAID_MODULES"


def test_paid_modules_keeps_old_bazi_deep_paid():
    """老 bazi_deep_paid 必须保留在 PAID_MODULES(向后兼容)。"""
    assert "bazi_deep_paid" in PAID_MODULES


def test_v1_children_excludes_m0():
    """V1_CHILDREN_MODULES = V1_MODULES - {m0_structure}。"""
    assert V1_CHILDREN_MODULES == V1_MODULES - {"m0_structure"}


# ===== 422:Schema 层交叉校验 =====


async def test_m1_without_parent_fingerprint_returns_422(interpret_client):
    """M1-M7 缺 parent_fingerprint → 422(链式调用契约:M0 输出必须注入)。"""
    resp = await interpret_client.post("/api/interpret", json={
        "content_hash": "hash-m1-no-parent",
        "module": "m1_talent",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
        # 故意不传 parent_fingerprint
    })
    assert resp.status_code == 422
    body = resp.json()
    assert "parent_fingerprint" in str(body)


async def test_m0_without_parent_fingerprint_does_not_422_on_schema(interpret_client):
    """M0 不需要 parent_fingerprint,Schema 层不报 422(虽然路由层会因为
    PROMPT_VERSIONS 未注册返 422,但 Schema 层 parent 校验不触发)。"""
    resp = await interpret_client.post("/api/interpret", json={
        "content_hash": "hash-m0",
        "module": "m0_structure",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
    })
    # Stage 4 期间 M0 必然因 PROMPT_VERSIONS 未注册返 422(不是因 parent 缺失)
    assert resp.status_code == 422, (
        f"M0 在 Stage 4 应返 422(PROMPT_VERSIONS 未注册),"
        f"实得 {resp.status_code}: {resp.json()}"
    )
    body = resp.json()
    assert "parent_fingerprint" not in str(body), (
        "M0 不应该被 parent_fingerprint 校验拦下"
    )


@pytest.mark.parametrize("module", ["m4_health", "m5_wealth"])
async def test_paid_v1_module_without_user_local_id_returns_422(
    interpret_client, module,
):
    """M4/M5 付费 module 缺 user_local_id → 422(PAID_MODULES 校验)。"""
    base = {
        "content_hash": f"hash-{module}-no-user",
        "module": module,
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
        "parent_fingerprint": "test-fingerprint",
    }
    if module == "m4_health":
        base.update(m4_age=30, m4_current_concern="睡眠不好")
    else:
        base.update(m5_assets_summary="中等", m5_preference="平衡")
    # 故意不传 user_local_id
    resp = await interpret_client.post("/api/interpret", json=base)
    assert resp.status_code == 422
    assert "user_local_id" in str(resp.json())


async def test_m4_without_age_returns_422(interpret_client):
    """M4 缺 m4_age → 422。"""
    resp = await interpret_client.post("/api/interpret", json={
        "content_hash": "hash-m4-no-age",
        "module": "m4_health",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
        "parent_fingerprint": "fp",
        "user_local_id": "user-1",
        "m4_current_concern": "睡眠不好",
        # 故意不传 m4_age
    })
    assert resp.status_code == 422
    assert "m4_age" in str(resp.json())


async def test_m4_without_concern_returns_422(interpret_client):
    """M4 缺 m4_current_concern → 422。"""
    resp = await interpret_client.post("/api/interpret", json={
        "content_hash": "hash-m4-no-concern",
        "module": "m4_health",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
        "parent_fingerprint": "fp",
        "user_local_id": "user-1",
        "m4_age": 30,
        # 故意不传 m4_current_concern
    })
    assert resp.status_code == 422
    assert "m4_current_concern" in str(resp.json())


async def test_m5_without_assets_returns_422(interpret_client):
    """M5 缺 m5_assets_summary → 422。"""
    resp = await interpret_client.post("/api/interpret", json={
        "content_hash": "hash-m5-no-assets",
        "module": "m5_wealth",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
        "parent_fingerprint": "fp",
        "user_local_id": "user-1",
        "m5_preference": "平衡",
        # 故意不传 m5_assets_summary
    })
    assert resp.status_code == 422
    assert "m5_assets_summary" in str(resp.json())


async def test_m5_without_preference_returns_422(interpret_client):
    """M5 缺 m5_preference → 422。"""
    resp = await interpret_client.post("/api/interpret", json={
        "content_hash": "hash-m5-no-pref",
        "module": "m5_wealth",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
        "parent_fingerprint": "fp",
        "user_local_id": "user-1",
        "m5_assets_summary": "中等收入",
        # 故意不传 m5_preference
    })
    assert resp.status_code == 422
    assert "m5_preference" in str(resp.json())


# ===== Stage 5 落地后:m0-m7 已注册到 PROMPT_VERSIONS,context 校验生效 =====


@pytest.mark.parametrize("module", [
    "m0_structure", "m1_talent", "m2_high_low", "m3_system",
    "m4_health", "m5_wealth", "m6_dynamics", "m7_manual",
])
async def test_v1_module_with_legacy_context_returns_422_missing_fields(
    interpret_client, module, tmp_entitlement_store,
):
    """m0-m7 已注册到 PROMPT_VERSIONS(Stage 5);用老 BAZI_DEEP_CONTEXT 调用
    会因缺 chart / structure_fingerprint 等 v1 必填字段返 422。

    Stage 4 期间这些测试断言"尚未支持";Stage 5 落地后 PROMPT_VERSIONS
    已注册,行为变为 validate_context 拦截 context 缺字段。
    """
    payload = {
        "content_hash": f"hash-{module}-legacy-ctx",
        "module": module,
        "context": BAZI_DEEP_CONTEXT,  # 不含 chart / structure_fingerprint 等
        "target_date": None,
    }
    if module in V1_CHILDREN_MODULES:
        payload["parent_fingerprint"] = "fp"
    if module in PAID_MODULES:
        payload["user_local_id"] = "user-1"
        _seed_entitlement_for_v1(
            tmp_entitlement_store,
            content_hash=payload["content_hash"],
            module=module,
            user_local_id="user-1",
        )
    if module == "m4_health":
        payload["m4_age"] = 30
        payload["m4_current_concern"] = "睡眠"
    if module == "m5_wealth":
        payload["m5_assets_summary"] = "中等"
        payload["m5_preference"] = "平衡"

    resp = await interpret_client.post("/api/interpret", json=payload)
    assert resp.status_code == 422
    body = resp.json()
    # 不再返"尚未支持"(PROMPT_VERSIONS 已注册);返"prompt 渲染缺字段"
    assert "尚未支持" not in str(body), (
        f"Stage 5 后 PROMPT_VERSIONS 已注册 {module},不应返'尚未支持': {body}"
    )
    assert "缺字段" in str(body) or "chart" in str(body).lower(), (
        f"应返 validate_context 的缺字段错误,body={body}"
    )


def _seed_entitlement_for_v1(
    store, *, content_hash: str, module: str, user_local_id: str,
) -> None:
    """给 v1 付费 module 塞 entitlement(避免 403 卡在 entitlement 层)。

    2026-08-23 断链修复:module 一律存 base 名 "bazi_deep"——路由层对 v1
    module 也映射回 bazi_deep 查询(单 SKU 解锁全部深度付费内容),iOS
    redeem 恒写 bazi_deep,seed 形态与生产数据一致。module 参数保留
    (用于 tx_id 区分),不再进 entitlement 行。
    """
    store.insert(
        transaction_id=f"tx-{module}-{content_hash[:8]}",
        product_id="com.qicompass.deep_analysis.single",
        content_hash=content_hash,
        module="bazi_deep",
        user_local_id=user_local_id,
        purchased_at="2026-08-01T00:00:00+00:00",
        original_purchase_date="2026-08-01T00:00:00+00:00",
    )


# ===== 路由层 temperature 接入 =====


async def test_old_module_passes_default_temperature_to_provider(
    interpret_client, mock_ai_client,
):
    """老模块(bazi_deep_free)走 resolve_temperature = AI_DEFAULT_TEMPERATURE = 0.6。"""
    resp = await interpret_client.post("/api/interpret", json={
        "content_hash": "hash-old-temp",
        "module": "bazi_deep_free",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
    })
    assert resp.status_code == 200, resp.json()
    # MockAIClient 接 interpret(prompt, *, temperature=0.6) 应被调到
    assert mock_ai_client.last_temperature == 0.6


def test_resolve_temperature_returns_expected_for_all_v1_modules():
    """所有 v1 module 必须返回 v1 §1 设计的 temperature 分级值。

    单元测:不需要走 HTTP,直接调函数。
    """
    expected = {
        "m0_structure": 0.3, "m1_talent": 0.3, "m2_high_low": 0.3,
        "m3_system": 0.6, "m4_health": 0.6, "m5_wealth": 0.6,
        "m6_dynamics": 0.6, "m7_manual": 0.6,
    }
    for module, temp in expected.items():
        assert resolve_temperature(module) == temp, (
            f"{module} 应返回 {temp},实得 {resolve_temperature(module)}"
        )


# ===== CacheKey 维度扩展:parent_hash / user_input_hash 计算(单元测)=====


def test_hash_parent_fingerprint_none_returns_empty():
    """parent_fingerprint=None(老模块 + M0)→ 空串。"""
    assert _hash_parent_fingerprint(None) == ""


def test_hash_parent_fingerprint_empty_returns_empty():
    """parent_fingerprint="" → 空串(同 None 行为)。"""
    assert _hash_parent_fingerprint("") == ""


def test_hash_parent_fingerprint_value_returns_sha256():
    """parent_fingerprint 非空 → sha256 hex 64 字符。"""
    result = _hash_parent_fingerprint("结构指纹示例")
    assert result == hashlib.sha256("结构指纹示例".encode("utf-8")).hexdigest()
    assert len(result) == 64


def test_hash_user_input_old_module_returns_empty():
    """老模块(bazi_deep_free)无用户输入维度 → 空串。"""
    req = InterpretRequest(
        content_hash="h",
        module="bazi_deep_free",
        context=BAZI_DEEP_CONTEXT,
        target_date=None,
    )
    assert _hash_user_input(req) == ""


def test_hash_user_input_m0_returns_empty():
    """M0 自身无用户输入 → 空串。"""
    req = InterpretRequest(
        content_hash="h",
        module="m0_structure",
        context=BAZI_DEEP_CONTEXT,
        target_date=None,
    )
    assert _hash_user_input(req) == ""


def test_hash_user_input_m4_returns_deterministic_hash():
    """M4 用户输入 → sha256,确定性。"""
    req = InterpretRequest(
        content_hash="h",
        module="m4_health",
        context=BAZI_DEEP_CONTEXT,
        target_date=None,
        parent_fingerprint="fp",
        user_local_id="u1",
        m4_age=30,
        m4_current_concern="睡眠不好",
    )
    h1 = _hash_user_input(req)
    h2 = _hash_user_input(req)
    assert h1 == h2, "同输入必须同哈希(确定性)"
    assert h1 != ""


def test_hash_user_input_m4_different_age_different_hash():
    """M4 不同 age → 不同哈希(隔离维度有效)。"""
    req_30 = InterpretRequest(
        content_hash="h", module="m4_health", context=BAZI_DEEP_CONTEXT,
        target_date=None, parent_fingerprint="fp", user_local_id="u1",
        m4_age=30, m4_current_concern="睡眠",
    )
    req_35 = InterpretRequest(
        content_hash="h", module="m4_health", context=BAZI_DEEP_CONTEXT,
        target_date=None, parent_fingerprint="fp", user_local_id="u1",
        m4_age=35, m4_current_concern="睡眠",
    )
    assert _hash_user_input(req_30) != _hash_user_input(req_35)


def test_hash_user_input_m5_returns_deterministic_hash():
    """M5 用户输入 → sha256,确定性。"""
    req = InterpretRequest(
        content_hash="h",
        module="m5_wealth",
        context=BAZI_DEEP_CONTEXT,
        target_date=None,
        parent_fingerprint="fp",
        user_local_id="u1",
        m5_assets_summary="中等收入",
        m5_preference="平衡",
    )
    h1 = _hash_user_input(req)
    expected_payload = "assets=中等收入|preference=平衡"
    expected = hashlib.sha256(expected_payload.encode("utf-8")).hexdigest()
    assert h1 == expected


def test_hash_user_input_m5_different_preference_different_hash():
    """M5 不同 preference → 不同哈希。"""
    req_balanced = InterpretRequest(
        content_hash="h", module="m5_wealth", context=BAZI_DEEP_CONTEXT,
        target_date=None, parent_fingerprint="fp", user_local_id="u1",
        m5_assets_summary="中等", m5_preference="平衡",
    )
    req_aggressive = InterpretRequest(
        content_hash="h", module="m5_wealth", context=BAZI_DEEP_CONTEXT,
        target_date=None, parent_fingerprint="fp", user_local_id="u1",
        m5_assets_summary="中等", m5_preference="进攻",
    )
    assert _hash_user_input(req_balanced) != _hash_user_input(req_aggressive)


# ===== 2026-08-23 断链修复:entitlement base module 映射 =====


def test_entitlement_base_module_mapping_covers_all_paid_modules():
    """映射键域与 PAID_MODULES 严格一致(加白名单漏映射会 RuntimeError,
    此处提前在测试层暴露)。"""
    from app.models.interpret import _ENTITLEMENT_BASE_MODULE
    assert set(_ENTITLEMENT_BASE_MODULE) == PAID_MODULES, (
        f"PAID_MODULES 与 _ENTITLEMENT_BASE_MODULE 键域漂移:"
        f"仅白名单={PAID_MODULES - set(_ENTITLEMENT_BASE_MODULE)} "
        f"仅映射={set(_ENTITLEMENT_BASE_MODULE) - PAID_MODULES}"
    )


def test_entitlement_base_module_deep_modules_map_to_bazi_deep():
    """bazi_deep_paid + v1 M2-M7 → bazi_deep(单 SKU 解锁全部深度付费内容,
    MONETIZATION.md 设计本意;iOS redeem 恒写 bazi_deep)。"""
    from app.models.interpret import entitlement_base_module
    assert entitlement_base_module("bazi_deep_paid") == "bazi_deep"
    for m in ("m2_high_low", "m3_system", "m4_health",
              "m5_wealth", "m6_dynamics", "m7_manual"):
        assert entitlement_base_module(m) == "bazi_deep", (
            f"{m} 应映射到 bazi_deep"
        )


def test_entitlement_base_module_compatibility_modules_map_to_compatibility():
    """compatibility_paid + compatibility alias → compatibility。"""
    from app.models.interpret import entitlement_base_module
    assert entitlement_base_module("compatibility_paid") == "compatibility"
    assert entitlement_base_module("compatibility") == "compatibility"


def test_entitlement_base_module_unknown_raises_runtime_error():
    """未知付费 module → RuntimeError(代码 bug 显式暴露,不静默兜底)。"""
    from app.models.interpret import entitlement_base_module
    with pytest.raises(RuntimeError, match="需同步补映射"):
        entitlement_base_module("not_a_real_module")


# 能过 validate_context 的最小 m2 context(全部标量;内容值任意)
_V1_M2_CONTEXT = {
    "chart": '{"pillars": "test-chart"}',
    "structure_fingerprint": "fp-test",
    "innate": '["天赋A"]',
    "defensive": '["防御B"]',
}


def test_module_literal_accepts_compatibility_split_modules():
    """M4 拆分:compatibility_free / compatibility_paid 必须过 Literal
    (2026-08-23 修复:此前 iOS 发这两值会被 Literal 422,合盘 AI 解读
    对真后端全量不可用)。"""
    base_kwargs = dict(
        content_hash="hash-compat-split",
        context=BAZI_DEEP_CONTEXT,  # Literal 层测试,context 内容无关
        target_date=None,
    )
    InterpretRequest(module="compatibility_free", **base_kwargs)
    InterpretRequest(
        module="compatibility_paid", user_local_id="user-1", **base_kwargs,
    )
    # compatibility alias 进 PAID_MODULES 后也要求 user_local_id
    InterpretRequest(
        module="compatibility", user_local_id="user-1", **base_kwargs,
    )


async def test_v1_paid_module_no_entitlement_returns_403(interpret_client):
    """v1 付费 module 无 entitlement → 403(越狱保护覆盖 v1 链)。

    用能过 validate_context 的最小 v1 context,确保请求走到 entitlement
    检查(步骤 2.5)而非提前 422。
    """
    payload = {
        "content_hash": "hash-m2-no-ent",
        "module": "m2_high_low",
        "context": _V1_M2_CONTEXT,
        "target_date": None,
        "parent_fingerprint": "fp",
        "user_local_id": "user-1",
    }
    resp = await interpret_client.post("/api/interpret", json=payload)
    assert resp.status_code == 403, resp.json()
    assert resp.json()["error"]["code"] == "ENTITLEMENT_NOT_FOUND"


async def test_v1_paid_module_with_bazi_deep_entitlement_passes_gate(
    interpret_client, tmp_entitlement_store,
):
    """断链修复核心回归:一条 module="bazi_deep" 的 entitlement
    (iOS redeem 实际写入形态)→ v1 付费 module(m2)过门控 → 200。

    修复前:路由按 m2_high_low 原名查 entitlement,已购用户同样 403;
    修复后:映射回 bazi_deep,与 iOS 写入形态对齐。
    """
    content_hash = "hash-m2-ent-pass"
    payload = {
        "content_hash": content_hash,
        "module": "m2_high_low",
        "context": _V1_M2_CONTEXT,
        "target_date": None,
        "parent_fingerprint": "fp",
        "user_local_id": "user-1",
    }
    _seed_entitlement_for_v1(
        tmp_entitlement_store,
        content_hash=content_hash,
        module="m2_high_low",
        user_local_id="user-1",
    )
    resp = await interpret_client.post("/api/interpret", json=payload)
    assert resp.status_code == 200, resp.json()
    assert resp.json()["interpretation"]
