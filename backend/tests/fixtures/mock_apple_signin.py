"""Mock Sign in with Apple identity_token 生成器(测试用)。

不用真调 Apple /auth/keys(避免网络依赖 + 限流),用本地生成的 RSA 密钥对
自签 identity_token,然后注入 apple_signin._get_jwks_client 让它返我们的公钥。
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa


@dataclass
class MockAppleKeyPair:
    """测试用 RSA 密钥对(生成一次重复用,避免每个测试都生成)。"""

    private_key_pem: str  # PKCS8 PEM 编码私钥(给 jwt.encode)
    public_key: Any  # cryptography RSAPublicKey 对象(给 mock signing_key.key)
    public_jwk: dict[str, Any]  # JWKS 格式公钥(参考,实际 mock 用 public_key 对象)
    kid: str  # key id(写在 JWT header)


def generate_mock_apple_keypair(kid: str = "mock-apple-test-key-1") -> MockAppleKeyPair:
    """生成一对 RSA 密钥给 Apple identity_token 自签测试用。"""
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public_key = private_key.public_key()

    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ).decode("utf-8")

    # JWKS 格式(RFC 7517):Apple 用 RSA + RS256,kid/alg/n/e 必填
    public_numbers = public_key.public_numbers()
    import base64

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
    return MockAppleKeyPair(
        private_key_pem=private_pem,
        public_key=public_key,  # cryptography RSAPublicKey 对象
        public_jwk=public_jwk,
        kid=kid,
    )


def generate_apple_identity_token(
    keypair: MockAppleKeyPair,
    *,
    apple_user_id: str = "apple-user-test-001",
    email: str | None = "test@example.com",
    email_verified: bool = True,
    audience: str = "com.qicompass.app",
    issuer: str = "https://appleid.apple.com",
    expired: bool = False,
    wrong_audience: bool = False,
    wrong_issuer: bool = False,
) -> str:
    """生成 mock identity_token(供 verify_apple_identity_token 测试用)。

    可控参数让测试构造各 case:
    - expired=True:iat 1 天前 + exp 1 小时前 → AppleSignInExpiredError
    - wrong_audience=True:aud 设错的 → AppleSignInAudienceError
    - wrong_issuer=True:iss 设错的 → AppleSignInInvalidTokenError
    """
    now = int(time.time())
    exp_offset = -3600 if expired else 3600
    payload = {
        "iss": "https://wrong.example.com" if wrong_issuer else issuer,
        "aud": "com.wrong.audience" if wrong_audience else audience,
        "sub": apple_user_id,
        "iat": now - 86400,  # 1 天前签发
        "exp": now + exp_offset,
        "email": email,
        "email_verified": "true" if email_verified else "false",
    }
    return jwt.encode(
        payload,
        keypair.private_key_pem,
        algorithm="RS256",
        headers={"kid": keypair.kid},
    )
