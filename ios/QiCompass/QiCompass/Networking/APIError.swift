import Foundation

/// API 错误枚举(错误显式传播:不吞异常,该报错就报错)。
///
/// 对齐后端 `{error:{code,message,request_id,content_hash}}` 结构化错误响应。
enum APIError: Error, LocalizedError {
    case networkError(URLError)
    case httpError(statusCode: Int, body: String?)
    case decodingError(Error)
    case encodingError(Error)
    case backendError(code: String, message: String, requestId: String?)

    var errorDescription: String? {
        switch self {
        case .networkError(let e):
            return String(format: String(localized: "网络错误: %@"), e.localizedDescription)
        case .httpError(let code, let body):
            return "HTTP \(code)\(body.map { ": \($0)" } ?? "")"
        case .decodingError(let e):
            return String(format: String(localized: "解码失败: %@"), e.localizedDescription)
        case .encodingError(let e):
            return String(format: String(localized: "编码失败: %@"), e.localizedDescription)
        case .backendError(let code, let msg, let reqId):
            // 2026-09-28 修复:code 是 String(如 ENTITLEMENT_ERROR),%lld 会把
            // 指针当 Int64 读出乱码数字;改 %@。
            return String(format: String(localized: "后端错误[%@]: %@%@"), code, msg, reqId.map { "(request_id=\($0))" } ?? "")
        }
    }
}

extension APIError {
    /// 后端 409 STALE_SOURCE 判定(翻译链 L4/F5/F4 降级入口)。
    ///
    /// 2026-10-07 review 收口:此前 DeepAnalysisViewModel /
    /// DailyFortuneOrchestrator / CompatibilityViewModel 三处各写一份同款
    /// 判定(其中 compat 是内联 if-case)——同一错误语义三种表述,漂移只是
    /// 时间问题。收口到错误类型的单一事实源,三处消费方全部改走这里。
    static func isStaleSource(_ error: Error) -> Bool {
        guard case .backendError(let code, _, _)? = error as? APIError else {
            return false
        }
        return code == "STALE_SOURCE"
    }

    /// 后端 403 CONTEXT_TOKEN_* 判定(2026-10-07 P0 收口):老快照无 token
    /// (CONTEXT_TOKEN_REQUIRED)或 secret 已轮换/伪造(CONTEXT_TOKEN_INVALID)。
    /// 二者都需重新排盘取新 token 才能恢复,用户可见文案应给「重新排盘」
    /// 而非通用「解读失败」(否则用户不知道要重新录入出生信息)。
    static func isContextTokenError(_ error: Error) -> Bool {
        guard case .backendError(let code, _, _)? = error as? APIError else {
            return false
        }
        return code == "CONTEXT_TOKEN_REQUIRED" || code == "CONTEXT_TOKEN_INVALID"
    }
}
