"""FastAPI Depends:从 Authorization header 验 JWT 拿 user_id(PR2.5)。

策略(对齐 plan "entitlement 加 nullable user_id + 兜底 user_local_id"):
- 有 Authorization: Bearer <jwt> → 验签 → 返 user.id(str)
- 无 Authorization → 返 None(老 iOS 客户端兼容,继续走 user_local_id 模式)

调用方(interpret.py / entitlement.py)把 user_id 传给 store:
- store.get_active(user_id=user_id, user_local_id=req.user_local_id)
- store 优先 user_id 查,兜底 user_local_id
"""

from __future__ import annotations

from fastapi import Header, Request

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
    request: Request = None,  # type: ignore[assignment]
) -> str:
    """强制要求登录(返 user.id,无 Authorization 或验签失败 → 401)。

    2026-11-24 账号删除加固:JWT 验签后**再核验账号存在**(user 表查无
    此行 → 401)。删号后的残留 JWT 密码学上仍有效,但强登录路由
    (/api/entitlement 列表、/api/auth/account)全部拒绝——可选登录路由
    (get_current_user_id → None 兜底)不加此查询(每请求一查的成本
    不值得;残余写面 = 重建幽灵配额桶,低危害,见设计文档 §2.1)。
    """
    user_id = await get_current_user_id(authorization)
    if user_id is None:
        raise JWTMalformedError(message="此接口要求登录,缺 Authorization header")
    user_store = getattr(request.app.state, "user_store", None)
    if user_store is not None:
        from fastapi.concurrency import run_in_threadpool
        exists = await run_in_threadpool(user_store.user_exists, user_id)
        if not exists:
            raise JWTMalformedError(
                message="账号已删除或不存在(残留登录凭证被拒绝,请重新登录)")
    return user_id
