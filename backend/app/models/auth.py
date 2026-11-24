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


class DeleteAccountRequest(BaseModel):
    """DELETE /api/auth/account 请求体(2026-11-24,Apple 5.1.1(v))。

    Apple 用户必带 apple_authorization_code:删号前 iOS 先让用户重新
    Sign in with Apple 拿新鲜 code,后端换 token 并吊销(Apple 硬性要求;
    重新认证同时证明操作者掌握被删账号的 Apple 凭据)。Google 用户无需
    (后端不存 Google token,无可吊销)。
    """

    apple_authorization_code: str | None = Field(
        default=None,
        description="iOS 重新 Sign in with Apple 拿到的一次性 authorization "
                    "code(Apple 账号必填;Google 账号不带)",
        min_length=1,
    )


class DeleteAccountResponse(BaseModel):
    """DELETE /api/auth/account 响应体。"""

    deleted: bool = Field(default=True, description="恒 true(失败走错误响应)")
    user_id_prefix: str = Field(
        ..., description="被删账号 id 前 8 位(审计显示用,不含完整标识)")
    tables: dict[str, int] = Field(
        ..., description="各表受影响行数(审计摘要;不含任何身份数据)")
