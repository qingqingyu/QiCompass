import SwiftUI
import SwiftData

/// Tab 2:合盘。状态机驱动(D2 五态)。
///
/// 状态:
/// - .loading → 命盘列表加载中
/// - .empty → 0 存档,引导去深度解析
/// - .configuring → 配置态(A/B/context)
/// - .computing → 调 /api/bazi/compatibility 中
/// - .resultReady(response, interpretState) → 结果 + AI 子状态
/// - .failed(msg) → 错误态
struct CompatibilityView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var vm: CompatibilityViewModel?

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                content
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .toolbar {
                if case .resultReady = vm?.state {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回修改") { vm?.backToConfig() }
                            .foregroundStyle(BaziTheme.cinnabar)
                    }
                }
            }
        }
        .task {
            if vm == nil {
                vm = CompatibilityViewModel(
                    orchestrator: env.compatibilityOrchestrator,
                    chartStore: env.chartSnapshotStore,
                    compatibilityStore: env.compatibilitySnapshotStore,
                    modelContext: env.modelContainer.mainContext
                )
            }
            vm?.loadArchivedCharts()
        }
    }

    private var navigationTitle: String {
        switch vm?.state {
        case .resultReady: return "合盘结果"
        default:           return "合盘"
        }
    }

    @ViewBuilder
    private var content: some View {
        if let vm {
            switch vm.state {
            case .loading:
                LoadingStateView(title: "准备中…")
            case .empty:
                CompatibilityEmptyView {
                    // 设返回标志,深度解析完成后 DeepAnalysisView 据此切回合盘
                    env.pendingReturnTab = .compatibility
                    NotificationCenter.default.post(
                        name: .switchTab, object: nil,
                        userInfo: ["tab": RootTabView.Tab.deepAnalysis.switchKey]
                    )
                }
            case .configuring:
                CompatibilityConfigView(vm: vm) {
                    vm.compute()
                }
            case .computing:
                LoadingStateView(title: "推演合盘中…")
            case .resultReady(let response, let interpretState):
                if let chartA = vm.archivedCharts[safe: vm.selectedChartAIndex]?.snapshot,
                   let chartB = vm.bChartSnapshot {
                    CompatibilityMainView(
                        vm: vm,
                        response: response,
                        interpretState: interpretState,
                        chartASnapshot: chartA,
                        chartBSnapshot: chartB,
                        onBackToConfig: { vm.backToConfig() },
                        onGenerateInterpret: { vm.generateInterpretation() }
                    )
                } else {
                    ErrorStateView(
                        userFacingError: .generic(message: "命盘数据读取失败"),
                        retry: { vm.backToConfig() }
                    )
                }
            case .failed(let userError):
                ErrorStateView(
                    userFacingError: userError,
                    retry: { vm.loadArchivedCharts() }
                )
            }
        } else {
            ProgressView().tint(BaziTheme.cinnabar)
        }
    }
}

// MARK: - switchTab Notification

extension Notification.Name {
    /// 切 Tab 通知(rawValue 唯一命名,决策 D1 / 风险 #4)。
    /// userInfo: ["tab": "deepAnalysis" / "compatibility" / "dailyFortune"]
    static let switchTab = Notification.Name("com.qicompass.switchTab")
}
