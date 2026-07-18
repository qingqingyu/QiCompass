import Foundation

/// API 端点路由(6 个端点)。
///
/// 后端已实现:`/api/health`、`/api/bazi/calculate`、`/api/bazi/compatibility`、
/// `/api/bazi/daily-fortune`、`/api/interpret`、`/api/entitlement/redeem`(M2b)、
/// `/api/webhooks/appstore`(M2c,Apple 调,iOS 不调)
enum APIEndpoint: Sendable {
    case health
    case baziCalculate
    case compatibility
    case dailyFortune
    case interpret
    case entitlementRedeem  // M3a 新增

    var path: String {
        switch self {
        case .health:            return "/api/health"
        case .baziCalculate:     return "/api/bazi/calculate"
        case .compatibility:     return "/api/bazi/compatibility"
        case .dailyFortune:      return "/api/bazi/daily-fortune"
        case .interpret:         return "/api/interpret"
        case .entitlementRedeem: return "/api/entitlement/redeem"
        }
    }

    var method: String {
        switch self {
        case .health:            return "GET"
        default:                 return "POST"
        }
    }
}

