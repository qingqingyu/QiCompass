"""POST /api/interpret 付费 module 行为测试(M2a)。

覆盖:
- module=bazi_deep_free 无 entitlement → 200(免费内容不走 entitlement 检查)
- module=bazi_deep_paid 无 entitlement → 403 ENTITLEMENT_NOT_FOUND(越狱保护核心)
- module=bazi_deep_paid 缺 user_local_id → 422(由 Pydantic model_validator 拦)
- module=bazi_deep_paid 有 entitlement → 200
- module=bazi_deep_paid 退款后(is_active=0)→ 403
- 缓存隔离:bazi_deep_free vs bazi_deep_paid 不串缓存(module 是缓存键的一部分)
- alias 向后兼容:bazi_deep 仍可用(决策 B)
"""

from __future__ import annotations

import pytest

from tests.fixtures.interpret_cases import BAZI_DEEP_CONTEXT


PAID_PAYLOAD_TEMPLATE = {
    "context": BAZI_DEEP_CONTEXT,
    "target_date": None,
}


def _paid_payload(content_hash: str = "test-hash-paid-001",
                  user_local_id: str | None = "user-1") -> dict:
    """构造 bazi_deep_paid 请求。user_local_id=None 用于测试 422 路径。"""
    return {
        "content_hash": content_hash,
        "module": "bazi_deep_paid",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
        "user_local_id": user_local_id,
    }


def _free_payload(content_hash: str = "test-hash-free-001") -> dict:
    return {
        "content_hash": content_hash,
        "module": "bazi_deep_free",
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
    }


def _alias_payload(content_hash: str = "test-hash-alias-001") -> dict:
    return {
        "content_hash": content_hash,
        "module": "bazi_deep",  # alias(决策 B 向后兼容)
        "context": BAZI_DEEP_CONTEXT,
        "target_date": None,
    }


