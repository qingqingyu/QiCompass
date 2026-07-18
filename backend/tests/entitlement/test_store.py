"""EntitlementStore CRUD + active 查询 + 幂等性测试(M2a)。

覆盖:
- init_schema 幂等(连续调两次不报错)
- insert 幂等(同 transaction_id 二次返 False)
- get_by_transaction 命中 / 未命中
- get_active 命中 / 未命中 / 多笔改生辰重购
- deactivate reason=refund 写 refunded_at / reason=revoke 写 revoked_at
- deactivate 幂等(同 tx 二次返 False)
"""

from __future__ import annotations

import pytest

from app.entitlement import EntitlementStore


@pytest.fixture
def store(tmp_path) -> EntitlementStore:
    """临时 EntitlementStore,init_schema 完成。"""
    s = EntitlementStore(str(tmp_path / "test_entitlement.db"))
    s.init_schema()
    return s


# ===== init_schema 幂等 =====


def test_init_schema_idempotent(tmp_path):
    """连续调两次 init_schema 不报错(幂等,对齐 ai/cache.py 行为)。"""
    s = EntitlementStore(str(tmp_path / "test_entitlement.db"))
    s.init_schema()
    s.init_schema()  # 不抛即通过


# ===== insert 幂等 =====


def test_insert_returns_true_for_new(store):
    """新 transaction_id 插入返回 True。"""
    ok = store.insert(
        transaction_id="tx-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    assert ok is True


def test_insert_returns_false_for_duplicate(store):
    """同 transaction_id 二次插入返回 False(INSERT OR IGNORE 幂等)。"""
    args = dict(
        transaction_id="tx-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    assert store.insert(**args) is True
    assert store.insert(**args) is False  # 幂等


# ===== get_by_transaction =====


def test_get_by_transaction_hit(store):
    """按 transaction_id 查命中,返回全字段 dict。"""
    store.insert(
        transaction_id="tx-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    row = store.get_by_transaction("tx-001")
    assert row is not None
    assert row["transaction_id"] == "tx-001"
    assert row["product_id"] == "com.qicompass.deep_analysis.single"
    assert row["content_hash"] == "hash-a"
    assert row["module"] == "bazi_deep"
    assert row["user_local_id"] == "user-1"
    assert row["is_active"] == 1
    assert row["refunded_at"] is None
    assert row["revoked_at"] is None


def test_get_by_transaction_miss(store):
    """未存在的 transaction_id 返回 None。"""
    assert store.get_by_transaction("nonexistent") is None


# ===== get_active =====


def test_get_active_hit(store):
    """有效 entitlement 命中(按 content_hash + module + user_local_id)。"""
    store.insert(
        transaction_id="tx-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    row = store.get_active(
        content_hash="hash-a", module="bazi_deep", user_local_id="user-1")
    assert row is not None
    assert row["transaction_id"] == "tx-001"


def test_get_active_miss_by_content_hash(store):
    """content_hash 不匹配 → None。"""
    store.insert(
        transaction_id="tx-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    row = store.get_active(
        content_hash="hash-other", module="bazi_deep", user_local_id="user-1")
    assert row is None


def test_get_active_miss_by_user(store):
    """user_local_id 不匹配 → None(防越权:用户的 entitlement 不能被另一用户查到)。"""
    store.insert(
        transaction_id="tx-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    row = store.get_active(
        content_hash="hash-a", module="bazi_deep", user_local_id="user-2")
    assert row is None


def test_get_active_returns_latest_when_multiple(store):
    """同 (content_hash, module, user) 多笔(改生辰重购)→ 取最近一笔。

    场景:用户改生辰 → content_hash 变 → 旧 entitlement 留着 → 新命盘再购。
    这里模拟同 content_hash 多笔(可能是 repurchase 或测试场景)。
    """
    # 第一笔(2026-07-18)
    store.insert(
        transaction_id="tx-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    # 第二笔(2026-07-19,更近)
    store.insert(
        transaction_id="tx-002",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-19T12:00:00+00:00",
        original_purchase_date="2026-07-19T11:55:00+00:00",
    )
    row = store.get_active(
        content_hash="hash-a", module="bazi_deep", user_local_id="user-1")
    assert row is not None
    assert row["transaction_id"] == "tx-002"  # 取最近


def test_get_active_skips_inactive(store):
    """is_active=0 的 entitlement 不应被 get_active 命中(退款/撤销后)。"""
    store.insert(
        transaction_id="tx-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    store.deactivate(
        transaction_id="tx-001", reason="refund",
        at_iso="2026-07-20T10:00:00+00:00")
    row = store.get_active(
        content_hash="hash-a", module="bazi_deep", user_local_id="user-1")
    assert row is None


# ===== deactivate =====


def test_deactivate_refund_sets_refunded_at(store):
    """reason=refund → is_active=0 + refunded_at 写入,revoked_at 仍 None。"""
    store.insert(
        transaction_id="tx-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    ok = store.deactivate(
        transaction_id="tx-001", reason="refund",
        at_iso="2026-07-20T10:00:00+00:00")
    assert ok is True
    row = store.get_by_transaction("tx-001")
    assert row["is_active"] == 0
    assert row["refunded_at"] == "2026-07-20T10:00:00+00:00"
    assert row["revoked_at"] is None


def test_deactivate_revoke_sets_revoked_at(store):
    """reason=revoke → is_active=0 + revoked_at 写入,refunded_at 仍 None。"""
    store.insert(
        transaction_id="tx-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    ok = store.deactivate(
        transaction_id="tx-001", reason="revoke",
        at_iso="2026-07-20T10:00:00+00:00")
    assert ok is True
    row = store.get_by_transaction("tx-001")
    assert row["is_active"] == 0
    assert row["revoked_at"] == "2026-07-20T10:00:00+00:00"
    assert row["refunded_at"] is None


def test_deactivate_idempotent(store):
    """同 tx 二次 deactivate 返回 False(WHERE is_active=1 不再命中)。"""
    store.insert(
        transaction_id="tx-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-a",
        module="bazi_deep",
        user_local_id="user-1",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    assert store.deactivate(
        transaction_id="tx-001", reason="refund",
        at_iso="2026-07-20T10:00:00+00:00") is True
    assert store.deactivate(
        transaction_id="tx-001", reason="refund",
        at_iso="2026-07-21T10:00:00+00:00") is False  # 幂等


def test_deactivate_nonexistent_returns_false(store):
    """deactivate 不存在的 tx → False(不抛,不创建空行)。"""
    ok = store.deactivate(
        transaction_id="nonexistent", reason="refund",
        at_iso="2026-07-20T10:00:00+00:00")
    assert ok is False


def test_deactivate_invalid_reason_raises(store):
    """reason 不在 {refund, revoke} → ValueError(防御编程,不静默接受)。"""
    with pytest.raises(ValueError, match="reason 必须是"):
        store.deactivate(
            transaction_id="tx-001", reason="invalid",
            at_iso="2026-07-20T10:00:00+00:00")
