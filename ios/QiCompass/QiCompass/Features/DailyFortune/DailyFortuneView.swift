import SwiftUI
import SwiftData

/// Tab 3:每日运势。状态机驱动 + 顶部 7 天历史 pill + 下拉刷新 + 子时换日三重触发。
///
/// 主状态:
/// - .empty → 首次进入(等 onAppear 检查命盘)
/// - .loading → 排盘中(阶段 1)
/// - .chartMissing → CTA「先做深度解析」
/// - .fortuneReady(response, interpretState, businessDate) → 主视图 + AI 子状态
/// - .failed(msg) → 错误态
struct DailyFortuneView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @State private var vm: DailyFortuneViewModel?
    @State private var currentChartHash: String?
    @State private var currentZiHourRule: String = "zi_next_day"

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.backgroundGradient.ignoresSafeArea()
                content
            }
            .navigationTitle("每日运势")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task {
            if vm == nil {
                vm = DailyFortuneViewModel(
                    orchestrator: env.dailyFortuneOrchestrator,
                    chartStore: env.chartSnapshotStore,
                    dailyStore: env.dailyFortuneSnapshotStore,
                )
            }
            await resolveCurrentChart()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                vm?.checkBusinessDateChanged(
                    currentChartHash: currentChartHash,
                    ziHourRule: currentZiHourRule,
                )
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .NSCalendarDayChanged
            )
        ) { _ in
            vm?.checkBusinessDateChanged(
                currentChartHash: currentChartHash,
                ziHourRule: currentZiHourRule,
            )
        }
    }

    /// 从 UserSnapshotLink 取当前用户的命盘 hash + zi_hour_rule。
    /// MVP 单用户 → 取最近一条 link。
    @MainActor
    private func resolveCurrentChart() async {
        let ctx = env.modelContainer.mainContext
        do {
            let links = try ctx.fetch(FetchDescriptor<UserSnapshotLink>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            ))
            guard let link = links.first else {
                currentChartHash = nil
                vm?.state = .chartMissing
                return
            }
            // 取对应 ChartSnapshot 的 ziHourRule
            // SwiftData #Predicate 不能捕获外部属性,先提取为局部 let
            let snapshotHash = link.snapshotHash
            let charts = try ctx.fetch(FetchDescriptor<ChartSnapshot>(
                predicate: #Predicate { $0.contentHash == snapshotHash }
            ))
            if let chart = charts.first {
                currentZiHourRule = chart.ziHourRule
            }
            currentChartHash = snapshotHash
            vm?.onAppear(
                currentChartHash: currentChartHash,
                ziHourRule: currentZiHourRule,
            )
        } catch {
            AppLogger.persistence.error(
                "op=dailyFortune.resolveChart failed error=\(String(describing: error), privacy: .public)"
            )
            // 不静默吞:把失败传给 UI
            vm?.state = .failed(.generic(message: "读取命盘存档失败:\(error.localizedDescription)"))
        }
    }

    @ViewBuilder
    @MainActor
    private var content: some View {
        if let vm {
            switch vm.state {
            case .empty:
                LoadingStateView(title: "准备中…")
            case .loading:
                LoadingStateView(title: "推演流日中…")
            case .chartMissing:
                DailyFortuneEmptyView()
            case .fortuneReady(let response, let interpretState, let businessDate):
                DailyFortuneMainView(
                    vm: vm,
                    response: response,
                    interpretState: interpretState,
                    businessDate: businessDate,
                    chartHash: currentChartHash,
                    ziHourRule: currentZiHourRule,
                    onRefresh: { handleRefresh() },
                    onHistorySelect: { date in
                        vm.selectHistoryDate(
                            date,
                            currentChartHash: currentChartHash,
                            ziHourRule: currentZiHourRule,
                        )
                    },
                    onGenerateInterpret: {
                        vm.generateInterpretation(currentChartHash: currentChartHash)
                    },
                )
            case .failed(let userError):
                ErrorStateView(
                    userFacingError: userError,
                    retry: {
                        vm.onAppear(
                            currentChartHash: currentChartHash,
                            ziHourRule: currentZiHourRule,
                        )
                    }
                )
            }
        } else {
            ProgressView().tint(BaziTheme.gold)
        }
    }

    private func handleRefresh() {
        Task {
            await vm?.refresh(
                currentChartHash: currentChartHash,
                ziHourRule: currentZiHourRule,
            )
        }
    }
}
