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
        // L1/F2(2026-10-01 语言切换走查):进程启动第一件事冻结生效语言快照
        // ——任何后续代码读 AppLanguage.current 都锚定到本次启动的档位,
        // 重启前切换设置项不再半生效(界面术语/header/缓存键三者一致)。
        AppLanguage.freezeLaunchSnapshot()
        AppLogger.app.info("QiCompassApp.init 开始")
        // S1(2026-10-18):楷体/宋体是系统可下载字体,真机默认不带(探测实证
        // 8 个名全 false)——启动即按需下载,完成后 FontAvailability 通知刷新
        BaziFont.ensureDownloadableFonts()
        // 整链完成通知 delegate(方案二,2026-10-11):启动即挂——冷启动由
        // 通知点入的场景,didReceive 要在launch 完成前就绪才不丢
        _ = ChainCompletionNotifier.shared
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
