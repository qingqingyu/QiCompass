"""Sign in with Google ID Token 验证(照 apple_signin.py 模式)。

流程:
1. iOS 用 GoogleSignIn SDK 拿到 Google ID Token(JWT,含 iss/aud/sub/email 等)
2. 后端拉 Google 公钥 GET https://www.googleapis.com/oauth2/v3/certs(JWKS 格式),缓存 1 小时
3. 用公钥 RS256 验签 id_token
4. 验 aud == GOOGLE_SIGN_IN_CLIENT_ID + exp 未过期(jwt.decode 内做);
   iss ∈ {"accounts.google.com", "https://accounts.google.com"}(Google 两种格式都发,
   PyJWT 的 issuer 参数不支持多值,故 decode 后手动校验)
5. 提 sub(google_user_id,稳定)+ email(Google 每次登录都返)+ email_verified

与 Apple 的差异:
- iss 有两个合法值 → 手动校验,不走 jwt.decode 的 issuer 参数
- email_verified 是原生 bool(Apple 是 "true"/"false" 字符串)
- aud 无兜底默认:GOOGLE_SIGN_IN_CLIENT_ID 未配置时抛
  GoogleSignInNotConfiguredError(503,服务端配置错,不是客户端 401)

错误显式传播(对齐 CLAUDE.md):验签失败 / iss 错 / aud 错 / 过期 / 未配置 各 case 显式抛错。
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import jwt
from jwt import InvalidTokenError, PyJWKClient

from ..config import GOOGLE_PUBLIC_KEYS_CACHE_TTL, GOOGLE_SIGN_IN_CLIENT_ID
from ..errors import BaziError

_GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
# Google ID Token 的 iss 两种格式都合法(文档:
# https://developers.google.com/identity/sign-in/web/backend-auth)
_GOOGLE_ISSUERS = frozenset({"accounts.google.com", "https://accounts.google.com"})

# PyJWKClient 自带缓存,我们额外维护一层 TTL(配置 GOOGLE_PUBLIC_KEYS_CACHE_TTL=3600),
# 减少 Google 限流风险(对齐 apple_signin.py 的双层缓存模式)
_jwks_client: PyJWKClient | None = None
_jwks_client_created_at: float = 0.0


class GoogleSignInError(BaziError):
    """Google Sign in ID Token 验证失败基类。"""

    code = "GOOGLE_SIGN_IN_ERROR"
    http_status = 401


class GoogleSignInInvalidTokenError(GoogleSignInError):
    code = "GOOGLE_SIGN_IN_INVALID_TOKEN"


class GoogleSignInExpiredError(GoogleSignInError):
    code = "GOOGLE_SIGN_IN_EXPIRED"


class GoogleSignInAudienceError(GoogleSignInError):
    code = "GOOGLE_SIGN_IN_AUDIENCE_MISMATCH"


class GoogleSignInNotConfiguredError(BaziError):
    """GOOGLE_SIGN_IN_CLIENT_ID 未配置(服务端配置错,不是客户端 token 错)。"""

    code = "GOOGLE_SIGN_IN_NOT_CONFIGURED"
    http_status = 503


@dataclass(frozen=True)
class GoogleUserInfo:
    """从 Google ID Token 解出的用户信息。"""

    google_user_id: str  # Google sub,稳定标识,跨设备相同
    email: str | None  # Google 每次登录都返(不同于 Apple 仅首次)
    email_verified: bool  # Google 原生 bool(Apple 是字符串)


def _get_jwks_client() -> PyJWKClient:
    """获取(必要时刷新)Google JWKS 客户端。

    全局缓存,TTL = GOOGLE_PUBLIC_KEYS_CACHE_TTL(默认 3600s)。
    超时后丢弃重建,下次调用拉最新公钥(Google 公钥轮换安全)。
    """
    global _jwks_client, _jwks_client_created_at
    import time

    now = time.time()
    if _jwks_client is None or (now - _jwks_client_created_at) > GOOGLE_PUBLIC_KEYS_CACHE_TTL:
        # lifespan 控 PyJWKClient 内部 JWKS set 缓存(参数名是 lifespan,
        # 不是 lifespan_keys_cache_seconds ——后者会 TypeError,见
        # test_google_signin.py 的构造回归测试),设比外层 TTL 短(60s),
        # 便于外层 TTL 过期后立即拉新
        _jwks_client = PyJWKClient(_GOOGLE_JWKS_URL, lifespan=60)
        _jwks_client_created_at = now
    return _jwks_client


def verify_google_identity_token(
    token: str,
    expected_audience: str | None = GOOGLE_SIGN_IN_CLIENT_ID,
) -> GoogleUserInfo:
    """验证 Google Sign in ID Token。

    Args:
        token:GoogleSignIn SDK 返回的 idToken(JWT 字符串)
        expected_audience:期望的 aud(默认 GOOGLE_SIGN_IN_CLIENT_ID,
            即 Google Cloud Console iOS OAuth client 的 CLIENT_ID)

    Returns:
        GoogleUserInfo(google_user_id + email + email_verified)

    Raises:
        GoogleSignInNotConfiguredError:expected_audience 为空(服务端未配置 GOOGLE_SIGN_IN_CLIENT_ID)
        GoogleSignInInvalidTokenError:token 格式错 / 签名错 / iss 错 / 缺 sub
        GoogleSignInExpiredError:token 过期
        GoogleSignInAudienceError:aud 与期望不符
    """
    if not expected_audience:
        raise GoogleSignInNotConfiguredError(
            message="GOOGLE_SIGN_IN_CLIENT_ID 未配置(Google 登录不可用)。"
            "在 backend/.env 设置 Google Cloud Console 的 iOS OAuth client CLIENT_ID。"
        )

    if not token or not token.strip():
        raise GoogleSignInInvalidTokenError(message="id_token 为空")

    jwks = _get_jwks_client()
    try:
        # get_signing_key_from_jwt 内部解析 token header(kid)→ 从 JWKS 查对应公钥
        signing_key = jwks.get_signing_key_from_jwt(token)
    except Exception as e:
        # PyJWKClient 找不到 kid / JWKS 拉取失败 / 等
        raise GoogleSignInInvalidTokenError(
            message=f"无法解析 Google id_token 签名密钥:{e}"
        ) from e

    try:
        payload: Any = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],  # Google 固定 RS256
            audience=expected_audience,
            # 防御纵深:强制要求 exp claim 存在(签名覆盖 payload,攻击者无法
            # 剥离;此处防的是"无 exp 即不过期"的病态 token 被放行)
            options={"require": ["exp"]},
            # issuer 不在这传:Google 有两个合法 iss 值,PyJWT 不支持多值,下面手动校验
        )
    except jwt.ExpiredSignatureError:
        raise GoogleSignInExpiredError(message="Google id_token 已过期")
    except jwt.InvalidAudienceError:
        raise GoogleSignInAudienceError(
            message=f"id_token aud 与期望不符(期望 {expected_audience})"
        )
    except InvalidTokenError as e:
        raise GoogleSignInInvalidTokenError(
            message=f"id_token 验签失败:{e}"
        ) from e

    if not isinstance(payload, dict):
        raise GoogleSignInInvalidTokenError(
            message=f"id_token payload 非 dict:{type(payload).__name__}"
        )

    # iss 手动校验(双合法值,见 _GOOGLE_ISSUERS)
    issuer = payload.get("iss")
    if issuer not in _GOOGLE_ISSUERS:
        raise GoogleSignInInvalidTokenError(
            message=(
                "id_token iss 与期望不符"
                f"(期望 {' 或 '.join(sorted(_GOOGLE_ISSUERS))},实际 {issuer!r})"
            )
        )

    google_user_id = payload.get("sub")
    if not isinstance(google_user_id, str) or not google_user_id:
        raise GoogleSignInInvalidTokenError(message="id_token 缺 sub 字段")

    email = payload.get("email")
    # Google 原生发 bool;防御性兼容字符串 "true"(个别旧客户端场景)
    email_verified_raw = payload.get("email_verified")
    email_verified = email_verified_raw is True or email_verified_raw == "true"

    return GoogleUserInfo(
        google_user_id=google_user_id,
        email=email if isinstance(email, str) else None,
        email_verified=email_verified,
    )
