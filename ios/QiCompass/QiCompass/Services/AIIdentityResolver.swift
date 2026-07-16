import Foundation

enum AIIdentityError: Error, LocalizedError {
    case invalidHealthIdentity(provider: String, model: String)

    var errorDescription: String? {
        switch self {
        case .invalidHealthIdentity(let provider, let model):
            return "AI 服务身份无效(provider=\(provider), model=\(model))"
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
        let start = ContinuousClock().now
        do {
            let health = try await apiClient.health()
            let provider = health.aiProvider.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = health.aiModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["anthropic", "openai"].contains(provider), !model.isEmpty else {
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
