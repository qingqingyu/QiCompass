"""POST /api/entitlement/redeem + GET /api/entitlement/list 测试(M2b + Slice 1)。

全用 MockAppleServerAPI,不真调 Apple。覆盖:

redeem:
- 成功路径:redeem → 写表 + 返回 entitled=True(带 JWT)
- 幂等:同 tx 二次 redeem → 直接返回(不重复调 Apple)
- 已 inactive tx 重新 redeem → 403(已退款,不可激活)
- product_id 不匹配 → 502
- Apple 返回 is_refunded → 403
- Apple verify 抛错 → 502
- 字段校验:缺字段 / 空白 user_local_id → 422
- 调用 MockAppleServerAPI 计数验证幂等行为
- **强制 JWT**:未带 Authorization → 401(Slice 1 决策)

list(Slice 1 新增):
- 未带 JWT → 401
- 带 JWT → 返当前 user 的全部 entitlement
- 空 user → 返空列表
- 按 user_id 过滤(不返其他 user 的数据)
- entitlement.user_id 已写入(redeem 调用后验证)
"""

from __future__ import annotations

from datetime import datetime, timezone

import pytest

from app.entitlement import AppleTransactionInfo, MockAppleServerAPI
from app.main import app


# ---------- constants ----------

TEST_USER_ID = "test-user-id-001"
OTHER_USER_ID = "other-user-id-002"


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
def auth_headers() -> dict[str, str]:
    """返 {"Authorization": "Bearer <jwt>"},JWT sub=TEST_USER_ID。

    用 app.auth.jwt_service.create_access_token 生成真 JWT,跑完整验签链路。
    """
    from app.auth.jwt_service import create_access_token
    token = create_access_token(TEST_USER_ID)
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture
def other_user_auth_headers() -> dict[str, str]:
    """返另一用户的 Authorization header(sub=OTHER_USER_ID),用于测试 user_id 过滤。"""
    from app.auth.jwt_service import create_access_token
    token = create_access_token(OTHER_USER_ID)
    return {"Authorization": f"Bearer {token}"}


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


# ===== redeem:强制 JWT(Slice 1 新增)=====


async def test_redeem_without_jwt_returns_401(redeem_client):
    """未带 Authorization → 401(redeem 强制登录,对齐 Slice 1 决策)。"""
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload())
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "JWT_MALFORMED"


# ===== redeem:成功路径 =====


async def test_redeem_success_writes_and_returns(redeem_client, mock_apple,
                                                 tmp_entitlement_store,
                                                 auth_headers):
    """正常 redeem(带 JWT):Apple 验证通过 → 写表 → 返回 entitled=True + 时间戳。"""
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
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
    # Slice 1 强制登录:entitlement.user_id 必有值(= JWT sub)
    assert row["user_id"] == TEST_USER_ID

    # 验证调过 Apple(verify_transaction_calls 非空)
    assert len(mock_apple.verify_transaction_calls) == 1


# ===== redeem:幂等 =====


async def test_redeem_idempotent_returns_same_row(
    redeem_client, mock_apple, tmp_entitlement_store, auth_headers,
):
    """同 transaction_id 二次 redeem → 直接返回已存在的行,**不重复调 Apple**。"""
    # 第一次:miss → 调 Apple + 写表
    r1 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
    assert r1.status_code == 200
    first_purchased_at = r1.json()["purchased_at"]
    assert len(mock_apple.verify_transaction_calls) == 1

    # 第二次:hit → 不调 Apple,返回已存在的行
    r2 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
    assert r2.status_code == 200
    assert r2.json()["purchased_at"] == first_purchased_at  # 同一行
    assert len(mock_apple.verify_transaction_calls) == 1, "幂等命中不应再调 Apple"


async def test_redeem_inactive_tx_rejected(
    redeem_client, mock_apple, tmp_entitlement_store, auth_headers,
):
    """已退款/撤销的 tx 重新 redeem → 403(不能重新激活)。"""
    # 第一次成功
    r1 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
    assert r1.status_code == 200

    # 退款
    assert tmp_entitlement_store.deactivate(
        transaction_id="tx-001", reason="refund",
        at_iso="2026-07-20T10:00:00+00:00") is True

    # 二次 redeem → 403
    r2 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
    assert r2.status_code == 403
    assert r2.json()["error"]["code"] == "ENTITLEMENT_ERROR"
    # 不应再调 Apple(查表已 inactive 直接拒)
    assert len(mock_apple.verify_transaction_calls) == 1


# ===== redeem:幂等命中核对(2026-08-23 修复)=====


