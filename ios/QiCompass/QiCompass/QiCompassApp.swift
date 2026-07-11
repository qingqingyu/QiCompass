import SwiftUI
import SwiftData

/// @main 入口:ModelContainer 装配 + 默认 Mock APIClient。
//
// 脚手架阶段 Debug 默认用 MockAPIClient(后端未运行时三 Tab 仍有可调用路径)。
// 可通过 Debug 面板切换 Live/Mock。正式 slice 替换为按 Build Configuration 选择。
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
        // Debug 默认 Mock,Release 用 Live
        #if DEBUG
        let useMock = true
        #else
        let useMock = false
        #endif
        let client: APIClient = useMock
            ? MockAPIClient()
            : LiveAPIClient(baseURL: AppEnvironment.backendBaseURL())
        _env = StateObject(wrappedValue: AppEnvironment(
            modelContainer: container, apiClient: client, useMockClient: useMock
        ))
        AppLogger.app.info("QiCompass 启动 mock_client=\(useMock)")
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(env)
                .modelContainer(env.modelContainer)
        }
    }
}
