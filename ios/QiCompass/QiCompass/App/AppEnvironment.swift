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
    let interpretationCacheStore: InterpretationCacheStore
    let dailyReadCounter: DailyReadCounter
    let deepAnalysisOrchestrator: DeepAnalysisOrchestrator

    // 每日运势编排链路(slice 6 装配,与深度解析共享 chartStore/interpretStore/counter)
    let dailyFortuneSnapshotStore: DailyFortuneSnapshotStore
    let dailyFortuneOrchestrator: DailyFortuneOrchestrator

    // 合盘编排链路(slice 7 装配,共享 chartStore/interpretStore/counter)
    let compatibilitySnapshotStore: CompatibilitySnapshotStore
    let compatibilityOrchestrator: CompatibilityOrchestrator

    init(modelContainer: ModelContainer, apiClient: APIClient, useMockClient: Bool) {
        self.modelContainer = modelContainer
        self.apiClient = apiClient
        self.useMockClient = useMockClient

        let context = modelContainer.mainContext
        let chartStore = ChartSnapshotStore(context: context)
        let interpretStore = InterpretationCacheStore(context: context)
        let counter = DailyReadCounter()
        self.chartSnapshotStore = chartStore
        self.interpretationCacheStore = interpretStore
        self.dailyReadCounter = counter
        self.deepAnalysisOrchestrator = DeepAnalysisOrchestrator(
            apiClient: apiClient,
            chartStore: chartStore,
            interpretStore: interpretStore,
            counter: counter
        )
        // slice 6 装配:每日运势复用 chartStore/interpretStore/counter(决策 §3.8)
        let dailyStore = DailyFortuneSnapshotStore(context: context)
        self.dailyFortuneSnapshotStore = dailyStore
        self.dailyFortuneOrchestrator = DailyFortuneOrchestrator(
            apiClient: apiClient,
            dailyStore: dailyStore,
            interpretStore: interpretStore,
            chartStore: chartStore,
            counter: counter
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
            counter: counter
        )
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
