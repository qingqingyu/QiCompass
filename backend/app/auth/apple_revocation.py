"""Sign in with Apple token 吊销(账号删除前置,2026-11-24)。

Apple 审核 5.1.1(v):提供 Sign in with Apple 的 App 在删除账号时**必须**调
Apple REST API 吊销用户 token。docs/账号删除端点设计决策-2026-11-24.md §5.1。

流程(删号前,由 API 层调用):
1. iOS 端先让用户**重新 Sign in with Apple**拿新鲜 authorization code
   (顺带封堵「偷来的长效 JWT 恶意删号」——重新认证证明操作者掌握 Apple 凭据)
2. `revoke_apple_tokens(authorization_code, expected_apple_user_id)`:
   a. 用 .p8 私钥签 ES256 client_secret JWT(团队 ID + Key ID + Bundle ID)
   b. POST /auth/token 换 code → access_token / refresh_token / id_token
   c. 验 id_token(复用 apple_signin 的 JWKS 验签)→ sub 必须等于被删账号的
      provider_user_id(防拿 B 的 code 删 A 的账号)
   d. POST /auth/revoke 吊销 refresh_token
3. 任一步失败 → 显式抛错,API 层**不执行删除**(不做半删:Apple 侧未吊销
   而本地已删 = 用户重登会创建无历史新账号,Apple 侧凭据仍悬空)

错误显式传播:配置缺失(503)/ code 无效 / sub 不匹配 / Apple 端点错 各自
显式异常类型,不静默吞。

Google 账号无需本模块:Google 登录只验短效 idToken,后端不存任何 Google
token,没有可吊销之物(Google 账号删除直接走 delete_user_data)。
"""

from __future__ import annotations

import logging
import time
from dataclasses import dataclass

import httpx
import jwt

from ..config import (
    APPLE_AUTH_KEY_ID,
    APPLE_AUTH_PRIVATE_KEY,
    APPLE_AUTH_TEAM_ID,
    APPLE_REVOKE_TIMEOUT_SECONDS,
    APPLE_SIGN_IN_CLIENT_ID,
)
from ..errors import BaziError
from .apple_signin import verify_apple_identity_token

logger = logging.getLogger(__name__)

_APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token"
_APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke"
_APPLE_AUDIENCE = "https://appleid.apple.com"
# client_secret JWT 有效期(Apple 上限 6 个月;删号是即时调用,短窗足够)
_CLIENT_SECRET_TTL_SECONDS = 600


class AppleRevocationError(BaziError):
    """Apple token 吊销失败基类。"""

    code = "APPLE_REVOCATION_ERROR"
    http_status = 502


class AppleRevocationNotConfiguredError(AppleRevocationError):
    """服务端未配齐 .p8 三元组(team/key/private key)→ 无法吊销,拒绝删号。"""

    code = "APPLE_REVOCATION_NOT_CONFIGURED"
    http_status = 503


class AppleRevocationCodeInvalidError(AppleRevocationError):
    """authorization code 换 token 失败(code 过期/已用/不属于本 App)。"""

    code = "APPLE_REVOCATION_CODE_INVALID"


class AppleRevocationUserMismatchError(AppleRevocationError):
    """code 换出的 id_token sub 与被删账号不符(拿别人的 code 删这个账号)。"""

    code = "APPLE_REVOCATION_USER_MISMATCH"
    http_status = 403


class AppleRevocationEndpointError(AppleRevocationError):
    """Apple revoke 端点返回非 2xx。"""

    code = "APPLE_REVOCATION_ENDPOINT_FAILED"


def revocation_configured() -> bool:
    """Apple 吊销三元组是否配齐(启动日志与 API 层 503 判定共用)。"""
    return bool(APPLE_AUTH_TEAM_ID and APPLE_AUTH_KEY_ID and APPLE_AUTH_PRIVATE_KEY)


def _client_secret() -> str:
    """签 ES256 client_secret JWT(Apple /auth/token 与 /auth/revoke 共用)。

    payload 按 Apple 文档:iss=团队 ID / sub=client_id(Bundle ID)/
    aud=https://appleid.apple.com / iat / exp;header kid=Key ID。
    """
    now = time.time()
    payload = {
        "iss": APPLE_AUTH_TEAM_ID,
        "sub": APPLE_SIGN_IN_CLIENT_ID,
        "aud": _APPLE_AUDIENCE,
        "iat": int(now),
        "exp": int(now + _CLIENT_SECRET_TTL_SECONDS),
    }
    return jwt.encode(
        payload,
        APPLE_AUTH_PRIVATE_KEY,
        algorithm="ES256",
        headers={"kid": APPLE_AUTH_KEY_ID},
    )


