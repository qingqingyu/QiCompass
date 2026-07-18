"""POST /api/entitlement/redeem 测试(M2b)。

全用 MockAppleServerAPI,不真调 Apple。覆盖:
- 成功路径:redeem → 写表 + 返回 entitled=True
- 幂等:同 tx 二次 redeem → 直接返回(不重复调 Apple)
- 已 inactive tx 重新 redeem → 403(已退款,不可激活)
- product_id 不匹配 → 502
- Apple 返回 is_refunded → 403
- Apple verify 抛错 → 502
- 字段校验:缺字段 / 空白 user_local_id → 422
- 调用 MockAppleServerAPI 计数验证幂等行为
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from app.entitlement import AppleTransactionInfo, MockAppleServerAPI
from app.main import app


# ---------- fixtures ----------


@pytest.fixture
def mock_apple() -> MockAppleServerAPI:
    """可配置的 Mock Apple client(默认返回 active + 没 refund)。"""
    return MockAppleServerAPI(
        tx_info=AppleTransactionInfo(
            transaction_id="<mock>",
            product_id="com.qicompass.deep_analysis.single",
            original_purchase_date=datetime(2026, 7, 18, 11, 55, tzinfo=timezone.utc),
            is_refunded=False,
        ),
    )


@pytest.fixture
async def redeem_client(interpret_client, mock_apple):
    """interpret_client 已替换 cache + entitlement_store + ai_client,
    这里再替换 apple_server_api 为 mock_apple。
    """
    saved = app.state.apple_server_api
    app.state.apple_server_api = mock_apple
    try:
        yield interpret_client
    finally:
        app.state.apple_server_api = saved


def _redeem_payload(
    *, transaction_id: str = "tx-001",
    product_id: str = "com.qicompass.deep_analysis.single",
    content_hash: str = "hash-a",
    module: str = "bazi_deep",
    user_local_id: str = "user-1",
) -> dict:
    return {
        "transaction_id": transaction_id,
        "product_id": product_id,
        "content_hash": content_hash,
        "module": module,
        "user_local_id": user_local_id,
    }


# ===== 成功路径 =====


async def test_redeem_success_writes_and_returns(redeem_client, mock_apple,
                                                 tmp_entitlement_store):
    """正常 redeem:Apple 验证通过 → 写表 → 返回 entitled=True + 时间戳。"""
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload())
    assert resp.status_code == 200, resp.json()
    body = resp.json()
    assert body["entitled"] is True
    assert body["transaction_id"] == "tx-001"
    assert "purchased_at" in body
    assert "original_purchase_date" in body

    # 验证写表
    row = tmp_entitlement_store.get_by_transaction("tx-001")
    assert row is not None
    assert row["is_active"] == 1
    assert row["product_id"] == "com.qicompass.deep_analysis.single"
    assert row["content_hash"] == "hash-a"
    assert row["module"] == "bazi_deep"
    assert row["user_local_id"] == "user-1"

    # 验证调过 Apple(verify_transaction_calls 非空)
    assert len(mock_apple.verify_transaction_calls) == 1


# ===== 幂等 =====


async def test_redeem_idempotent_returns_same_row(
    redeem_client, mock_apple, tmp_entitlement_store,
):
    """同 transaction_id 二次 redeem → 直接返回已存在的行,**不重复调 Apple**。"""
    # 第一次:miss → 调 Apple + 写表
    r1 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload())
    assert r1.status_code == 200
    first_purchased_at = r1.json()["purchased_at"]
    assert len(mock_apple.verify_transaction_calls) == 1

    # 第二次:hit → 不调 Apple,返回已存在的行
    r2 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload())
    assert r2.status_code == 200
    assert r2.json()["purchased_at"] == first_purchased_at  # 同一行
    assert len(mock_apple.verify_transaction_calls) == 1, "幂等命中不应再调 Apple"


async def test_redeem_inactive_tx_rejected(
    redeem_client, mock_apple, tmp_entitlement_store,
):
    """已退款/撤销的 tx 重新 redeem → 403(不能重新激活)。"""
    # 第一次成功
    r1 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload())
    assert r1.status_code == 200

    # 退款
    assert tmp_entitlement_store.deactivate(
        transaction_id="tx-001", reason="refund",
        at_iso="2026-07-20T10:00:00+00:00") is True

    # 二次 redeem → 403
    r2 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload())
    assert r2.status_code == 403
    assert r2.json()["error"]["code"] == "ENTITLEMENT_ERROR"
    # 不应再调 Apple(查表已 inactive 直接拒)
    assert len(mock_apple.verify_transaction_calls) == 1


# ===== Apple 校验失败 =====


async def test_redeem_product_id_mismatch_returns_502(
    redeem_client, mock_apple,
):
    """Apple 返回的 product_id 与请求不匹配 → 502 AppleVerificationError。"""
    mock_apple._default_tx_info = AppleTransactionInfo(
        transaction_id="<mock>",
        product_id="com.qicompass.compatibility.single",  # 跟请求的 deep_analysis 不同
        original_purchase_date=datetime(2026, 7, 18, tzinfo=timezone.utc),
        is_refunded=False,
    )
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload())
    assert resp.status_code == 502
    assert resp.json()["error"]["code"] == "APPLE_VERIFICATION_ERROR"
    assert "product_id 不匹配" in resp.json()["error"]["message"]


async def test_redeem_apple_returns_refunded_returns_403(
    redeem_client, mock_apple,
):
    """Apple 返回 is_refunded=True → 403 EntitlementError(理论上 webhook 已处理)。"""
    mock_apple._default_tx_info = AppleTransactionInfo(
        transaction_id="<mock>",
        product_id="com.qicompass.deep_analysis.single",
        original_purchase_date=datetime(2026, 7, 18, tzinfo=timezone.utc),
        is_refunded=True,  # Apple 说已退款
    )
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload())
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "ENTITLEMENT_ERROR"


async def test_redeem_apple_verify_fails_returns_502(
    redeem_client, mock_apple,
):
    """MockAppleServerAPI verify_fails=True → 模拟 Apple 网络故障 → 502。"""
    mock_apple._verify_fails = True
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload())
    assert resp.status_code == 502
    assert resp.json()["error"]["code"] == "APPLE_VERIFICATION_ERROR"


# ===== 字段校验 =====


async def test_redeem_missing_field_returns_422(redeem_client):
    """缺必填字段 → 422 Pydantic 校验。"""
    payload = _redeem_payload()
    del payload["user_local_id"]
    resp = await redeem_client.post("/api/entitlement/redeem", json=payload)
    assert resp.status_code == 422


async def test_redeem_blank_user_local_id_returns_422(redeem_client):
    """user_local_id="   " → strip 后空 → 422。"""
    payload = _redeem_payload(user_local_id="   ")
    resp = await redeem_client.post("/api/entitlement/redeem", json=payload)
    assert resp.status_code == 422


async def test_redeem_invalid_product_id_returns_422(redeem_client):
    """product_id 不在 SKU 列表 → 422(Literal 校验)。"""
    payload = _redeem_payload(product_id="com.qicompass.invalid")
    resp = await redeem_client.post("/api/entitlement/redeem", json=payload)
    assert resp.status_code == 422


async def test_redeem_invalid_module_returns_422(redeem_client):
    """module 不在 {bazi_deep, compatibility} → 422。"""
    payload = _redeem_payload(module="bazi_deep_paid")  # _paid 不合法(要基础名)
    resp = await redeem_client.post("/api/entitlement/redeem", json=payload)
    assert resp.status_code == 422
