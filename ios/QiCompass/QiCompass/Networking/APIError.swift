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
            return String(format: String(localized: "后端错误[%lld]: %@%@"), code, msg, reqId.map { "(request_id=\($0))" } ?? "")
        }
    }
}
