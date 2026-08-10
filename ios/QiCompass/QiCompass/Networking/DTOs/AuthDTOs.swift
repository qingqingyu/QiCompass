import Foundation

/// POST /api/auth/sign-in 请求体(PR2.5)。
struct SignInRequest: Codable, Sendable {
    let identityToken: String

    enum CodingKeys: String, CodingKey {
        case identityToken = "identity_token"
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
