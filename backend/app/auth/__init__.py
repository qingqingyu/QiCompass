"""账号系统模块(PR2.5)。

子模块:
- `jwt_service`:自家 JWT 签发/验证(HS256)
- `apple_signin`:Sign in with Apple ID Token 验证(Apple 公钥 + JWT 验签)
- `user_store`:User 表 CRUD
- `dependencies`:FastAPI Depends(get_current_user_id)
"""
