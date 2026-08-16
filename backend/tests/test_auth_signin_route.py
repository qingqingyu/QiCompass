"""POST /api/auth/sign-in 路由测试(Slice 1 新增,聚焦 backfill 行为)。

不真调 Apple /auth/keys:monkeypatch verify_apple_identity_token 直接返 mock AppleUserInfo。
用 tmp_path 真 SQLite 隔离 user_store + entitlement_store,验证端到端 backfill。

覆盖:
- sign-in 不带 user_local_id → 不触发 backfill(向后兼容)
- sign-in 带 user_local_id 且无老数据 → backfill 返 0,登录成功
- sign-in 带 user_local_id 且有 user_id=NULL 的老 entitlement → backfill 补上 user_id
- backfill 失败不阻断登录(降级:返回正常 SignInResponse + 日志记错)
"""

from __future__ import annotations

import pytest

from app.main import app


# ---------- fixtures ----------


@pytest.fixture
def tmp_user_store(tmp_path):
    """临时 UserStore(独立 SQLite 文件,测完即弃)。"""
    from app.auth.user_store import UserStore
    store = UserStore(str(tmp_path / "test_signin_user.db"))
    store.init_schema()
    return store


@pytest.fixture
async def signin_client(tmp_user_store, tmp_entitlement_store):
    """TestClient + 替换 app.state.user_store + entitlement_store。

    verify_apple_identity_token 由单个测试 monkeypatch(不同测试用不同 apple_user_id)。
    """
    from httpx import ASGITransport, AsyncClient

    saved_user_store = getattr(app.state, "user_store", None)
    saved_entitlement = getattr(app.state, "entitlement_store", None)

    app.state.user_store = tmp_user_store
    app.state.entitlement_store = tmp_entitlement_store

    try:
        async with AsyncClient(transport=ASGITransport(app=app),
                               base_url="http://test") as ac:
            yield ac
    finally:
        app.state.user_store = saved_user_store
        app.state.entitlement_store = saved_entitlement


def _patch_apple_verify(monkeypatch, *, apple_user_id: str = "apple-sub-001"):
    """让 verify_apple_identity_token 返 mock AppleUserInfo,跳过真 Apple 验签。

    patch 目标是 `app.api.auth` 模块里的 `verify_apple_identity_token` 引用
    (auth.py 顶部 `from ..auth.apple_signin import verify_apple_identity_token`
    把符号 bind 到本模块;patch apple_signin 原模块不生效)。
    """
    from app.auth.apple_signin import AppleUserInfo
    import app.api.auth as auth_api_module

    def _fake_verify(token: str, expected_audience: str | None = None) -> AppleUserInfo:
        return AppleUserInfo(
            apple_user_id=apple_user_id,
            email="user@example.com",
            email_verified=True,
        )

    monkeypatch.setattr(auth_api_module, "verify_apple_identity_token", _fake_verify)


def _patch_google_verify(monkeypatch, *, google_user_id: str = "google-sub-001"):
    """让 verify_google_identity_token 返 mock GoogleUserInfo(同 _patch_apple_verify 模式)。"""
    from app.auth.google_signin import GoogleUserInfo
    import app.api.auth as auth_api_module

    def _fake_verify(token: str, expected_audience: str | None = None) -> GoogleUserInfo:
        return GoogleUserInfo(
            google_user_id=google_user_id,
            email="user@gmail.com",
            email_verified=True,
        )

    monkeypatch.setattr(auth_api_module, "verify_google_identity_token", _fake_verify)


# ===== 不带 user_local_id:向后兼容 =====


async def test_signin_without_user_local_id_skips_backfill(
    signin_client, tmp_entitlement_store, monkeypatch,
):
    """sign-in 不带 user_local_id → 不 backfill(老 iOS 客户端兼容)。"""
    _patch_apple_verify(monkeypatch)

    resp = await signin_client.post(
        "/api/auth/sign-in",
        json={"identity_token": "fake-token"},
    )
    assert resp.status_code == 200, resp.json()
    body = resp.json()
    assert "access_token" in body
    assert "user_id" in body
    assert "expires_at" in body


# ===== 带 user_local_id 但无老数据 =====


async def test_signin_with_user_local_id_no_legacy_backfills_zero(
    signin_client, tmp_entitlement_store, monkeypatch,
):
    """sign-in 带 user_local_id,但该 UUID 下无老 entitlement → backfill 返 0,登录成功。"""
    _patch_apple_verify(monkeypatch)

    resp = await signin_client.post(
        "/api/auth/sign-in",
        json={"identity_token": "fake-token", "user_local_id": "user-local-001"},
    )
    assert resp.status_code == 200, resp.json()
    # 没老数据,但流程正常走完
    assert resp.json()["user_id"]


# ===== 带 user_local_id 且有老数据 → 真 backfill =====


async def test_signin_backfills_legacy_entitlements(
    signin_client, tmp_entitlement_store, monkeypatch,
):
    """核心场景:用户匿名时期买过 → 登录时 backfill,entitlement.user_id 从 NULL 补上。"""
    _patch_apple_verify(monkeypatch, apple_user_id="apple-sub-backfill-001")

    # Seed:匿名时期的购买(user_id=None)
    tmp_entitlement_store.insert(
        transaction_id="tx-legacy-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-legacy-a",
        module="bazi_deep",
        user_local_id="user-local-legacy",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
        # user_id 不传 → None
    )

    # 登录 + 带 user_local_id
    resp = await signin_client.post(
        "/api/auth/sign-in",
        json={
            "identity_token": "fake-token",
            "user_local_id": "user-local-legacy",
        },
    )
    assert resp.status_code == 200, resp.json()
    backend_user_id = resp.json()["user_id"]

    # 验证 backfill:老 entitlement.user_id 已从 NULL 补成 backend_user_id
    row = tmp_entitlement_store.get_by_transaction("tx-legacy-001")
    assert row is not None
    assert row["user_id"] == backend_user_id

    # 验证 now list_by_user_id 能查到这条(以前查不到,因为 user_id 是 NULL)
    user_rows = tmp_entitlement_store.list_by_user_id(backend_user_id)
    assert len(user_rows) == 1
    assert user_rows[0]["transaction_id"] == "tx-legacy-001"


