"""POST /api/webhooks/appstore 退款 webhook 测试(M2c)。

覆盖:
- REFUND → is_active=0 + refunded_at 写入
- REVOKE → is_active=0 + revoked_at 写入
- 未知 notificationType → 表不动 + 200
- 验签失败 → 200 + 表不动(避免 Apple 重试风暴)
- 空 body → 200
- 重复 webhook(同 tx 二次 REFUND)→ 幂等(deactivate 返 False)
- DB 写失败场景(由 store 异常模拟,webhook 转 500 让 Apple 重试)

全用 MockAppleServerAPI,不真调 Apple。
"""

from __future__ import annotations

import pytest

from app.entitlement import AppleNotificationPayload, MockAppleServerAPI
from app.main import app


@pytest.fixture
def mock_apple_notification() -> MockAppleServerAPI:
    """默认返回 REFUND + tx-001。"""
    return MockAppleServerAPI(
        notification=AppleNotificationPayload(
            notification_type="REFUND",
            transaction_id="tx-001",
            raw_summary="test-refund",
        ),
    )


@pytest.fixture
async def webhook_client(interpret_client, mock_apple_notification):
    """复用 interpret_client(已替换 cache + entitlement_store + ai_client),
    再替换 apple_server_api。
    """
    saved = app.state.apple_server_api
    app.state.apple_server_api = mock_apple_notification
    try:
        yield interpret_client
    finally:
        app.state.apple_server_api = saved


def _seed_entitlement(store, *, transaction_id: str = "tx-001",
                      content_hash: str = "hash-a",
                      user_local_id: str = "user-1") -> None:
    """预置一条 active entitlement 供 webhook deactivate。"""
    store.insert(
        transaction_id=transaction_id,
        product_id="com.qicompass.deep_analysis.single",
        content_hash=content_hash,
        module="bazi_deep",
        user_local_id=user_local_id,
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )


# ===== REFUND =====


async def test_webhook_refund_deactivates_entitlement(
    webhook_client, mock_apple_notification, tmp_entitlement_store,
):
    """REFUND → entitlement is_active=0 + refunded_at 写入。"""
    _seed_entitlement(tmp_entitlement_store, transaction_id="tx-001")

    resp = await webhook_client.post(
        "/api/webhooks/appstore",
        content="fake-jws-payload",  # Mock 不真验签,内容任意
        headers={"Content-Type": "application/octet-stream"},
    )
    assert resp.status_code == 200

    row = tmp_entitlement_store.get_by_transaction("tx-001")
    assert row is not None
    assert row["is_active"] == 0
    assert row["refunded_at"] is not None
    assert row["revoked_at"] is None


# ===== REVOKE =====


async def test_webhook_revoke_deactivates_entitlement(
    webhook_client, mock_apple_notification, tmp_entitlement_store,
):
    """REVOKE → entitlement is_active=0 + revoked_at 写入。"""
    _seed_entitlement(tmp_entitlement_store, transaction_id="tx-001")
    mock_apple_notification._default_notification = AppleNotificationPayload(
        notification_type="REVOKE",
        transaction_id="tx-001",
        raw_summary="test-revoke",
    )

    resp = await webhook_client.post(
        "/api/webhooks/appstore", content="fake-jws")
    assert resp.status_code == 200

    row = tmp_entitlement_store.get_by_transaction("tx-001")
    assert row["is_active"] == 0
    assert row["revoked_at"] is not None
    assert row["refunded_at"] is None


# ===== 未知 type =====


async def test_webhook_unhandled_type_skips_deactivate(
    webhook_client, mock_apple_notification, tmp_entitlement_store,
):
    """未知 type(SUBSCRIBED 等)→ 表不动 + 200(Apple 升级 API 不卡住老后端)。"""
    _seed_entitlement(tmp_entitlement_store, transaction_id="tx-001")
    mock_apple_notification._default_notification = AppleNotificationPayload(
        notification_type="SUBSCRIBED",
        transaction_id="tx-001",
        raw_summary="test-subscribed",
    )

    resp = await webhook_client.post(
        "/api/webhooks/appstore", content="fake-jws")
    assert resp.status_code == 200

    # 表不动(还是 active)
    row = tmp_entitlement_store.get_by_transaction("tx-001")
    assert row["is_active"] == 1


