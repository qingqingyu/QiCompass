"""auth/apple_signin.py 单元测试。

不真调 Apple /auth/keys,用 mock_apple_signin 生成本地 RSA 密钥对自签 identity_token,
注入 _get_jwks_client 让它返我们的公钥(避免网络依赖)。

验收用例:
- 正常 identity_token → 返 AppleUserInfo
- 缺 sub → AppleSignInInvalidTokenError
- 过期 → AppleSignInExpiredError
- aud 错 → AppleSignInAudienceError
- iss 错 → AppleSignInInvalidTokenError
- 非 JWT 字符串 → AppleSignInInvalidTokenError
- 空 token → AppleSignInInvalidTokenError
"""

from __future__ import annotations

from typing import Any
from unittest.mock import MagicMock, patch

import pytest

from app.auth.apple_signin import (
    AppleSignInAudienceError,
    AppleSignInExpiredError,
    AppleSignInInvalidTokenError,
    verify_apple_identity_token,
)
from tests.fixtures.mock_apple_signin import (
    generate_apple_identity_token,
    generate_mock_apple_keypair,
)


@pytest.fixture(scope="module")
def mock_keypair():
    """module 级共享一对 RSA 密钥(RSA 生成慢,避免每测试都生成)。"""
    return generate_mock_apple_keypair()


@pytest.fixture
def patched_jwks(monkeypatch, mock_keypair):
    """注入 mock PyJWKClient,返我们的 mock 公钥(不真拉 Apple)。"""
    from app.auth import apple_signin

    mock_signing_key = MagicMock()
    mock_signing_key.key = mock_keypair.public_key  # cryptography RSAPublicKey 对象

    mock_client = MagicMock()
    mock_client.get_signing_key_from_jwt.return_value = mock_signing_key

    # 直接替换 _get_jwks_client 返回 mock_client
    monkeypatch.setattr(apple_signin, "_get_jwks_client", lambda: mock_client)
    return mock_client


def test_verify_normal_token_returns_user_info(patched_jwks, mock_keypair):
    """正常 identity_token → AppleUserInfo(apple_user_id + email + email_verified)。"""
    token = generate_apple_identity_token(
        mock_keypair,
        apple_user_id="apple-user-123",
        email="user@example.com",
        email_verified=True,
    )
    info = verify_apple_identity_token(token, expected_audience="com.qicompass.app")
    assert info.apple_user_id == "apple-user-123"
    assert info.email == "user@example.com"
    assert info.email_verified is True


def test_verify_token_without_email(patched_jwks, mock_keypair):
    """email=None(后续登录,Apple 不返 email)。email_verified 取决于传参(默认 True)。"""
    token = generate_apple_identity_token(mock_keypair, email=None)
    info = verify_apple_identity_token(token)
    assert info.apple_user_id == "apple-user-test-001"
    assert info.email is None
    # email=None 不影响 email_verified(默认 True,mock generator 默认行为)
    assert info.email_verified is True


def test_verify_expired_token_raises_expired(patched_jwks, mock_keypair):
    """过期 token → AppleSignInExpiredError。"""
    token = generate_apple_identity_token(mock_keypair, expired=True)
    with pytest.raises(AppleSignInExpiredError, match="过期"):
        verify_apple_identity_token(token)


def test_verify_wrong_audience_raises_audience_error(patched_jwks, mock_keypair):
    """aud 不符 → AppleSignInAudienceError。"""
    token = generate_apple_identity_token(mock_keypair, wrong_audience=True)
    with pytest.raises(AppleSignInAudienceError, match="aud"):
        verify_apple_identity_token(token)


def test_verify_wrong_issuer_raises_invalid(patched_jwks, mock_keypair):
    """iss 不符 → AppleSignInInvalidTokenError。"""
    token = generate_apple_identity_token(mock_keypair, wrong_issuer=True)
    with pytest.raises(AppleSignInInvalidTokenError, match="iss"):
        verify_apple_identity_token(token)


def test_verify_malformed_token_raises_invalid(patched_jwks, mock_keypair):
    """非 JWT 字符串 → AppleSignInInvalidTokenError(显式抛,不静默)。"""
    # patched_jwks 内 get_signing_key_from_jwt 会被 PyJWKClient 解析失败抛错,
    # 我们的 except 捕获后抛 AppleSignInInvalidTokenError
    mock_client = patched_jwks
    mock_client.get_signing_key_from_jwt.side_effect = ValueError("malformed jwt")

    with pytest.raises(AppleSignInInvalidTokenError, match="无法解析"):
        verify_apple_identity_token("not.a.jwt")

    # 重置 side_effect 不污染后续测试
    mock_client.get_signing_key_from_jwt.side_effect = None


def test_verify_empty_token_raises_invalid(patched_jwks):
    """空 token → AppleSignInInvalidTokenError。"""
    with pytest.raises(AppleSignInInvalidTokenError, match="为空"):
        verify_apple_identity_token("")


def test_verify_token_missing_sub_raises_invalid(patched_jwks, mock_keypair):
    """payload 缺 sub → AppleSignInInvalidTokenError。

    构造方式:手动用 mock_keypair 签个缺 sub 的 token,verify 内 jwt.decode 通过后
    显式校验 sub 字段。
    """
    import time
    import jwt

    payload = {
        "iss": "https://appleid.apple.com",
        "aud": "com.qicompass.app",
        "iat": int(time.time()) - 100,
        "exp": int(time.time()) + 3600,
        "email": "test@example.com",
        # 故意缺 sub
    }
    token = jwt.encode(
        payload,
        mock_keypair.private_key_pem,
        algorithm="RS256",
        headers={"kid": mock_keypair.kid},
    )
    with pytest.raises(AppleSignInInvalidTokenError, match="sub"):
        verify_apple_identity_token(token)
