import Foundation

/// GET /api/health 响应。
/// 对齐 backend/app/api/health.py:{"status":"ok","lunar_python_version":"1.4.8","model":"bazi-calculate-v1"}
struct HealthResponse: Codable, Equatable, Sendable {
    let status: String
    let lunarPythonVersion: String
    let model: String

    enum CodingKeys: String, CodingKey {
        case status
        case lunarPythonVersion = "lunar_python_version"
        case model
    }
}
