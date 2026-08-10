"""PR2.5 /api/auth/sign-in 路由。

流程:
1. iOS PR2 拿到 Apple identityToken
2. POST /api/auth/sign-in 提交 identity_token
3. 后端 verify_apple_identity_token → AppleUserInfo(apple_user_id + email)
4. UserStore.upsert_by_apple_user_id → User(服务端 id)
5. jwt_service.create_access_token(user.id) → 自家 JWT
6. 返回 {access_token, user_id, expires_at} 给 iOS

iOS 拿到 access_token 后存 Keychain,后续 API 调用 Authorization: Bearer <access_token>。
"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Request
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel

from ..auth.apple_signin import verify_apple_identity_token
from ..auth.jwt_service import create_access_token
from ..config import APPLE_SIGN_IN_CLIENT_ID, JWT_EXP_MINUTES
from ..errors import BaziError
from ..models.auth import SignInRequest, SignInResponse

router = APIRouter(tags=["auth"])


@router.post("/api/auth/sign-in", response_model=SignInResponse)
async def sign_in(req: SignInRequest, request: Request) -> SignInResponse:
    """Apple identity_token → 自家 JWT。

    - 成功:返 SignInResponse(access_token + user_id + expires_at)
    - 失败:AppleSignInError(401,验签失败 / aud 错 / 过期 等)
    """
    user_store = request.app.state.user_store

    # 1. 验证 Apple identity_token
    apple_user = await run_in_threadpool(
        verify_apple_identity_token,
        req.identity_token,
        APPLE_SIGN_IN_CLIENT_ID,
    )

    # 2. upsert User
    user = await run_in_threadpool(
        user_store.upsert_by_apple_user_id,
        apple_user.apple_user_id,
        apple_user.email,
    )

    # 3. 签发自家 JWT
    access_token = create_access_token(user.id)

    # 4. 计算过期时间(返给客户端便于 UI 显示)
    expires_at = (
        datetime.now(timezone.utc) + timedelta(minutes=JWT_EXP_MINUTES)
    ).isoformat()

    return SignInResponse(
        access_token=access_token,
        user_id=user.id,
        expires_at=expires_at,
    )
