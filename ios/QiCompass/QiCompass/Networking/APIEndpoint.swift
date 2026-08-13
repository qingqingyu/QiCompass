import Foundation

/// API 端点路由。
///
/// 后端已实现:`/api/health`、`/api/bazi/calculate`、`/api/bazi/compatibility`、
/// `/api/bazi/daily-fortune`、`/api/interpret`、`/api/entitlement/redeem`(M2b)、
/// `/api/entitlement/list`(Slice 1 新增,登录后批量同步用)、
/// `/api/auth/sign-in`(PR2.5)、
/// `/api/webhooks/appstore`(M2c,Apple 调,iOS 不调)
enum APIEndpoint: Sendable {
    case health
    case baziCalculate
    case compatibility
    case dailyFortune
    case interpret
    case entitlementRedeem  // M3a 新增
    case entitlementList    // Slice 1 新增(登录后批量同步 entitlement)
    case authSignIn          // PR2.5 新增(Apple identity_token → 自家 JWT)
    case syncPull            // PR3.2 新增(拉云端命盘)
    case syncPush            // PR3.2 新增(上传本地命盘)

    var path: String {
        switch self {
        case .health:            return "/api/health"
        case .baziCalculate:     return "/api/bazi/calculate"
        case .compatibility:     return "/api/bazi/compatibility"
        case .dailyFortune:      return "/api/bazi/daily-fortune"
        case .interpret:         return "/api/interpret"
        case .entitlementRedeem: return "/api/entitlement/redeem"
        case .entitlementList:   return "/api/entitlement/list"
        case .authSignIn:        return "/api/auth/sign-in"
        case .syncPull:          return "/api/sync/pull"
        case .syncPush:          return "/api/sync/push"
        }
    }

    var method: String {
        switch self {
        case .health:            return "GET"
        case .entitlementList:   return "GET"
        default:                 return "POST"
        }
    }
}

