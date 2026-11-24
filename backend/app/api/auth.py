"""PR2.5 /api/auth/sign-in 路由(Apple / Google 双 provider,2026-08-16 起)。

流程:
1. iOS 拿到 provider 的 identityToken/idToken
2. POST /api/auth/sign-in 提交 provider + identity_token(+ 可选 user_local_id 用于 backfill)
3. 后端按 provider 分支验签(apple_signin / google_signin)→ UserInfo(sub + email)
4. UserStore.upsert_by_provider → User(服务端 id)
5. (可选)EntitlementStore.backfill_user_id_by_local_id → 老 entitlement 补 user_id
6. jwt_service.create_access_token(user.id) → 自家 JWT
7. 返回 {access_token, user_id, expires_at} 给 iOS

v1 产品决策(2026-08-16):不跨 provider 合并账号——同一人先用 Apple 再用
Google 登录是两个独立账号(UNIQUE(provider, provider_user_id)),entitlement
不互通。原因:Apple 私密转发 email 无法可靠判定同人,自动合并有误合风险。

iOS 拿到 access_token 后存 Keychain,后续 API 调用 Authorization: Bearer <access_token>。
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, Request
from fastapi.concurrency import run_in_threadpool

from ..auth.apple_revocation import revoke_apple_tokens
from ..auth.apple_signin import verify_apple_identity_token
from ..auth.dependencies import require_authenticated_user
from ..auth.google_signin import verify_google_identity_token
from ..auth.jwt_service import create_access_token
from ..config import APPLE_SIGN_IN_CLIENT_ID, GOOGLE_SIGN_IN_CLIENT_ID, JWT_EXP_MINUTES
from ..errors import BaziError
from ..models.auth import (
    DeleteAccountRequest,
    DeleteAccountResponse,
    SignInRequest,
    SignInResponse,
)

router = APIRouter(tags=["auth"])
logger = logging.getLogger(__name__)


class AccountNotFoundError(BaziError):
    """删除时账号已不存在(require_authenticated_user 核验后被并发删除)。

    BaziError 构造器只收 message(code/http_status 是子类类属性,不走
    kwargs)——本类即「404 语义 + ACCOUNT_NOT_FOUND code」的正确载体。
    """

    code = "ACCOUNT_NOT_FOUND"
    http_status = 404


@router.post("/api/auth/sign-in", response_model=SignInResponse)
async def sign_in(req: SignInRequest, request: Request) -> SignInResponse:
    """provider identity_token → 自家 JWT(Apple / Google)。

    - 成功:返 SignInResponse(access_token + user_id + expires_at)
    - 失败:AppleSignInError / GoogleSignInError(401,验签失败 / aud 错 / 过期 等);
      GoogleSignInNotConfiguredError(503,服务端未配 GOOGLE_SIGN_IN_CLIENT_ID)
    """
    user_store = request.app.state.user_store

    # 1. 按 provider 分支验签,统一解出 (provider_user_id, email)
    if req.provider == "google":
        google_user = await run_in_threadpool(
            verify_google_identity_token,
            req.identity_token,
            GOOGLE_SIGN_IN_CLIENT_ID,
        )
        provider_user_id = google_user.google_user_id
        email = google_user.email
    else:
        apple_user = await run_in_threadpool(
            verify_apple_identity_token,
            req.identity_token,
            APPLE_SIGN_IN_CLIENT_ID,
        )
        provider_user_id = apple_user.apple_user_id
        email = apple_user.email

    # 2. upsert User(同一人不同 provider = 不同账号,见模块 docstring 决策)
    user = await run_in_threadpool(
        user_store.upsert_by_provider,
        req.provider,
        provider_user_id,
        email,
    )

    # 3. 签发自家 JWT
    access_token = create_access_token(user.id)

    # 4. Backfill 老 entitlement:客户端传 user_local_id 时,把该 UUID 下
    #    既有但 user_id 为 NULL 的购买记录补上 user_id,让匿名时期的购买
    #    跟随登录账号(provider 无关)迁移。失败不阻断登录(降级:user_id 仍 NULL,
    #    老数据继续按 user_local_id 兜底查询,见 store.get_active)。
    backfilled_count = 0
    if req.user_local_id:
        entitlement_store = request.app.state.entitlement_store
        try:
            backfilled_count = await run_in_threadpool(
                entitlement_store.backfill_user_id_by_local_id,
                user_id=user.id,
                user_local_id=req.user_local_id,
            )
        except Exception as e:
            # 失败不阻断登录,但显式记日志(对齐 CLAUDE.md "错误显式传播":不静默吞,
            # 但 backfill 是辅助路径,降级比 fail-the-login 用户体验更好)
            logger.exception(
                "auth.sign_in.backfill_failed user_id=%s user_local_id=%s error=%r",
                # user_local_id 脱敏只留前 8 位(2026-10-07:它在 entitlement
                # 兜底查询里起密钥作用,全文进日志 = 泄露即可冒用购买记录)
                user.id, req.user_local_id[:8], e,
            )

    # 5. 计算过期时间(返给客户端便于 UI 显示)
    expires_at = (
        datetime.now(timezone.utc) + timedelta(minutes=JWT_EXP_MINUTES)
    ).isoformat()

    logger.info(
        "auth.sign_in.ok user_id=%s provider=%s provider_user_id_prefix=%s backfilled=%d",
        user.id, req.provider, provider_user_id[:8], backfilled_count,
    )

    return SignInResponse(
        access_token=access_token,
        user_id=user.id,
        expires_at=expires_at,
    )


@router.delete("/api/auth/account", response_model=DeleteAccountResponse)
async def delete_account(
    req: DeleteAccountRequest,
    request: Request,
    user_id: str = Depends(require_authenticated_user),
) -> DeleteAccountResponse:
    """DELETE /api/auth/account:删除账号及全部服务端数据(2026-11-24)。

    Apple 5.1.1(v) 硬性要求(应用内删账号)。次序(**先吊销后删除**——
    Apple 侧吊销失败则本地不删,不做半删):
    1. require_authenticated_user(JWT 验签 + 账号存在性核验)
    2. Apple 用户:revoke_apple_tokens(换 code → 验归属 sub → 吊销);
       配置缺失 → 503 拒删;sub 不匹配 → 403
    3. delete_user_data(单事务:出生数据整删 / 交易台账匿名化保留 /
       含自输入文本缓存清 / 其余账号行删;失败回滚)
    4. 响应返回审计摘要(各表行数;完整数据见服务端 account.deleted 日志)

    Google 用户:后端不存 Google token,无可吊销,直接走第 3 步。
    """
    user_store = request.app.state.user_store
    # 账号存在性再核验(require_authenticated_user 已查过;此处取 provider)
    user = await run_in_threadpool(user_store.get_by_id, user_id)
    if user is None:
        raise AccountNotFoundError(
            f"账号不存在或已删除(user_id={user_id[:8]}…)")

    # Apple:先吊销 Apple 侧 token(失败 → 显式错,不进入删除)
    if user.provider == "apple":
        await revoke_apple_tokens(
            authorization_code=req.apple_authorization_code or "",
            expected_apple_user_id=user.provider_user_id,
        )

    # 跨表删除(同步 SQLite 事务 → 线程池)
    stats = await run_in_threadpool(
        user_store.delete_account_data, user_id)

    logger.info(
        "auth.account.deleted user_id_prefix=%s provider=%s tables=%s",
        user_id[:8], user.provider, stats,
    )
    return DeleteAccountResponse(
        deleted=True,
        user_id_prefix=user_id[:8],
        tables=stats,
    )
