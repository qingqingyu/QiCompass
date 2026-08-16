"""auth/google_signin.py 单元测试(照 test_apple_signin.py 模式)。

不真调 Google JWKS 端点,用 mock_google_signin 生成本地 RSA 密钥对自签 id_token,
注入 _get_jwks_client 让它返我们的公钥(避免网络依赖)。

验收用例:
- 正常 id_token → 返 GoogleUserInfo
- iss 合法第二格式(https://accounts.google.com)→ 也通过(双合法值手动校验)
- 缺 sub → GoogleSignInInvalidTokenError
- 过期 → GoogleSignInExpiredError
- aud 错 → GoogleSignInAudienceError
- iss 错 → GoogleSignInInvalidTokenError
- 非 JWT 字符串 → GoogleSignInInvalidTokenError
- 空 token → GoogleSignInInvalidTokenError
- expected_audience 未配置(None)→ GoogleSignInNotConfiguredError(503,服务端配置错)
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from app.auth.google_signin import (
    GoogleSignInAudienceError,
    GoogleSignInExpiredError,
    GoogleSignInInvalidTokenError,
    GoogleSignInNotConfiguredError,
    verify_google_identity_token,
)
from tests.fixtures.mock_google_signin import (
    generate_google_identity_token,
    generate_mock_google_keypair,
)

# 与 mock_google_signin.generate_google_identity_token 默认 aud 一致
_TEST_AUDIENCE = "1234567890-test.apps.googleusercontent.com"


@pytest.fixture(scope="module")
def mock_keypair():
    """module 级共享一对 RSA 密钥(RSA 生成慢,避免每测试都生成)。"""
    return generate_mock_google_keypair()


@pytest.fixture
def patched_jwks(monkeypatch, mock_keypair):
    """注入 mock PyJWKClient,返我们的 mock 公钥(不真拉 Google)。"""
    from app.auth import google_signin

    mock_signing_key = MagicMock()
    mock_signing_key.key = mock_keypair.public_key  # cryptography RSAPublicKey 对象

    mock_client = MagicMock()
    mock_client.get_signing_key_from_jwt.return_value = mock_signing_key

    # 直接替换 _get_jwks_client 返回 mock_client
    monkeypatch.setattr(google_signin, "_get_jwks_client", lambda: mock_client)
    return mock_client


def test_get_jwks_client_constructs_real_client_no_typename_error(monkeypatch):
    """回归:真调 _get_jwks_client()(不 mock)验证 PyJWKClient 构造参数名正确。

    背景:曾照抄了不存在于 PyJWT 的 lifespan_keys_cache_seconds 参数,构造即
    TypeError → 生产首次 Google 登录 500。全 mock _get_jwks_client 的测试
    抓不到(构造 PyJWKClient 不发网络请求,只有首次取 key 才拉 JWKS)。
    """
    from jwt import PyJWKClient

    from app.auth import google_signin

    # 还原模块级缓存全局态,避免真实 client 泄漏到其他测试
    monkeypatch.setattr(google_signin, "_jwks_client", None)
    monkeypatch.setattr(google_signin, "_jwks_client_created_at", 0.0)

    client = google_signin._get_jwks_client()
    assert isinstance(client, PyJWKClient)


def test_verify_normal_token_returns_user_info(patched_jwks, mock_keypair):
    """正常 id_token → GoogleUserInfo(google_user_id + email + email_verified)。"""
    token = generate_google_identity_token(
        mock_keypair,
        google_user_id="google-user-123",
        email="user@gmail.com",
        email_verified=True,
    )
    info = verify_google_identity_token(token, expected_audience=_TEST_AUDIENCE)
    assert info.google_user_id == "google-user-123"
    assert info.email == "user@gmail.com"
    assert info.email_verified is True


def test_verify_second_issuer_format_also_passes(patched_jwks, mock_keypair):
    """iss = "https://accounts.google.com"(带 https 前缀的合法第二格式)→ 通过。"""
    token = generate_google_identity_token(
        mock_keypair, issuer="https://accounts.google.com"
    )
    info = verify_google_identity_token(token, expected_audience=_TEST_AUDIENCE)
    assert info.google_user_id == "google-user-test-001"


def test_verify_token_without_email(patched_jwks, mock_keypair):
    """email=None(极端场景)→ email 为 None,email_verified 仍按 claim 取。"""
    token = generate_google_identity_token(mock_keypair, email=None)
    info = verify_google_identity_token(token, expected_audience=_TEST_AUDIENCE)
    assert info.google_user_id == "google-user-test-001"
    assert info.email is None


def test_verify_expired_token_raises_expired(patched_jwks, mock_keypair):
    """过期 token → GoogleSignInExpiredError。"""
    token = generate_google_identity_token(mock_keypair, expired=True)
    with pytest.raises(GoogleSignInExpiredError, match="过期"):
        verify_google_identity_token(token, expected_audience=_TEST_AUDIENCE)


def test_verify_wrong_audience_raises_audience_error(patched_jwks, mock_keypair):
    """aud 不符 → GoogleSignInAudienceError。"""
    token = generate_google_identity_token(mock_keypair, wrong_audience=True)
    with pytest.raises(GoogleSignInAudienceError, match="aud"):
        verify_google_identity_token(token, expected_audience=_TEST_AUDIENCE)


def test_verify_wrong_issuer_raises_invalid(patched_jwks, mock_keypair):
    """iss 不在两个合法值里 → GoogleSignInInvalidTokenError(手动 iss 校验)。"""
    token = generate_google_identity_token(mock_keypair, wrong_issuer=True)
    with pytest.raises(GoogleSignInInvalidTokenError, match="iss"):
        verify_google_identity_token(token, expected_audience=_TEST_AUDIENCE)


def test_verify_malformed_token_raises_invalid(patched_jwks):
    """非 JWT 字符串 → GoogleSignInInvalidTokenError(显式抛,不静默)。"""
    mock_client = patched_jwks
    mock_client.get_signing_key_from_jwt.side_effect = ValueError("malformed jwt")

    with pytest.raises(GoogleSignInInvalidTokenError, match="无法解析"):
        verify_google_identity_token("not.a.jwt", expected_audience=_TEST_AUDIENCE)

    # 重置 side_effect 不污染后续测试
    mock_client.get_signing_key_from_jwt.side_effect = None


def test_verify_empty_token_raises_invalid(patched_jwks):
    """空 token → GoogleSignInInvalidTokenError。"""
    with pytest.raises(GoogleSignInInvalidTokenError, match="为空"):
        verify_google_identity_token("", expected_audience=_TEST_AUDIENCE)


def test_verify_token_missing_sub_raises_invalid(patched_jwks, mock_keypair):
    """payload 缺 sub → GoogleSignInInvalidTokenError。"""
    import time
    import jwt

    payload = {
        "iss": "accounts.google.com",
        "aud": _TEST_AUDIENCE,
        "iat": int(time.time()) - 100,
        "exp": int(time.time()) + 3600,
        "email": "test@gmail.com",
        # 故意缺 sub
    }
    token = jwt.encode(
        payload,
        mock_keypair.private_key_pem,
        algorithm="RS256",
        headers={"kid": mock_keypair.kid},
    )
    with pytest.raises(GoogleSignInInvalidTokenError, match="sub"):
        verify_google_identity_token(token, expected_audience=_TEST_AUDIENCE)


def test_verify_token_missing_exp_claim_raises_invalid(patched_jwks, mock_keypair):
    """payload 缺 exp claim(options require exp 防御纵深)→ InvalidTokenError。"""
    import time
    import jwt

    payload = {
        "iss": "accounts.google.com",
        "aud": _TEST_AUDIENCE,
        "sub": "google-user-no-exp",
        "iat": int(time.time()) - 100,
        # 故意缺 exp:无过期时间的 token 必须拒收
    }
    token = jwt.encode(
        payload,
        mock_keypair.private_key_pem,
        algorithm="RS256",
        headers={"kid": mock_keypair.kid},
    )
    with pytest.raises(GoogleSignInInvalidTokenError, match="验签失败"):
        verify_google_identity_token(token, expected_audience=_TEST_AUDIENCE)


def test_verify_without_configured_audience_raises_not_configured():
    """expected_audience 为 None(服务端未配置 GOOGLE_SIGN_IN_CLIENT_ID)
    → GoogleSignInNotConfiguredError(503),不是客户端 401。"""
    with pytest.raises(GoogleSignInNotConfiguredError, match="未配置"):
        verify_google_identity_token("fake-token", expected_audience=None)
