import Foundation

/// POST /api/auth/sign-in 请求体(PR2.5 + Slice 1 加 userLocalId + 2026-08-16 加 provider)。
struct SignInRequest: Codable, Sendable {
    /// 登录方式("apple" / "google",AuthProvider.rawValue)。显式传值,
    /// 后端 Literal["apple","google"] 校验;老后端(无 provider 字段)按
    /// Pydantic 默认忽略未知字段,会当 apple 处理 — 新版客户端发 google
    /// 必须搭配已支持 provider 的新后端,否则 Apple 验签失败 401(不静默误判)。
    let provider: String
    let identityToken: String
    /// 客户端 lazy UUID,登录时传给后端用于 backfill 老 entitlement 的 user_id。
    /// nil 表示老 iOS 客户端不传(向后兼容,后端跳过 backfill)。
    let userLocalId: String?

    enum CodingKeys: String, CodingKey {
        case provider
        case identityToken = "identity_token"
        case userLocalId = "user_local_id"
    }
}

/// POST /api/auth/sign-in 响应体(PR2.5)。
struct SignInResponse: Codable, Sendable {
    let accessToken: String
    let tokenType: String  // "Bearer"
    let userId: String
    let expiresAt: String  // ISO 8601 UTC

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case userId = "user_id"
        case expiresAt = "expires_at"
    }
}
