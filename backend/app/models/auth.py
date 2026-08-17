"""PR2.5 账号系统 Pydantic models。"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class SignInRequest(BaseModel):
    """POST /api/auth/sign-in 请求体。"""

    provider: Literal["apple", "google"] = Field(
        default="apple",
        description="登录方式。默认 apple(老客户端不带此字段 → Apple,向后兼容)。",
    )
    identity_token: str = Field(
        ...,
        description="provider 返回的 identityToken/idToken(JWT 字符串,iOS 调系统 ASAuthorization 或 GoogleSignIn SDK 后拿到)",
        min_length=1,
    )
    user_local_id: str | None = Field(
        default=None,
        description=(
            "客户端 lazy 生成的 UUID(可选)。登录时传入用于 backfill 老 entitlement:"
            "把仅有 user_local_id、user_id 为 NULL 的老数据补上 user_id,"
            "让用户既有的匿名购买能跟随 Apple 账号迁移过来。"
        ),
        min_length=1,
    )


class SignInResponse(BaseModel):
    """POST /api/auth/sign-in 响应体。"""

    access_token: str = Field(..., description="自家 JWT(30 天过期,iOS 存 Keychain)")
    token_type: str = Field(default="Bearer")
    user_id: str = Field(..., description="服务端 User.id(UUID)")
    expires_at: str = Field(..., description="access_token 过期时间(ISO 8601 UTC)")
