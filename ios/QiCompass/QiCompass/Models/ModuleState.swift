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

    /// 是否终态(可响应用户操作)。pending/fetching 是非终态。
    var isTerminal: Bool {
        switch self {
        case .pending, .fetching: return false
        case .ok, .failed, .locked, .needsInput: return true
        }
    }

    /// 是否成功态(用于链式调用判断:上游 ok 才能跑下游)。
    var isOk: Bool {
        if case .ok = self { return true }
        return false
    }
}
