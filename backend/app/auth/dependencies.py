"""FastAPI Depends:从 Authorization header 验 JWT 拿 user_id(PR2.5)。

策略(对齐 plan "entitlement 加 nullable user_id + 兜底 user_local_id"):
- 有 Authorization: Bearer <jwt> → 验签 → 返 user.id(str)
- 无 Authorization → 返 None(老 iOS 客户端兼容,继续走 user_local_id 模式)

调用方(interpret.py / entitlement.py)把 user_id 传给 store:
- store.get_active(user_id=user_id, user_local_id=req.user_local_id)
- store 优先 user_id 查,兜底 user_local_id
"""

from __future__ import annotations

from fastapi import Header

from .jwt_service import extract_user_id
from .jwt_service import (
    JWTExpiredError,
    JWTInvalidSignatureError,
    JWTMalformedError,
)


async def get_current_user_id(
    authorization: str | None = Header(default=None),
) -> str | None:
    """从 Authorization header 验 JWT 拿 user_id。

    Args:
        authorization:HTTP Authorization header(格式 "Bearer <jwt>" 或 None)

    Returns:
        user.id(str)如果验签成功;None 如果没 Authorization header(老 iOS 客户端)

    Raises:
        JWTExpiredError / JWTInvalidSignatureError / JWTMalformedError:
            Authorization 存在但 token 验签失败(401,显式抛)
    """
    if not authorization:
        return None  # 无 header → 老 iOS 客户端走 user_local_id 兜底

    # 解析 "Bearer <token>" 前缀
    parts = authorization.split(maxsplit=1)
    if len(parts) != 2 or parts[0].lower() != "bearer":
        # Authorization 存在但格式错 → 显式抛(防 iOS 升级中状态混乱)
        raise JWTMalformedError(
            message=f"Authorization header 格式错(期望 'Bearer <jwt>',实际 '{authorization[:30]}...')"
        )

    token = parts[1].strip()
    return extract_user_id(token)  # 验签失败会抛 JWTExpiredError 等


async def require_authenticated_user(
    authorization: str | None = Header(default=None),
) -> str:
    """强制要求登录(返 user.id,无 Authorization 或验签失败 → 401)。

    用于未来需要强制登录的路由(本 PR 不用,/api/interpret 和 /api/entitlement/redeem
    仍兼容老 iOS 客户端)。
    """
    user_id = await get_current_user_id(authorization)
    if user_id is None:
        raise JWTMalformedError(message="此接口要求登录,缺 Authorization header")
    return user_id
