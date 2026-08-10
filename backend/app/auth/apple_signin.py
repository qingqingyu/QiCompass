"""Sign in with Apple ID Token 验证(PR2.5)。

流程:
1. iOS 拿到 identityToken(Apple JWT,含 iss/aud/sub/email 等)
2. 后端拉 Apple 公钥 GET https://appleid.apple.com/auth/keys(JWKS 格式),缓存 1 小时
3. 用公钥 RS256 验签 identityToken
4. 验 iss == "https://appleid.apple.com" + aud == APPLE_SIGN_IN_CLIENT_ID + exp 未过期
5. 提 sub(apple_user_id,稳定)+ email(仅首次登录返回)

错误显式传播(对齐 CLAUDE.md):验签失败 / iss 错 / aud 错 / 过期 各 case 显式抛错。
"""

from __future__ import annotations

from dataclasses import dataclass

import jwt
from jwt import InvalidTokenError, PyJWKClient

from ..config import APPLE_PUBLIC_KEYS_CACHE_TTL, APPLE_SIGN_IN_CLIENT_ID
from ..errors import BaziError

_APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
_APPLE_ISSUER = "https://appleid.apple.com"

# PyJWKClient 自带缓存(默认 300 秒 keys_cache_keys),但我们额外维护一层
# TTL(配置 APPLE_PUBLIC_KEYS_CACHE_TTL=3600),允许更长缓存减少 Apple 限流风险
_jwks_client: PyJWKClient | None = None
_jwks_client_created_at: float = 0


class AppleSignInError(BaziError):
    """Apple Sign in ID Token 验证失败基类。"""

    code = "APPLE_SIGN_IN_ERROR"
    http_status = 401


class AppleSignInInvalidTokenError(AppleSignInError):
    code = "APPLE_SIGN_IN_INVALID_TOKEN"


class AppleSignInExpiredError(AppleSignInError):
    code = "APPLE_SIGN_IN_EXPIRED"


class AppleSignInAudienceError(AppleSignInError):
    code = "APPLE_SIGN_IN_AUDIENCE_MISMATCH"


@dataclass(frozen=True)
class AppleUserInfo:
    """从 Apple identityToken 解出的用户信息。"""

    apple_user_id: str  # Apple sub,稳定标识,跨设备相同
    email: str | None  # 仅首次登录 Apple 返回,后续 nil
    email_verified: bool  # Apple 是否已验证 email


def _get_jwks_client() -> PyJWKClient:
    """获取(必要时刷新)Apple JWKS 客户端。

    全局缓存,TTL = APPLE_PUBLIC_KEYS_CACHE_TTL(默认 3600s)。
    超时后丢弃重建,下次调用拉最新公钥(Apple 公钥轮换安全)。
    """
    global _jwks_client, _jwks_client_created_at
    import time

    now = time.time()
    if _jwks_client is None or (now - _jwks_client_created_at) > APPLE_PUBLIC_KEYS_CACHE_TTL:
        # lifespan_keys_cache_seconds 控 PyJWKClient 内部 keys 缓存,
        # 设比外层 TTL 短一点(60s),便于外层 TTL 过期后立即拉新
        _jwks_client = PyJWKClient(
            _APPLE_JWKS_URL, lifespan_keys_cache_seconds=60
        )
        _jwks_client_created_at = now
    return _jwks_client


def verify_apple_identity_token(
    token: str,
    expected_audience: str = APPLE_SIGN_IN_CLIENT_ID,
) -> AppleUserInfo:
    """验证 Apple Sign in ID Token。

    Args:
        token:Apple 返回的 identityToken(JWT 字符串)
        expected_audience:期望的 aud(默认 APPLE_SIGN_IN_CLIENT_ID = Bundle ID)

    Returns:
        AppleUserInfo(apple_user_id + email + email_verified)

    Raises:
        AppleSignInInvalidTokenError:token 格式错 / 签名错 / iss 错 / aud 错
        AppleSignInExpiredError:token 过期
    """
    if not token or not token.strip():
        raise AppleSignInInvalidTokenError(message="identity_token 为空")

    jwks = _get_jwks_client()
    try:
        # get_signing_key_from_jwt 内部解析 token header(kid)→ 从 JWKS 查对应公钥
        signing_key = jwks.get_signing_key_from_jwt(token)
    except Exception as e:
        # PyJWKClient 找不到 kid / JWKS 拉取失败 / 等
        raise AppleSignInInvalidTokenError(
            message=f"无法解析 Apple identity_token 签名密钥:{e}"
        ) from e

    try:
        payload = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],  # Apple 固定 RS256
            audience=expected_audience,
            issuer=_APPLE_ISSUER,
        )
    except jwt.ExpiredSignatureError:
        raise AppleSignInExpiredError(message="Apple identity_token 已过期")
    except jwt.InvalidAudienceError:
        raise AppleSignInAudienceError(
            message=f"identity_token aud 与期望不符(期望 {expected_audience})"
        )
    except jwt.InvalidIssuerError:
        raise AppleSignInInvalidTokenError(
            message=f"identity_token iss 与期望不符(期望 {_APPLE_ISSUER})"
        )
    except InvalidTokenError as e:
        raise AppleSignInInvalidTokenError(
            message=f"identity_token 验签失败:{e}"
        ) from e

    if not isinstance(payload, dict):
        raise AppleSignInInvalidTokenError(
            message=f"identity_token payload 非 dict:{type(payload).__name__}"
        )

    apple_user_id = payload.get("sub")
    if not isinstance(apple_user_id, str) or not apple_user_id:
        raise AppleSignInInvalidTokenError(message="identity_token 缺 sub 字段")

    email = payload.get("email")
    # Apple 用字符串 "true"/"false" 而非 bool
    email_verified_raw = payload.get("email_verified")
    email_verified = email_verified_raw == "true" or email_verified_raw is True

    return AppleUserInfo(
        apple_user_id=apple_user_id,
        email=email if isinstance(email, str) else None,
        email_verified=email_verified,
    )
