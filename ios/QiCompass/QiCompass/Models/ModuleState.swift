import Foundation

/// v1 prompt 系统单模块状态(Stage 7a 引入)。
///
/// 与现有 `InterpretState`(单文本态,服务 bazi_deep_free/paid / compatibility /
/// daily_fortune 老路径)**并存**:现有不动给合盘/每日运势继续用,本 enum 仅服务
/// DeepAnalysisViewModel 的 `moduleStates: [ModuleID: ModuleState]`。
///
/// 设计要点:
/// - 每个 module 独立状态机,失败可单独重试(不影响其他模块)
/// - M0 失败 → 整条链中断(后续 M1-M7 缺 parent_fingerprint 无法跑)
/// - 付费模块未解锁显示 `.locked`,购买成功后自动转 `.pending`(由 VM 触发)
/// - M4/M5 需用户输入时显 `.needsInput`,Stage 8 输入 sheet 提交后转 `.pending`
enum ModuleState: Equatable {
    /// 未请求(初始态 / 上游依赖未完成 / 用户未点击)
    case pending
    /// 请求中(已发起 /api/interpret 调用)
    case fetching
    /// 成功(text 是 LLM 返回的 JSON 字符串,Stage 7c 解析关键字段渲染)
    case ok(text: String, cached: Bool)
    /// 失败,可单独重试(不污染其他模块状态)
    case failed(message: String)
    /// 付费模块未解锁(显示锁标 + 解锁 CTA,触发 PaywallView)
    case locked
    /// M4/M5 需要用户输入(显示"提供输入"CTA,Stage 8 弹 sheet)
    case needsInput
    /// context_token 缺失/失效(2026-10-08):老快照盘生成/翻译必 403,重试
    /// 无意义——章节页渲染「重新排盘」出口而非「重试本章」(落态入口:
    /// DeepAnalysisViewModel 通用 catch 的 APIError.isContextTokenError)。
    /// failedToken(十六轮 #4):失败当时所用的 v1 族 token——hydrate 重入时
    /// 只有当前 token ≠ failedToken(已被重排翻新)才降级 .pending 重试;
    /// 仍同枚则保持失效态,不白发注定 403 的请求、不抹掉「重新排盘」指引。
    /// nil = 请求未携带 token(老快照无 contextTokens,403 由缺失引起)。
    case contextTokenExpired(failedToken: String?)
    /// 服务端免费配额 429 QUOTA_EXCEEDED(2026-10-08 外评 #6):与本地 10 次/日
    /// 池不同源(共享 IP/多设备会把服务端池先耗尽),重试本章/回前台自动续跑
    /// 只会反复 429——达限态禁重试,章节页渲染倒计时(UTC 零点换日,与
    /// InterpretState.dailyLimitReached 同口径),不进自动续跑清单(落态入口:
    /// DeepAnalysisViewModel 通用 catch 的 UserFacingError.dailyLimitReached)。
    case dailyLimitReached(nextReset: Date)

    /// 是否终态(可响应用户操作)。pending/fetching 是非终态。
    var isTerminal: Bool {
        switch self {
        case .pending, .fetching: return false
        case .ok, .failed, .locked, .needsInput, .contextTokenExpired,
             .dailyLimitReached:
            return true
        }
    }

    /// 是否成功态(用于链式调用判断:上游 ok 才能跑下游)。
    var isOk: Bool {
        if case .ok = self { return true }
        return false
    }
}