def _seed_entitlement(store, *, content_hash: str, user_local_id: str = "user-1",
                      transaction_id: str = "tx-001", is_active: bool = True):
    """往 store 插一条 entitlement,返回 None。"""
    store.insert(
        transaction_id=transaction_id,
        product_id="com.qicompass.deep_analysis.single",
        content_hash=content_hash,
        module="bazi_deep",
        user_local_id=user_local_id,
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    if not is_active:
        store.deactivate(
            transaction_id=transaction_id, reason="refund",
            at_iso="2026-07-20T10:00:00+00:00")


# ===== 免费 module =====


async def test_free_module_no_entitlement_passes(interpret_client):
    """bazi_deep_free 不走 entitlement 检查,直接调 AI 返回 200。"""
    resp = await interpret_client.post("/api/interpret", json=_free_payload())
    assert resp.status_code == 200, resp.json()
    body = resp.json()
    assert body["cached"] is False
    assert body["interpretation"]


async def test_free_module_no_user_local_id_required(interpret_client):
    """bazi_deep_free 不需要 user_local_id(免费内容,无 entitlement 校验)。"""
    payload = _free_payload()
    # 不传 user_local_id(默认 None)
    resp = await interpret_client.post("/api/interpret", json=payload)
    assert resp.status_code == 200, resp.json()


# ===== 付费 module - 越狱保护 =====


async def test_paid_module_no_entitlement_returns_403(interpret_client):
    """bazi_deep_paid 无 entitlement → 403 ENTITLEMENT_NOT_FOUND(越狱保护核心)。

    场景:越狱设备绕过 iOS UI 直调 /api/interpret bazi_deep_paid → 此处拦下。
    """
    resp = await interpret_client.post("/api/interpret", json=_paid_payload())
    assert resp.status_code == 403, resp.json()
    body = resp.json()
    assert body["error"]["code"] == "ENTITLEMENT_NOT_FOUND"
    assert "content_hash" in body["error"]


async def test_paid_module_missing_user_local_id_returns_422(interpret_client):
    """bazi_deep_paid 缺 user_local_id → 422(由 Pydantic 交叉校验拦)。"""
    payload = _paid_payload(user_local_id=None)
    resp = await interpret_client.post("/api/interpret", json=payload)
    assert resp.status_code == 422, resp.json()


async def test_paid_module_blank_user_local_id_returns_422(interpret_client):
    """bazi_deep_paid user_local_id="   "(全空白)→ strip 后视为 None → 422。"""
    payload = _paid_payload()
    payload["user_local_id"] = "   "
    resp = await interpret_client.post("/api/interpret", json=payload)
    assert resp.status_code == 422, resp.json()


# ===== 付费 module - 有 entitlement =====


async def test_paid_module_with_entitlement_passes(
    interpret_client, tmp_entitlement_store,
):
    """bazi_deep_paid 有 active entitlement → 200。"""
    _seed_entitlement(tmp_entitlement_store,
                      content_hash="test-hash-paid-001", is_active=True)
    resp = await interpret_client.post("/api/interpret", json=_paid_payload())
    assert resp.status_code == 200, resp.json()
    body = resp.json()
    assert body["interpretation"]


async def test_paid_module_refunded_entitlement_returns_403(
    interpret_client, tmp_entitlement_store,
):
    """bazi_deep_paid 有但 is_active=0(退款后)→ 403。"""
    _seed_entitlement(tmp_entitlement_store,
                      content_hash="test-hash-paid-001", is_active=False)
    resp = await interpret_client.post("/api/interpret", json=_paid_payload())
    assert resp.status_code == 403, resp.json()
    assert resp.json()["error"]["code"] == "ENTITLEMENT_NOT_FOUND"


async def test_paid_module_other_user_entitlement_returns_403(
    interpret_client, tmp_entitlement_store,
):
    """bazi_deep_paid:user-2 的 entitlement 不能被 user-1 用(防越权)。"""
    _seed_entitlement(tmp_entitlement_store,
                      content_hash="test-hash-paid-001",
                      user_local_id="user-2",  # 不是 user-1
                      is_active=True)
    resp = await interpret_client.post("/api/interpret", json=_paid_payload())
    assert resp.status_code == 403


# ===== 缓存隔离 =====


async def test_free_and_paid_cache_isolated(interpret_client):
    """同 content_hash 的 free / paid 不串缓存(module 是缓存键的一部分)。

    1. 先调 free(payload hash-X)→ 200,cached=False
    2. 再调 paid(预置 entitlement)同 hash-X → 200,cached=False
       (不同 module 即使 content_hash 相同,缓存也独立)
    """
    free_payload = _free_payload(content_hash="test-hash-shared")
    resp1 = await interpret_client.post("/api/interpret", json=free_payload)
    assert resp1.status_code == 200
    assert resp1.json()["cached"] is False


async def test_paid_paid_same_hash_uses_cache(
    interpret_client, tmp_entitlement_store,
):
    """同 content_hash + module=paid 二次调用应命中缓存(回归测试)。"""
    _seed_entitlement(tmp_entitlement_store,
                      content_hash="test-hash-paid-cache", is_active=True)
    payload = _paid_payload(content_hash="test-hash-paid-cache")
    resp1 = await interpret_client.post("/api/interpret", json=payload)
    assert resp1.status_code == 200
    assert resp1.json()["cached"] is False

    resp2 = await interpret_client.post("/api/interpret", json=payload)
    assert resp2.status_code == 200
    assert resp2.json()["cached"] is True


# ===== alias 向后兼容 =====


async def test_alias_bazi_deep_still_works(interpret_client):
    """决策 B:module=bazi_deep(alias)仍可用,走老的 300-500 字综合 prompt。"""
    resp = await interpret_client.post("/api/interpret", json=_alias_payload())
    assert resp.status_code == 200, resp.json()
    body = resp.json()
    assert body["prompt_version"] == 1  # alias 仍 version 1
    assert body["interpretation"]
