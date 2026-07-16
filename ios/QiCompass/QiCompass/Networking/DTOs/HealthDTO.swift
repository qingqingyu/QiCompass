import Foundation

/// GET /api/health 响应。
/// `model` 仍是确定性排盘模型;AI 身份由 `aiProvider/aiModel` 单独表示。
struct HealthResponse: Codable, Equatable, Sendable {
    let status: String
    let lunarPythonVersion: String
    let model: String
    let aiProvider: String
    let aiModel: String

    enum CodingKeys: String, CodingKey {
        case status
        case lunarPythonVersion = "lunar_python_version"
        case model
        case aiProvider = "ai_provider"
        case aiModel = "ai_model"
    }
}

struct AIIdentity: Equatable, Sendable {
    let provider: String
    let model: String
}
