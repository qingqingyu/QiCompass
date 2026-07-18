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
        AppLogger.app.info("QiCompassApp.init 开始")
        let container: ModelContainer
        do {
            container = try ModelContainerFactory.make()
            AppLogger.app.info("ModelContainer 构造成功")
        } catch {
            // 不吞错:ModelContainer 构造失败直接 fatal(启动期,无降级路径)
            // fatal 前打 error 日志,让 os.Logger / Console.app 能捞到结构化记录
            // (fatalError 只输出到 stderr,无 subsystem/category 不便过滤)
            AppLogger.app.error("ModelContainer 构造失败 error=\(String(describing: error), privacy: .public)")
            fatalError("ModelContainer 构造失败: \(error)")
        }
        let useMock = AppEnvironment.useMockAPIClient()
        AppLogger.app.info("APIClient 选型 useMock=\(useMock, privacy: .public)")
        let client: APIClient = useMock
            ? MockAPIClient()
            : LiveAPIClient(baseURL: AppEnvironment.backendBaseURL())
        if useMock {
            AppLogger.app.info("APIClient=MockAPIClient(脚手架占位)")
        } else {
            AppLogger.app.info("APIClient=LiveAPIClient base_url=\(AppEnvironment.backendBaseURL().absoluteString, privacy: .public)")
        }
        _env = StateObject(wrappedValue: AppEnvironment(
            modelContainer: container, apiClient: client, useMockClient: useMock
        ))
        AppLogger.app.info("QiCompassApp.init 完成 mock_client=\(useMock, privacy: .public) base_url=\(AppEnvironment.backendBaseURL().absoluteString, privacy: .public)")
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(env)
                .modelContainer(env.modelContainer)
        }
    }
}