@dataclass(frozen=True)
class _TokenExchangeResult:
    refresh_token: str | None


async def revoke_apple_tokens(
    authorization_code: str,
    expected_apple_user_id: str,
) -> None:
    """换 code → 验归属 → 吊销 refresh_token;失败任一步显式抛错。

    Args:
        authorization_code:iOS 重新 Sign in with Apple 拿到的新鲜 code
            (一次性,10 分钟有效)
        expected_apple_user_id:被删账号的 Apple sub(qicompass_user.
            provider_user_id)——code 换出的 id_token.sub 必须与之相等

    Raises:
        AppleRevocationNotConfiguredError:三元组缺失
        AppleRevocationCodeInvalidError:code 换 token 失败
        AppleRevocationUserMismatchError:sub 不匹配(403)
        AppleRevocationEndpointError:revoke 端点失败
    """
    if not revocation_configured():
        raise AppleRevocationNotConfiguredError(
            message="Apple 账号删除需要服务端配置 APPLE_AUTH_TEAM_ID / "
                    "APPLE_AUTH_KEY_ID / APPLE_AUTH_PRIVATE_KEY(.p8);未配齐"
                    "前拒绝删除(否则 Apple 侧 token 无法吊销)")
    if not authorization_code or not authorization_code.strip():
        raise AppleRevocationCodeInvalidError(message="apple_authorization_code 为空")

    secret = _client_secret()
    data = {
        "client_id": APPLE_SIGN_IN_CLIENT_ID,
        "client_secret": secret,
        "code": authorization_code.strip(),
        "grant_type": "authorization_code",
    }
    async with httpx.AsyncClient(
        timeout=APPLE_REVOKE_TIMEOUT_SECONDS,
    ) as client:
        # 1. code → tokens
        resp = await client.post(_APPLE_TOKEN_URL, data=data)
        if resp.status_code != 200:
            raise AppleRevocationCodeInvalidError(
                message=f"Apple /auth/token 换 code 失败:HTTP {resp.status_code} "
                        f"{resp.text[:200]}")
        try:
            tokens = resp.json()
        except ValueError as exc:
            # 200 但非 JSON(代理页/HTML 错误页等)——归入 code 无效类,
            # 不让裸 ValueError 冒成 500
            raise AppleRevocationCodeInvalidError(
                message=f"Apple /auth/token 响应非 JSON:{exc}") from exc

        # 2. 验归属:id_token.sub 必须等于被删账号的 sub
        id_token = tokens.get("id_token")
        if not isinstance(id_token, str) or not id_token:
            raise AppleRevocationCodeInvalidError(
                message="Apple /auth/token 响应缺 id_token,无法核对账号归属")
        user_info = verify_apple_identity_token(id_token)
        if user_info.apple_user_id != expected_apple_user_id:
            raise AppleRevocationUserMismatchError(
                message="authorization code 归属的 Apple 账号与被删账号不符"
                        f"(code.sub={user_info.apple_user_id[:8]}… ≠ "
                        f"account.sub={expected_apple_user_id[:8]}…)"
                        "——请用被删账号本人的 Apple 凭据重新认证")

        # 3. 吊销 refresh_token(无 refresh_token 时吊销 access_token——
        #    短期内重签发窗口更小,仍是 Apple 认可的吊销形态)
        token_to_revoke = tokens.get("refresh_token") or tokens.get("access_token")
        if not isinstance(token_to_revoke, str) or not token_to_revoke:
            raise AppleRevocationEndpointError(
                message="Apple /auth/token 响应既无 refresh_token 也无 "
                        "access_token,无可吊销 token")
        revoke_resp = await client.post(
            _APPLE_REVOKE_URL,
            data={
                "client_id": APPLE_SIGN_IN_CLIENT_ID,
                "client_secret": secret,
                "token": token_to_revoke,
                "token_type_hint": "refresh_token",
            },
        )
        if revoke_resp.status_code != 200:
            raise AppleRevocationEndpointError(
                message=f"Apple /auth/revoke 失败:HTTP "
                        f"{revoke_resp.status_code} {revoke_resp.text[:200]}")

    logger.info(
        "apple.revocation.ok sub_prefix=%s",
        expected_apple_user_id[:8],
    )
