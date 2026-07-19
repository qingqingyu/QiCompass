import Foundation
import SwiftUI
import SwiftData

/// App 级依赖注入容器。
/// 持有 ModelContainer + APIClient + 深度解析编排链路(store/counter/orchestrator),
/// 通过 EnvironmentKey 注入 View 树。
@MainActor
final class AppEnvironment: ObservableObject {
    let modelContainer: ModelContainer
    let apiClient: APIClient
    let useMockClient: Bool

    // 深度解析编排链路(方案 §六 步骤 13 装配)
    let chartSnapshotStore: ChartSnapshotStore
    let userSnapshotLinkStore: UserSnapshotLinkStore
    let interpretationCacheStore: InterpretationCacheStore
    let aiIdentityResolver: AIIdentityResolver
    let dailyReadCounter: DailyReadCounter
    let deepAnalysisOrchestrator: DeepAnalysisOrchestrator

    /// 用户从哪个 Tab 的 CTA 切到深度解析,完成后自动切回该 Tab(nil = 不切回)。
    /// 当前仅合盘空态 CTA 触发时设值;DeepAnalysisViewModel 完成后消费并清零。
    /// 每日运势空态 v1 无 CTA,故未接入(后续若加 CTA 在 DailyFortuneView 设值即可)。
    var pendingReturnTab: RootTabView.Tab?

    // 每日运势编排链路(slice 6 装配,与深度解析共享 chartStore/interpretStore/counter)
    let dailyFortuneSnapshotStore: DailyFortuneSnapshotStore
    let dailyFortuneOrchestrator: DailyFortuneOrchestrator

    // 合盘编排链路(slice 7 装配,共享 chartStore/interpretStore/counter)
    let compatibilitySnapshotStore: CompatibilitySnapshotStore
    let compatibilityOrchestrator: CompatibilityOrchestrator

    // M3a 新增:付费授权链路
    let entitlementStore: EntitlementStore
    let purchaseManager: PurchaseManager

    init(modelContainer: ModelContainer, apiClient: APIClient, useMockClient: Bool) {
        // 规则 2:函数入口日志。AppEnvironment 装配是启动关键路径,失败会让整个 App 不可用。
        AppLogger.app.info("AppEnvironment.init 开始 useMockClient=\(useMockClient, privacy: .public)")
        self.modelContainer = modelContainer
        self.apiClient = apiClient
        self.useMockClient = useMockClient

        let context = modelContainer.mainContext
        let chartStore = ChartSnapshotStore(context: context)
        let userLinkStore = UserSnapshotLinkStore(context: context)
        let interpretStore = InterpretationCacheStore(context: context)
        let identityResolver = AIIdentityResolver(apiClient: apiClient)
        let counter = DailyReadCounter()
        self.chartSnapshotStore = chartStore
        self.userSnapshotLinkStore = userLinkStore
        self.interpretationCacheStore = interpretStore
        self.aiIdentityResolver = identityResolver
        self.dailyReadCounter = counter
        self.deepAnalysisOrchestrator = DeepAnalysisOrchestrator(
            apiClient: apiClient,
            chartStore: chartStore,
            interpretStore: interpretStore,
            counter: counter,
            aiIdentityResolver: identityResolver,
            userLinkStore: userLinkStore
        )
        // slice 6 装配:每日运势复用 chartStore/interpretStore/counter(决策 §3.8)
        let dailyStore = DailyFortuneSnapshotStore(context: context)
        self.dailyFortuneSnapshotStore = dailyStore
        self.dailyFortuneOrchestrator = DailyFortuneOrchestrator(
            apiClient: apiClient,
            dailyStore: dailyStore,
            interpretStore: interpretStore,
            chartStore: chartStore,
            counter: counter,
            aiIdentityResolver: identityResolver
        )
        // slice 7 装配:合盘独享 compatibilityStore,共享 chartStore(隐式落地 B)/
        // interpretStore/counter。三模块共用 DailyReadCounter 的每日 10 次全局池。
        let compatibilityStore = CompatibilitySnapshotStore(context: context)
        self.compatibilitySnapshotStore = compatibilityStore
        self.compatibilityOrchestrator = CompatibilityOrchestrator(
            apiClient: apiClient,
            compatibilityStore: compatibilityStore,
            chartStore: chartStore,
            interpretStore: interpretStore,
            counter: counter,
            aiIdentityResolver: identityResolver
        )
        // M3a 装配:EntitlementStore(共享 modelContext)+ PurchaseManager(Mock 模式)
        let entitlementStore = EntitlementStore(modelContext: context)
        self.entitlementStore = entitlementStore
        self.purchaseManager = PurchaseManager(
            entitlementStore: entitlementStore,
            apiClient: apiClient
        )
        AppLogger.app.info("AppEnvironment.init 完成(orchestrator + store 全部装配)")
    }

    /// 从 Info.plist 读取是否使用 MockAPIClient(默认 NO = 连真后端)。
    /// Debug/Release 均可通过 build setting USE_MOCK_API_CLIENT 覆盖为 YES 切回 Mock。
    static func useMockAPIClient() -> Bool {
        let raw = Bundle.main.object(forInfoDictionaryKey: "UseMockAPIClient") as? String ?? "NO"
        return raw.uppercased() == "YES"
    }

    /// 从 Info.plist 读取 BackendBaseURL(Debug: localhost HTTP / Release: 生产域名)。
    static func backendBaseURL() -> URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "BackendBaseURL") as? String
            ?? "http://localhost:8000"
        guard let url = URL(string: raw) else {
            // 不吞错:配置非法时 fatal,暴露问题而非静默用默认值
            // fatal 前打 error 日志(fatalError 只输出 stderr,无 subsystem 不便过滤)
            AppLogger.app.error("BackendBaseURL 非法 raw=\(raw, privacy: .public)")
            fatalError("BackendBaseURL 非法: \(raw)")
        }
        return url
    }
}
