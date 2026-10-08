import Foundation

/// GET /api/health 响应。
/// `model` 仍是确定性排盘模型;AI 身份由 `aiProvider/aiModel` 单独表示。
struct HealthResponse: Codable, Equatable, Sendable {
    let status: String
    let lunarPythonVersion: String
    let model: String
    let aiProvider: String
    let aiModel: String
    /// 各 module 当前 prompt 版本(module 名 → 版本,2026-10-08 外评 #4)。
    /// `var` + 默认 nil:老后端响应无此字段(decodeIfPresent)与既有测试
    /// 直构 HealthResponse 的调用点都不破;nil = 版本未知,读缓存不设版本上限。
    var promptVersions: [String: Int]? = nil

    enum CodingKeys: String, CodingKey {
        case status
        case lunarPythonVersion = "lunar_python_version"
        case model
        case aiProvider = "ai_provider"
        case aiModel = "ai_model"
        case promptVersions = "prompt_versions"
    }
}

struct AIIdentity: Equatable, Sendable {
    let provider: String
    let model: String
    /// 各 module 服务端当前 prompt 版本(来自 no-store health,随身份同源
    /// 取得,2026-10-08 外评 #4)。空字典 = 版本未知(老后端),读缓存不设
    /// 版本过滤;非空时本地行只认服务端当前版本——prompt bump 后客户端
    /// 24h 内的旧版行不再命中(否则旧解读照常展示并被写进新合盘快照,
    /// bump 在客户端失防)。
    var promptVersions: [String: Int] = [:]

    init(provider: String, model: String, promptVersions: [String: Int] = [:]) {
        self.provider = provider
        self.model = model
        self.promptVersions = promptVersions
    }
}
