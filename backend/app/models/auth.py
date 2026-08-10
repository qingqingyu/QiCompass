"""PR2.5 账号系统 Pydantic models。"""

from __future__ import annotations

from pydantic import BaseModel, Field


class SignInRequest(BaseModel):
    """POST /api/auth/sign-in 请求体。"""

    identity_token: str = Field(
        ...,
        description="Apple 返回的 identityToken(JWT 字符串,iOS 调 ASAuthorization 后拿到)",
        min_length=1,
    )


class SignInResponse(BaseModel):
    """POST /api/auth/sign-in 响应体。"""

    access_token: str = Field(..., description="自家 JWT(30 天过期,iOS 存 Keychain)")
    token_type: str = Field(default="Bearer")
    user_id: str = Field(..., description="服务端 User.id(UUID)")
    expires_at: str = Field(..., description="access_token 过期时间(ISO 8601 UTC)")
