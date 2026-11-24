import Foundation

/// DELETE /api/auth/account 请求(2026-11-24,Apple 5.1.1(v))。
///
/// Apple 账号必带 `appleAuthorizationCode`:删号前 iOS 先让用户重新
/// Sign in with Apple 拿新鲜一次性 code,后端换 token → 验归属 sub →
/// 吊销后执行删除。Google 账号(休眠态,UI 已只留 SIWA)无需。
struct DeleteAccountRequest: Codable, Sendable {
    let appleAuthorizationCode: String?

    enum CodingKeys: String, CodingKey {
        case appleAuthorizationCode = "apple_authorization_code"
    }
}

/// DELETE /api/auth/account 响应。
struct DeleteAccountResponse: Codable, Sendable {
    let deleted: Bool
    let userIdPrefix: String
    let tables: [String: Int]

    enum CodingKeys: String, CodingKey {
        case deleted
        case userIdPrefix = "user_id_prefix"
        case tables
    }
}
