"""Mock Sign in with Google id_token 生成器(测试用,照 mock_apple_signin.py 模式)。

不用真调 Google JWKS 端点(避免网络依赖 + 限流),用本地生成的 RSA 密钥对
自签 id_token,然后注入 google_signin._get_jwks_client 让它返我们的公钥。
"""

from __future__ import annotations

import base64
import time
from dataclasses import dataclass
from typing import Any

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa


@dataclass
class MockGoogleKeyPair:
    """测试用 RSA 密钥对(生成一次重复用,避免每个测试都生成)。"""

    private_key_pem: str  # PKCS8 PEM 编码私钥(给 jwt.encode)
    public_key: Any  # cryptography RSAPublicKey 对象(给 mock signing_key.key)
    public_jwk: dict[str, Any]  # JWKS 格式公钥(参考,实际 mock 用 public_key 对象)
    kid: str  # key id(写在 JWT header)


def generate_mock_google_keypair(kid: str = "mock-google-test-key-1") -> MockGoogleKeyPair:
    """生成一对 RSA 密钥给 Google id_token 自签测试用。"""
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_key = private_key.public_key()

    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("utf-8")

    # JWKS 格式(RFC 7517):Google 用 RSA + RS256,kid/alg/n/e 必填
    public_numbers = public_key.public_numbers()

    def _int_to_b64url(n: int) -> str:
        byte_len = (n.bit_length() + 7) // 8
        return base64.urlsafe_b64encode(n.to_bytes(byte_len, "big")).rstrip(b"=").decode("ascii")

    public_jwk = {
        "kty": "RSA",
        "kid": kid,
        "alg": "RS256",
        "use": "sig",
        "n": _int_to_b64url(public_numbers.n),
        "e": _int_to_b64url(public_numbers.e),
    }
    return MockGoogleKeyPair(
        private_key_pem=private_pem,
        public_key=public_key,
        public_jwk=public_jwk,
        kid=kid,
    )


def generate_google_identity_token(
    keypair: MockGoogleKeyPair,
    *,
    google_user_id: str = "google-user-test-001",
    email: str | None = "test@example.com",
    email_verified: bool = True,
    audience: str = "1234567890-test.apps.googleusercontent.com",
    issuer: str = "accounts.google.com",
    expired: bool = False,
    wrong_audience: bool = False,
    wrong_issuer: bool = False,
) -> str:
    """生成 mock id_token(供 verify_google_identity_token 测试用)。

    可控参数让测试构造各 case:
    - expired=True:iat 1 天前 + exp 1 小时前 → GoogleSignInExpiredError
    - wrong_audience=True:aud 设错的 → GoogleSignInAudienceError
    - wrong_issuer=True:iss 设错的 → GoogleSignInInvalidTokenError
    - issuer 两种合法值(带/不带 https 前缀)都能测
    """
    now = int(time.time())
    exp_offset = -3600 if expired else 3600
    payload = {
        "iss": "https://wrong.example.com" if wrong_issuer else issuer,
        "aud": "com.wrong.audience" if wrong_audience else audience,
        "sub": google_user_id,
        "iat": now - 86400,  # 1 天前签发
        "exp": now + exp_offset,
        "email": email,
        # Google 原生发 bool(与 Apple 的字符串 "true" 不同)
        "email_verified": email_verified,
    }
    return jwt.encode(
        payload,
        keypair.private_key_pem,
        algorithm="RS256",
        headers={"kid": keypair.kid},
    )
