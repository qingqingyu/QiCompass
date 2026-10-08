import Foundation

/// 用户可见错误分类(三模块共享,方案 §D5)。
///
/// 设计:stage-based + URLError code 结合。
/// - 先按调用阶段判(排盘 vs AI)
/// - 再用 URLError code 细分网络错误类型
/// - **不依赖**后端错误码命名做主分类
///
/// 日志策略:保留原始 error 对象 + 关键上下文(orchestrator 各 catch 已写日志,
/// 此处不重复;UI 层只持 UserFacingError 用于渲染)。
enum UserFacingError: Error, Equatable, LocalizedError {
    /// 网络不可用 / 超时 / 连接丢失(URLError code 命中)。
    case networkUnavailable
    /// 排盘库错误(后端 BAZI_CALCULATION_FAILED)或排盘阶段失败。
    case chartFailed(originalDescription: String)
    /// AI 解读阶段失败(命书生成)。
    case interpretFailed(originalDescription: String)
    /// 每日次数达上限。serverPool(2026-10-08 拍板):true = 服务端共享池
    /// 429(登录 user_id/匿名 IP 维度),false = iOS 本地 10/日池(按设备,
    /// 与登录无关)——达限文案据此决定是否引导登录(仅服务端池 + 未登录
    /// 时提示「登录后可获得独立额度」,本地池引导属误导)。
    case dailyLimitReached(nextReset: Date, serverPool: Bool)
    /// context_token 缺失/失效(2026-10-07 P0 收口):老快照无 token 或
    /// secret 已轮换,须重新排盘取新 token。
    case contextTokenExpired
    /// 兜底。
    case generic(message: String)

    /// 调用阶段(决定 stage-based 分类)。
    enum Stage {
        case chart                          // /api/bazi/calculate
        case interpret                      // /api/interpret
        case compatibilityDeterministic     // /api/bazi/compatibility
        case dailyDeterministic             // /api/bazi/daily-fortune
    }

    /// 从底层 error + stage 推导用户可见错误分类。
    /// CancellationError 不映射(VM 自己处理,不应进入 error state)。
    static func from(_ error: Error, stage: Stage) -> UserFacingError {
        // 达上限(三模块统一抛 DeepAnalysisError.dailyLimitReached)
        if let daily = error as? DeepAnalysisError,
           case .dailyLimitReached(let reset, _) = daily {
            return .dailyLimitReached(nextReset: reset, serverPool: false)
        }

        // APIError 包装的 URLError / 裸 URLError → 网络错误
        if Self.isOfflineOrTimeout(error) {
            return .networkUnavailable
        }

        // context_token 缺失/失效(老快照无 token / secret 已轮换)→ 须重新
        // 排盘,任何 stage 都不可当通用失败(否则用户不知要重新录入出生信息)
        if APIError.isContextTokenError(error) {
            return .contextTokenExpired
        }

        // 服务端免费配额 429(QUOTA_EXCEEDED)→ 达限态(禁重试 + 倒计时,
        // 2026-10-08):与本地 10 次/日池不同源(共享 IP / 多设备会把服务端
        // 池先耗尽),通用「解读失败 + 重试」会让用户反复点重试反复 429。
        // nextReset 取下一个 **UTC 零点**(后端 bucket 按 UTC 日,北京时间
        // 08:00 换日)——若显示本地零点,零点后重试仍在同一 UTC 日,会被
        // 当成倒计时骗人。
        if APIError.isQuotaExceeded(error) {
            return .dailyLimitReached(
                nextReset: Self.nextUTCMidnight(), serverPool: true)
        }

        // 后端排盘库错误(stage 决定归类)
        if case .backendError(let code, _, _)? = error as? APIError,
           code == "BAZI_CALCULATION_FAILED" {
            switch stage {
            case .chart, .compatibilityDeterministic, .dailyDeterministic:
                return .chartFailed(originalDescription: error.localizedDescription)
            case .interpret:
                return .interpretFailed(originalDescription: error.localizedDescription)
            }
        }

        // 按 stage 归类剩余错误(默认所有非 interpret 阶段失败都视为排盘类失败)
        switch stage {
        case .interpret:
            return .interpretFailed(originalDescription: error.localizedDescription)
        case .chart, .compatibilityDeterministic, .dailyDeterministic:
            return .chartFailed(originalDescription: error.localizedDescription)
        }
    }

    /// 判 URLError 是否为离线/超时类(用于离线 fallback 与 UI 分类)。
    ///
    /// 注意:不包含 `.cancelled`。URLError.cancelled 通常源于 Task 取消，
    /// 若归为离线会让本应走 CancellationError 路径的取消误触发 fallback UI。
    /// VM 的 catch 链已先 `catch is CancellationError { return }`，
    /// 但 URLSession 把取消包装成 URLError(.cancelled) 时不继承 CancellationError，
    /// 会落到 generic catch；这里显式排除，让取消落到 generic 而非 fallback。
    static func isOffline(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dataNotAllowed,
             .internationalRoamingOff:
            return true
        default:
            return false
        }
    }

    /// 下一个 UTC 零点(服务端免费配额 bucket 的换日界)。
    ///
    /// 固定 gregorian + UTC 日历计算,不受用户本地时区影响;与本地池的
    /// `DailyReadCounter.nextResetDate`(本地日界)刻意不同源——两者对齐的
    /// 是各自配额的真实重置时刻,而非彼此。
    static func nextUTCMidnight(now: Date = .now) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let startOfTomorrow = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        return startOfTomorrow ?? now
    }

    /// Error 级离线/超时判定(单一事实源,2026-10-07 第九轮 review #7 收编
    /// 三份两层解包):APIClient 会把 session URLError 包成
    /// `APIError.networkError` 抛出,裸 URLError 转型只覆盖一层——两层都解。
    /// 4xx/5xx/解码失败不在此列(调用方回落旧值 = 用旧值掩盖真错误,
    /// CLAUDE.md 禁止)。`.cancelled` 亦不在此列(见 isOffline 注释)。
    static func isOfflineOrTimeout(_ error: Error) -> Bool {
        if case .networkError(let urlError)? = error as? APIError {
            return isOffline(urlError)
        }
        if let urlError = error as? URLError {
            return isOffline(urlError)
        }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return L10n.Errors.networkTitle
        case .chartFailed:
            return L10n.Errors.chartTitle
        case .interpretFailed:
            return L10n.Errors.interpretTitle
        case .dailyLimitReached:
            return L10n.Errors.limitTitle
        case .contextTokenExpired:
            return L10n.Errors.contextTokenTitle
        case .generic(let m):
            return m
        }
    }

    /// 二级文案(解释 / 建议)。
    var subtitle: String {
        switch self {
        case .networkUnavailable:
            return L10n.Errors.networkSubtitle
        case .chartFailed:
            return L10n.Errors.chartSubtitle
        case .interpretFailed:
            return L10n.Errors.interpretSubtitle
        case .dailyLimitReached:
            return L10n.Errors.limitSubtitle
        case .contextTokenExpired:
            return L10n.Errors.contextTokenSubtitle
        case .generic(let m):
            return m
        }
    }
}
