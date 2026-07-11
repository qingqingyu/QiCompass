import Foundation

/// API 端点路由(5 个端点)。
///
/// 后端已实现:`/api/health`、`/api/bazi/calculate`、`/api/interpret`
/// 后端未实现(stub):`/api/bazi/compatibility`、`/api/bazi/daily-fortune`
enum APIEndpoint: Sendable {
    case health
    case baziCalculate
    case compatibility
    case dailyFortune
    case interpret

    var path: String {
        switch self {
        case .health:            return "/api/health"
        case .baziCalculate:     return "/api/bazi/calculate"
        case .compatibility:     return "/api/bazi/compatibility"
        case .dailyFortune:      return "/api/bazi/daily-fortune"
        case .interpret:         return "/api/interpret"
        }
    }

    var method: String {
        switch self {
        case .health:            return "GET"
        default:                 return "POST"
        }
    }
}