async def test_signin_backfill_idempotent_second_login_no_change(
    signin_client, tmp_entitlement_store, monkeypatch, tmp_user_store,
):
    """同用户第二次登录 → backfill 不覆盖已有 user_id(WHERE user_id IS NULL)。"""
    _patch_apple_verify(monkeypatch, apple_user_id="apple-sub-idem-001")

    # Seed:匿名购买
    tmp_entitlement_store.insert(
        transaction_id="tx-idem-001",
        product_id="com.qicompass.deep_analysis.single",
        content_hash="hash-idem-a",
        module="bazi_deep",
        user_local_id="user-local-idem",
        purchased_at="2026-07-18T12:00:00+00:00",
        original_purchase_date="2026-07-18T11:55:00+00:00",
    )

    # 第一次登录 → backfill 把 user_id 补上
    r1 = await signin_client.post(
        "/api/auth/sign-in",
        json={"identity_token": "fake", "user_local_id": "user-local-idem"},
    )
    assert r1.status_code == 200
    user_id_1 = r1.json()["user_id"]

    # 第二次登录(同 apple_user_id)→ backfill 不动已有 user_id
    r2 = await signin_client.post(
        "/api/auth/sign-in",
        json={"identity_token": "fake", "user_local_id": "user-local-idem"},
    )
    assert r2.status_code == 200
    user_id_2 = r2.json()["user_id"]

    # 同 apple_user_id → 同 backend user_id(upsert_by_apple_user_id)
    assert user_id_1 == user_id_2

    # entitlement 表 user_id 依然是 backend user_id(没被覆盖)
    row = tmp_entitlement_store.get_by_transaction("tx-idem-001")
    assert row["user_id"] == user_id_1


# ===== provider 字段(Apple / Google 双登录,2026-08-16 起)=====


async def test_signin_explicit_apple_provider_backward_compatible(
    signin_client, tmp_entitlement_store, monkeypatch,
):
    """provider="apple" 显式传 → 与不传(默认)行为一致,向后兼容。"""
    _patch_apple_verify(monkeypatch, apple_user_id="apple-sub-explicit-001")

    resp = await signin_client.post(
        "/api/auth/sign-in",
        json={"identity_token": "fake-token", "provider": "apple"},
    )
    assert resp.status_code == 200, resp.json()
    assert resp.json()["user_id"]


async def test_signin_google_provider_returns_200(
    signin_client, tmp_entitlement_store, monkeypatch,
):
    """provider="google" → 验签 mock 通过 → 200 + 自家 JWT;二次登录同 user_id。"""
    _patch_google_verify(monkeypatch, google_user_id="google-sub-route-001")

    r1 = await signin_client.post(
        "/api/auth/sign-in",
        json={"identity_token": "fake-google-token", "provider": "google"},
    )
    assert r1.status_code == 200, r1.json()
    body1 = r1.json()
    assert "access_token" in body1 and body1["user_id"]

    # 同 google sub 二次登录 → upsert 命中同一账号
    r2 = await signin_client.post(
        "/api/auth/sign-in",
        json={"identity_token": "fake-google-token", "provider": "google"},
    )
    assert r2.status_code == 200
    assert r2.json()["user_id"] == body1["user_id"]


async def test_signin_same_sub_different_provider_separate_accounts(
    signin_client, tmp_entitlement_store, monkeypatch,
):
    """同一 sub 值在 apple / google 两个 provider → 两个独立账号(v1 账号隔离决策)。"""
    shared_sub = "shared-sub-xyz"
    _patch_apple_verify(monkeypatch, apple_user_id=shared_sub)
    _patch_google_verify(monkeypatch, google_user_id=shared_sub)

    r_apple = await signin_client.post(
        "/api/auth/sign-in",
        json={"identity_token": "fake", "provider": "apple"},
    )
    r_google = await signin_client.post(
        "/api/auth/sign-in",
        json={"identity_token": "fake", "provider": "google"},
    )
    assert r_apple.status_code == 200
    assert r_google.status_code == 200
    assert r_apple.json()["user_id"] != r_google.json()["user_id"]


async def test_signin_google_not_configured_returns_503(
    signin_client, tmp_entitlement_store, monkeypatch,
):
    """provider=google 但 GOOGLE_SIGN_IN_CLIENT_ID 未配置 → 503 显式报错(不静默)。

    不 patch verify:让真 verify_google_identity_token 收到 expected_audience=None
    抛 GoogleSignInNotConfiguredError(BaziError handler → 503)。
    """
    import app.api.auth as auth_api_module

    monkeypatch.setattr(auth_api_module, "GOOGLE_SIGN_IN_CLIENT_ID", None)

    resp = await signin_client.post(
        "/api/auth/sign-in",
        json={"identity_token": "fake-token", "provider": "google"},
    )
    assert resp.status_code == 503, resp.json()
    assert "GOOGLE_SIGN_IN_NOT_CONFIGURED" in resp.text
