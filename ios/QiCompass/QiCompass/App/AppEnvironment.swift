import Foundation
import SwiftUI
import SwiftData

/// App 级依赖注入容器。
/// 持有 ModelContainer + APIClient,通过 EnvironmentKey 注入 View 树。
@MainActor
final class AppEnvironment: ObservableObject {
    let modelContainer: ModelContainer
    let apiClient: APIClient
    let useMockClient: Bool

    init(modelContainer: ModelContainer, apiClient: APIClient, useMockClient: Bool) {
        self.modelContainer = modelContainer
        self.apiClient = apiClient
        self.useMockClient = useMockClient
    }

    /// 从 Info.plist 读取 BackendBaseURL(Debug: localhost HTTP / Release: 生产域名)。
    static func backendBaseURL() -> URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
            ?? "http://localhost:8000"
        guard let url = URL(string: raw) else {
            // 不吞错:配置非法时 fatal,暴露问题而非静默用默认值
            fatalError("BackendBaseURL 非法: \(raw)")
        }
        return url
    }
}
