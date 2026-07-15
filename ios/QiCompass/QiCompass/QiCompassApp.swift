import SwiftUI
import SwiftData

/// @main 入口:ModelContainer 装配 + APIClient(Live/Mock 由 Info.plist 配置)。
//
// USE_MOCK_API_CLIENT build setting 控制:默认 NO(连真后端),
// 后端未运行时可改 YES 切回 MockAPIClient 占位。
@main
struct QiCompassApp: App {
    @StateObject private var env: AppEnvironment

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainerFactory.make()
        } catch {
            // 不吞错:ModelContainer 构造失败直接 fatal(启动期,无降级路径)
            fatalError("ModelContainer 构造失败: \(error)")
        }
        let useMock = AppEnvironment.useMockAPIClient()
        let client: APIClient = useMock
            ? MockAPIClient()
            : LiveAPIClient(baseURL: AppEnvironment.backendBaseURL())
        _env = StateObject(wrappedValue: AppEnvironment(
            modelContainer: container, apiClient: client, useMockClient: useMock
        ))
        AppLogger.app.info("QiCompass 启动 mock_client=\(useMock) base_url=\(AppEnvironment.backendBaseURL().absoluteString, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(env)
                .modelContainer(env.modelContainer)
        }
    }
}
