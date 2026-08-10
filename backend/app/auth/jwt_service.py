"""自家 JWT 工具(PR2.5)。

HS256 共享密钥签名(对齐 PR2.5 plan 决策)。一个 JWT_SECRET_KEY env 即可,
适合单后端 side project。RS256 非对称 + refresh_token 推 v3。

API:
- `create_access_token(user_id)`:签发 30 天过期的 access_token
- `verify_token(token)`:验签 + 返 payload;失败抛 `JWTError`

错误显式传播(对齐 CLAUDE.md):过期 / 签名错 / payload 缺字段 各 case 显式区分,
不静默吞。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Any

import jwt
from jwt import InvalidTokenError

from ..config import JWT_ALGORITHM, JWT_EXP_MINUTES, JWT_SECRET_KEY
from ..errors import BaziError


class JWTError(BaziError):
    """JWT 验证失败(基类)。"""

    code = "JWT_ERROR"
    http_status = 401


class JWTExpiredError(JWTError):
    code = "JWT_EXPIRED"
    # message 由调用方覆盖(Apple / 自家 各自上下文)


class JWTInvalidSignatureError(JWTError):
    code = "JWT_INVALID_SIGNATURE"


class JWTMalformedError(JWTError):
    code = "JWT_MALFORMED"


def create_access_token(user_id: str) -> str:
    """签发自家 access_token(HS256 + 30 天过期)。

    Args:
        user_id:服务端 User.id(UUID 字符串)

    Returns:
        JWT 字符串(可放 Authorization: Bearer <token>)
    """
    now = datetime.now(timezone.utc)
    payload: dict[str, Any] = {
        "sub": user_id,  # subject(user_id)
        "iat": int(now.timestamp()),  # issued at
        "exp": int((now + timedelta(minutes=JWT_EXP_MINUTES)).timestamp()),
        "iss": "qicompass-backend",  # 自家标识(便于排错)
    }
    return jwt.encode(payload, JWT_SECRET_KEY, algorithm=JWT_ALGORITHM)


def verify_token(token: str) -> dict[str, Any]:
    """验证自家 access_token。

    Args:
        token:JWT 字符串

    Returns:
        payload dict(含 sub / iat / exp / iss)

    Raises:
        JWTExpiredError:token 过期
        JWTInvalidSignatureError:签名验证失败(密钥错 / 算法错)
        JWTMalformedError:token 格式错(非 JWT)
    """
    if not token or not token.strip():
        raise JWTMalformedError(message="token 为空")
    try:
        payload = jwt.decode(
            token,
            JWT_SECRET_KEY,
            algorithms=[JWT_ALGORITHM],
            # iss 校验放宽(允许旧 token 不带 iss)
            options={"require": ["exp", "iat", "sub"]},
        )
    except jwt.ExpiredSignatureError:
        raise JWTExpiredError(message="token 已过期,请重新登录")
    except jwt.InvalidSignatureError:
        raise JWTInvalidSignatureError(message="token 签名验证失败")
    except InvalidTokenError as e:
        raise JWTMalformedError(message=f"token 格式错:{e}") from e

    if not isinstance(payload, dict):
        # pyjwt 返回类型实际是 dict,防御式校验
        raise JWTMalformedError(message=f"payload 非 dict:{type(payload).__name__}")

    return payload


def extract_user_id(token: str) -> str:
    """便捷接口:验证 token + 返 sub(user_id)。

    Raises:
        各 JWTError 子类
        JWTMalformedError:payload 缺 sub
    """
    payload = verify_token(token)
    user_id = payload.get("sub")
    if not isinstance(user_id, str) or not user_id:
        raise JWTMalformedError(message="payload 缺 sub 字段或非 str")
    return user_id