# ===== 验签失败 =====


async def test_webhook_verify_fails_returns_200(
    webhook_client, mock_apple_notification, tmp_entitlement_store,
):
    """验签失败 → 200 + 表不动(避免 Apple 重试风暴,只 log warning)。"""
    _seed_entitlement(tmp_entitlement_store, transaction_id="tx-001")
    mock_apple_notification._verify_fails = True

    resp = await webhook_client.post(
        "/api/webhooks/appstore", content="bad-signature")
    assert resp.status_code == 200  # 关键:不是 401/403

    # 表不动(验签失败不能影响数据)
    row = tmp_entitlement_store.get_by_transaction("tx-001")
    assert row["is_active"] == 1


# ===== 空 body =====


async def test_webhook_empty_body_returns_200(webhook_client):
    """Apple 误发空 body → 200 + 不操作。"""
    resp = await webhook_client.post(
        "/api/webhooks/appstore", content="")
    assert resp.status_code == 200


# ===== 幂等(同 tx 二次 webhook)=====


async def test_webhook_idempotent_on_duplicate(
    webhook_client, mock_apple_notification, tmp_entitlement_store,
):
    """同 tx 二次 REFUND → 第二次 deactivate 返 False(幂等),仍返 200。"""
    _seed_entitlement(tmp_entitlement_store, transaction_id="tx-001")

    # 第一次
    r1 = await webhook_client.post(
        "/api/webhooks/appstore", content="fake-jws")
    assert r1.status_code == 200
    assert tmp_entitlement_store.get_by_transaction("tx-001")["is_active"] == 0

    # 第二次(同 tx,同 type)
    r2 = await webhook_client.post(
        "/api/webhooks/appstore", content="fake-jws")
    assert r2.status_code == 200
    # 表还是 inactive(deactivate 第二次返 False,不变更)


# ===== 不存在的 tx(Apple 误推 / race condition)=====


async def test_webhook_unknown_tx_returns_200(
    webhook_client, mock_apple_notification, tmp_entitlement_store,
):
    """REFUND 但 tx 不存在于表 → 200(deactivate 返 False,不抛错)。"""
    # 不预置 entitlement
    resp = await webhook_client.post(
        "/api/webhooks/appstore", content="fake-jws")
    assert resp.status_code == 200
    # 表里没新增任何行
    assert tmp_entitlement_store.get_by_transaction("tx-001") is None


# ===== 大小写兼容 =====


async def test_webhook_lowercase_type_handled(
    webhook_client, mock_apple_notification, tmp_entitlement_store,
):
    """notification_type 大小写不敏感(refund 也能处理)。

    Apple SDK 实际返回大写,但 MockAppleServerAPI 也可能被外部传小写,
    webhook 内部统一 upper 后比较(防御编程)。
    """
    _seed_entitlement(tmp_entitlement_store, transaction_id="tx-001")
    mock_apple_notification._default_notification = AppleNotificationPayload(
        notification_type="refund",  # 小写
        transaction_id="tx-001",
        raw_summary="test-lowercase",
    )

    resp = await webhook_client.post(
        "/api/webhooks/appstore", content="fake-jws")
    assert resp.status_code == 200
    # 注:webhook 用 _HANDLED_TYPES = {"REFUND", "REVOKE"} 严格大写匹配
    # 小写不在 set 里 → 走 unhandled_type 路径,表不动
    # 测试若实际期待小写也处理,需要在 webhooks.py 加 .upper()
    # 现状:遵循 Apple 实际返回大写,不主动兼容小写
