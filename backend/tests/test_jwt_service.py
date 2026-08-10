"""auth/jwt_service.py 单元测试。

验收用例:
- create_access_token 输出可被 verify_token 验证
- 过期 token → JWTExpiredError
- 错密钥签名 → JWTInvalidSignatureError
- 非 JWT 字符串 → JWTMalformedError
- payload 缺 sub → JWTMalformedError
"""

from __future__ import annotations

import time

import jwt
import pytest

from app.auth.jwt_service import (
    JWTExpiredError,
    JWTInvalidSignatureError,
    JWTMalformedError,
    create_access_token,
    extract_user_id,
    verify_token,
)
from app.config import JWT_ALGORITHM, JWT_EXP_MINUTES, JWT_SECRET_KEY


def test_create_and_verify_round_trip():
    """create_access_token → verify_token 往返一致。"""
    user_id = "user-uuid-test-001"
    token = create_access_token(user_id)
    assert isinstance(token, str)

    payload = verify_token(token)
    assert payload["sub"] == user_id
    assert payload["iss"] == "qicompass-backend"
    assert "iat" in payload
    assert "exp" in payload
    # 默认 30 天过期
    assert payload["exp"] - payload["iat"] == JWT_EXP_MINUTES * 60


def test_extract_user_id_returns_sub():
    """extract_user_id 便捷接口返 sub。"""
    token = create_access_token("user-abc")
    assert extract_user_id(token) == "user-abc"


def test_verify_expired_token_raises_expired_error():
    """过期 token → JWTExpiredError。"""
    # 手动构造已过期的 token(覆盖 iat/exp)
    import datetime as dt
    payload = {
        "sub": "user-expired",
        "iat": int((dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=2)).timestamp()),
        "exp": int((dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)).timestamp()),
        "iss": "qicompass-backend",
    }
    expired_token = jwt.encode(payload, JWT_SECRET_KEY, algorithm=JWT_ALGORITHM)

    with pytest.raises(JWTExpiredError, match="过期"):
        verify_token(expired_token)


def test_verify_wrong_secret_raises_invalid_signature():
    """错密钥签名 → JWTInvalidSignatureError。"""
    token = jwt.encode(
        {"sub": "user-x", "iat": int(time.time()), "exp": int(time.time()) + 3600},
        "wrong-secret",
        algorithm=JWT_ALGORITHM,
    )
    with pytest.raises(JWTInvalidSignatureError, match="签名验证失败"):
        verify_token(token)


def test_verify_malformed_token_raises_malformed_error():
    """非 JWT 字符串 → JWTMalformedError。"""
    with pytest.raises(JWTMalformedError, match="格式错"):
        verify_token("this-is-not-a-jwt")


def test_verify_empty_token_raises_malformed_error():
    """空 token → JWTMalformedError(显式校验,不静默返 None)。"""
    with pytest.raises(JWTMalformedError, match="为空"):
        verify_token("")


def test_verify_token_missing_sub_raises_malformed():
    """payload 缺 sub → JWTMalformedError。"""
    token = jwt.encode(
        {"iat": int(time.time()), "exp": int(time.time()) + 3600},  # 缺 sub
        JWT_SECRET_KEY,
        algorithm=JWT_ALGORITHM,
    )
    with pytest.raises(JWTMalformedError, match="sub"):
        extract_user_id(token)


def test_verify_token_wrong_algorithm_rejected():
    """用其他算法(如 none)签的 token 拒签。
    防算法混淆攻击(pyjwt 默认验 algorithms 白名单)。"""
    # jwt.encode 用 HS512,但 verify 要求 HS256 → 拒签
    token = jwt.encode(
        {"sub": "user-x", "iat": int(time.time()), "exp": int(time.time()) + 3600},
        JWT_SECRET_KEY,
        algorithm="HS512",
    )
    with pytest.raises((JWTInvalidSignatureError, JWTMalformedError)):
        verify_token(token)
