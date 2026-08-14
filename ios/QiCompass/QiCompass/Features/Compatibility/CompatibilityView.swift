import SwiftUI
import SwiftData

/// Tab 2:合盘。状态机驱动(多选改造 + S02 detail 态)。
///
/// 状态:
/// - .loading → 命盘列表加载中
/// - .empty → 0 存档,引导去深度解析
/// - .configuring → 配置态(A 单选 + B 名单 / context)
/// - .computing(completed, total) → 批量确定性合盘中(决策 D3 串行 + i/N 进度)
/// - .list → 结果列表(决策 D9 卡片;D11 纯展示 + toolbar 编辑名单;点卡片进 detail)
/// - .detail(summary, response, interpretState) → 单对详情(S02 新增,复用 CompatibilityMainView)
/// - .failed(msg) → 错误态
struct CompatibilityView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var vm: CompatibilityViewModel?
    @State private var showPaywall = false

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
                if case .list = vm?.state {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("编辑名单") { vm?.backToConfig() }
                            .foregroundStyle(BaziTheme.cinnabar)
                    }
                }
                if case .detail = vm?.state {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回列表") { vm?.closeDetail() }
                            .foregroundStyle(BaziTheme.cinnabar)
                    }
                }
            }
            .sheet(isPresented: $showPaywall) {
                if let compatHash = vm?.lastCompatibilityHashForPaywall {
                    PaywallView(
                        viewModel: PaywallViewModel(
                            module: .compatibility,
                            contentHash: compatHash,
                            purchaseManager: env.purchaseManager,
                            onPurchaseSuccess: {
                                // 购买成功 → dismiss + 重新调该对的解读(决策 D4 按对绑定)
                                showPaywall = false
                                vm?.generateInterpretation()
                            }
                        )
                    )
                }
            }
        }
        .task {
            if vm == nil {
                vm = CompatibilityViewModel(
                    orchestrator: env.compatibilityOrchestrator,
                    chartStore: env.chartSnapshotStore,
                    compatibilityStore: env.compatibilitySnapshotStore,
                    entitlementStore: env.entitlementStore,
                    modelContext: env.modelContainer.mainContext
                )
            }
            vm?.loadArchivedCharts()
            // S06:loadArchivedCharts 完成后恢复名单 + 尝试恢复 list 态
            vm?.restoreRosterStateIfAvailable()
        }
    }

    private var navigationTitle: String {
        switch vm?.state {
        case .list:    return "合盘结果"
        case .detail:  return "合盘结果"
        case .computing: return "推演中"
        default:       return "合盘"
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
            case .computing(let completed, let total):
                LoadingStateView(title: "推演合盘中… (\(completed)/\(total))")
            case .list:
                CompatibilityPairListView(
                    vm: vm,
                    summaries: vm.summaries,
                    onBackToConfig: { vm.backToConfig() },
                    onOpenSummary: { vm.openDetail($0) }
                )
            case .detail(_, let response, let interpretState):
                // 复用 CompatibilityMainView(零改动),入参从当前对快照构造。
                if let chartA = vm.currentDetailASnapshot,
                   let chartB = vm.currentDetailBSnapshot {
                    CompatibilityMainView(
                        vm: vm,
                        response: response,
                        interpretState: interpretState,
                        chartASnapshot: chartA,
                        chartBSnapshot: chartB,
                        onBackToConfig: { vm.closeDetail() },
                        onGenerateInterpret: { vm.generateInterpretation() },
                        onShowPaywall: { showPaywall = true }
                    )
                } else {
                    // 不静默吞:detail 态但快照缺失 → 显式错误态
                    ErrorStateView(
                        userFacingError: .generic(message: "命盘数据读取失败"),
                        retry: { vm.closeDetail() }
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