async def test_redeem_idempotent_hit_with_different_content_hash_rejected(
    redeem_client, mock_apple, tmp_entitlement_store, auth_headers,
):
    """幂等命中但请求换了 content_hash → 403(防他人 tx_id 换 hash
    骗 entitled=true + iOS 本地镜像污染)。"""
    r1 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
    assert r1.status_code == 200

    # 同 tx_id 换 content_hash 重放 → 403
    r2 = await redeem_client.post(
        "/api/entitlement/redeem",
        json=_redeem_payload(content_hash="hash-of-attacker"),
        headers=auth_headers,
    )
    assert r2.status_code == 403
    assert r2.json()["error"]["code"] == "ENTITLEMENT_ERROR"
    # 不应再调 Apple(幂等查表阶段已拒)
    assert len(mock_apple.verify_transaction_calls) == 1


async def test_redeem_idempotent_hit_with_different_module_rejected(
    redeem_client, mock_apple, tmp_entitlement_store, auth_headers,
):
    """幂等命中但请求换了 module → 403。"""
    r1 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
    assert r1.status_code == 200

    r2 = await redeem_client.post(
        "/api/entitlement/redeem",
        json=_redeem_payload(module="compatibility"),
        headers=auth_headers,
    )
    assert r2.status_code == 403


async def test_redeem_idempotent_hit_other_user_rejected(
    redeem_client, mock_apple, tmp_entitlement_store, auth_headers,
    other_user_auth_headers,
):
    """幂等命中但请求方不是交易所有者(user_id / user_local_id 均不匹配)
    → 403(防拿他人 tx_id 兑换)。"""
    r1 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
    assert r1.status_code == 200

    # 另一个登录用户拿同 tx_id(且 user_local_id 也换了)→ 403
    payload = _redeem_payload(user_local_id="user-attacker")
    r2 = await redeem_client.post(
        "/api/entitlement/redeem", json=payload,
        headers=other_user_auth_headers,
    )
    assert r2.status_code == 403


async def test_redeem_idempotent_hit_same_user_new_device_user_local_id_ok(
    redeem_client, mock_apple, tmp_entitlement_store, auth_headers,
):
    """幂等命中 + 同 user_id(JWT)但新设备 user_local_id → 200(跨设备
    重装场景合法:user 维度双轨,user_id 命中即认可)。"""
    r1 = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
    assert r1.status_code == 200

    payload = _redeem_payload(user_local_id="user-1-new-device")
    r2 = await redeem_client.post(
        "/api/entitlement/redeem", json=payload,
        headers=auth_headers,  # 同一 JWT user
    )
    assert r2.status_code == 200
    assert r2.json()["entitled"] is True


# ===== redeem:Apple 校验失败 =====


async def test_redeem_product_id_mismatch_returns_502(
    redeem_client, mock_apple, auth_headers,
):
    """Apple 返回的 product_id 与请求不匹配 → 502 AppleVerificationError。"""
    mock_apple._default_tx_info = AppleTransactionInfo(
        transaction_id="<mock>",
        product_id="com.qicompass.compatibility.single",  # 跟请求的 deep_analysis 不同
        original_purchase_date=datetime(2026, 7, 18, tzinfo=timezone.utc),
        is_refunded=False,
    )
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
    assert resp.status_code == 502
    assert resp.json()["error"]["code"] == "APPLE_VERIFICATION_ERROR"
    assert "product_id 不匹配" in resp.json()["error"]["message"]


async def test_redeem_apple_returns_refunded_returns_403(
    redeem_client, mock_apple, auth_headers,
):
    """Apple 返回 is_refunded=True → 403 EntitlementError(理论上 webhook 已处理)。"""
    mock_apple._default_tx_info = AppleTransactionInfo(
        transaction_id="<mock>",
        product_id="com.qicompass.deep_analysis.single",
        original_purchase_date=datetime(2026, 7, 18, tzinfo=timezone.utc),
        is_refunded=True,  # Apple 说已退款
    )
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
    assert resp.status_code == 403
    assert resp.json()["error"]["code"] == "ENTITLEMENT_ERROR"


async def test_redeem_apple_verify_fails_returns_502(
    redeem_client, mock_apple, auth_headers,
):
    """MockAppleServerAPI verify_fails=True → 模拟 Apple 网络故障 → 502。"""
    mock_apple._verify_fails = True
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=_redeem_payload(),
        headers=auth_headers,
    )
    assert resp.status_code == 502
    assert resp.json()["error"]["code"] == "APPLE_VERIFICATION_ERROR"


# ===== redeem:字段校验 =====


async def test_redeem_missing_field_returns_422(redeem_client, auth_headers):
    """缺必填字段 → 422 Pydantic 校验。"""
    payload = _redeem_payload()
    del payload["user_local_id"]
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=payload, headers=auth_headers)
    assert resp.status_code == 422


async def test_redeem_blank_user_local_id_returns_422(redeem_client, auth_headers):
    """user_local_id="   " → strip 后空 → 422。"""
    payload = _redeem_payload(user_local_id="   ")
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=payload, headers=auth_headers)
    assert resp.status_code == 422


