import Foundation

/// POST /api/auth/sign-in 请求体(PR2.5 + Slice 1 加 userLocalId)。
struct SignInRequest: Codable, Sendable {
    let identityToken: String
    /// 客户端 lazy UUID,登录时传给后端用于 backfill 老 entitlement 的 user_id。
    /// nil 表示老 iOS 客户端不传(向后兼容,后端跳过 backfill)。
    let userLocalId: String?

    enum CodingKeys: String, CodingKey {
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
