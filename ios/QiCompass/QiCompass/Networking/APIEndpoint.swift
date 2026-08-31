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
    /// S3:触发/查询插画生成状态(POST,同 daily-fortune 请求体)
    case dailyFortuneImage
    /// S3:取插画内容(GET,query 参数经 url(base:) 构造)
    case dailyFortuneImageContent(chartHash: String, targetDate: String)
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
        case .dailyFortuneImage: return "/api/bazi/daily-fortune/image"
        case .dailyFortuneImageContent: return "/api/bazi/daily-fortune/image/content"
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
        case .dailyFortuneImageContent: return "GET"
        default:                 return "POST"
        }
    }

    /// 完整 URL。带 query 的端点(content)用 URLComponents 构造——
    /// `appendingPathComponent` 会把 "?" 编码进 path,不能走那条路。
    func url(base: URL) -> URL {
        switch self {
        case .dailyFortuneImageContent(let chartHash, let targetDate):
            guard var comps = URLComponents(
                url: base.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            ) else {
                preconditionFailure("dailyFortuneImageContent URL 构造失败 base=\(base)")
            }
            comps.queryItems = [
                URLQueryItem(name: "chart_hash", value: chartHash),
                URLQueryItem(name: "target_date", value: targetDate),
            ]
            guard let url = comps.url else {
                preconditionFailure(
                    "dailyFortuneImageContent query URL 构造失败 hash=\(chartHash) date=\(targetDate)"
                )
            }
            return url
        default:
            return base.appendingPathComponent(path)
        }
    }
}

