import Foundation

/// errorDescription 是**用户可见文案**(2026-08-16:代码性错误不进 UI)。
/// provider/model 留在 associated value,resolve() 抛错前已记
/// aiIdentity.resolve.invalid_identity 日志。
enum AIIdentityError: Error, LocalizedError {
    case invalidHealthIdentity(provider: String, model: String)

    var errorDescription: String? {
        switch self {
        case .invalidHealthIdentity:
            return "解读服务暂时不可用,请稍后重试"
        }
    }
}

/// 每次准备接受本地 AI 缓存前,从 no-store health 获取当前 provider/model。
/// health 失败必须向上抛,不能使用上次身份或 legacy 缓存。
@MainActor
final class AIIdentityResolver {
    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    func resolve() async throws -> AIIdentity {
        // 规则 2:函数入口日志。AI 身份解析是缓存写入前置,失败必须可追溯。
        AppLogger.networking.info("aiIdentity.resolve.start")
        let start = ContinuousClock().now
        do {
            let health = try await apiClient.health()
            let provider = health.aiProvider.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = health.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["anthropic", "openai"].contains(provider), !model.isEmpty else {
                // 规则 1:抛错前打 error 日志(原 throw 直接走外层 catch,这里补具体原因)
                AppLogger.networking.error(
                    "aiIdentity.resolve.invalid_identity provider=\(health.aiProvider, privacy: .public) model=\(health.aiModel, privacy: .public)"
                )
                throw AIIdentityError.invalidHealthIdentity(
                    provider: health.aiProvider,
                    model: health.aiModel
                )
            }
            let elapsed = start.duration(to: .now)
            AppLogger.networking.info(
                "aiIdentity.resolve.ok provider=\(provider, privacy: .public) model=\(model, privacy: .public) elapsed=\(elapsed)"
            )
            return AIIdentity(provider: provider, model: model)
        } catch {
            let elapsed = start.duration(to: .now)
            AppLogger.networking.error(
                "aiIdentity.resolve.failed elapsed=\(elapsed) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }
}