async def test_redeem_invalid_product_id_returns_422(redeem_client, auth_headers):
    """product_id 不在 SKU 列表 → 422(Literal 校验)。"""
    payload = _redeem_payload(product_id="com.qicompass.invalid")
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=payload, headers=auth_headers)
    assert resp.status_code == 422


async def test_redeem_invalid_module_returns_422(redeem_client, auth_headers):
    """module 不在 {bazi_deep, compatibility} → 422。"""
    payload = _redeem_payload(module="bazi_deep_paid")  # _paid 不合法(要基础名)
    resp = await redeem_client.post(
        "/api/entitlement/redeem", json=payload, headers=auth_headers)
    assert resp.status_code == 422


# ===== list:Slice 1 新增 =====


async def test_list_without_jwt_returns_401(redeem_client):
    """未带 Authorization 调 list → 401(强制登录)。"""
    resp = await redeem_client.get("/api/entitlement/list")
    assert resp.status_code == 401
    assert resp.json()["error"]["code"] == "JWT_MALFORMED"


async def test_list_empty_for_new_user(redeem_client, auth_headers):
    """登录 user 无任何 entitlement → 返空列表(200,不是 404)。"""
    resp = await redeem_client.get(
        "/api/entitlement/list", headers=auth_headers)
    assert resp.status_code == 200, resp.json()
    body = resp.json()
    assert body["entitlements"] == []


async def test_list_returns_only_current_user_entitlements(
    redeem_client, tmp_entitlement_store, auth_headers, other_user_auth_headers,
):
    """list 按 user_id 严格过滤:只返当前 JWT user 的记录,不返其他 user 的。"""
    # Seed:TEST_USER 两条 active,OTHER_USER 一条 active
    tmp_entitlement_store.insert(
        transaction_id="tx-user-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-user-a",
        module="bazi_deep",
        user_local_id="local-user-1",
        user_id=TEST_USER_ID,
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    tmp_entitlement_store.insert(
        transaction_id="tx-user-002",
        product_id="com.qicompass.compatibility.single",
        content_hash="hash-user-b",
        module="compatibility",
        user_local_id="local-user-1",
        user_id=TEST_USER_ID,
        purchased_at="2026-07-19T12:00:00+00:00",
        original_purchase_date="2026-07-19T11:55:00+00:00",
    )
    tmp_entitlement_store.insert(
        transaction_id="tx-other-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-other-a",
        module="bazi_deep",
        user_local_id="local-other-1",
        user_id=OTHER_USER_ID,
        purchased_at="2026-07-20T12:00:00+00:00",
        original_purchase_date="2026-07-20T11:55:00+00:00",
    )

    # TEST_USER 调 list → 只看到自己的 2 条
    resp = await redeem_client.get(
        "/api/entitlement/list", headers=auth_headers)
    assert resp.status_code == 200, resp.json()
    body = resp.json()
    assert len(body["entitlements"]) == 2
    tx_ids = {e["transaction_id"] for e in body["entitlements"]}
    assert tx_ids == {"tx-user-001", "tx-user-002"}
    # 所有返回的记录 user_id 都匹配当前 JWT
    for e in body["entitlements"]:
        assert e["user_id"] == TEST_USER_ID
        assert e["is_active"] is True

    # OTHER_USER 调 list → 只看到自己的 1 条
    resp2 = await redeem_client.get(
        "/api/entitlement/list", headers=other_user_auth_headers)
    assert resp2.status_code == 200
    body2 = resp2.json()
    assert len(body2["entitlements"]) == 1
    assert body2["entitlements"][0]["transaction_id"] == "tx-other-001"


async def test_list_includes_inactive_records(
    redeem_client, tmp_entitlement_store, auth_headers,
):
    """list 包含 inactive 记录(客户端自行筛选,用于正确同步退款状态)。"""
    tmp_entitlement_store.insert(
        transaction_id="tx-active-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-1",
        module="bazi_deep",
        user_local_id="local-1",
        user_id=TEST_USER_ID,
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )
    tmp_entitlement_store.insert(
        transaction_id="tx-refunded-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-2",
        module="bazi_deep",
        user_local_id="local-1",
        user_id=TEST_USER_ID,
        purchased_at="2026-07-19T12:00:00+00:00",
        original_purchase_date="2026-07-19T11:55:00+00:00",
    )
    tmp_entitlement_store.deactivate(
        transaction_id="tx-refunded-001", reason="refund",
        at_iso="2026-07-20T10:00:00+00:00")

    resp = await redeem_client.get(
        "/api/entitlement/list", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["entitlements"]) == 2
    by_tx = {e["transaction_id"]: e for e in body["entitlements"]}
    assert by_tx["tx-active-001"]["is_active"] is True
    assert by_tx["tx-refunded-001"]["is_active"] is False
    assert by_tx["tx-refunded-001"]["refunded_at"] is not None
