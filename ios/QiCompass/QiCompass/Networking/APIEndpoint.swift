import Foundation

/// API 端点路由(7 个端点)。
///
/// 后端已实现:`/api/health`、`/api/bazi/calculate`、`/api/bazi/compatibility`、
/// `/api/bazi/daily-fortune`、`/api/interpret`、`/api/entitlement/redeem`(M2b)、
/// `/api/auth/sign-in`(PR2.5)、
/// `/api/webhooks/appstore`(M2c,Apple 调,iOS 不调)
enum APIEndpoint: Sendable {
    case health
    case baziCalculate
    case compatibility
    case dailyFortune
    case interpret
    case entitlementRedeem  // M3a 新增
    case authSignIn          // PR2.5 新增(Apple identity_token → 自家 JWT)

    var path: String {
        switch self {
        case .health:            return "/api/health"
        case .baziCalculate:     return "/api/bazi/calculate"
        case .compatibility:     return "/api/bazi/compatibility"
        case .dailyFortune:      return "/api/bazi/daily-fortune"
        case .interpret:         return "/api/interpret"
        case .entitlementRedeem: return "/api/entitlement/redeem"
        case .authSignIn:        return "/api/auth/sign-in"
        }
    }

    var method: String {
        switch self {
        case .health:            return "GET"
        default:                 return "POST"
        }
    }
}

