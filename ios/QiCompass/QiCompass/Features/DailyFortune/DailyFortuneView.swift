import SwiftUI
import SwiftData

/// Tab 3:每日运势。状态机驱动 + 顶部 7 天历史 pill + 下拉刷新 + 子时换日三重触发。
///
/// 主状态:
/// - .empty → 首次进入(等 onAppear 检查命盘)
/// - .loading → 排盘中(阶段 1)
/// - .chartMissing → 空态(命盘存档缺失;首启被 onboarding sheet 盖住、完成即自动重载,重置后重走 onboarding 前可见)
/// - .ready(response, interpretState, businessDate) → 主视图 + AI 子状态
/// - .failed(msg) → 错误态
struct DailyFortuneView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    /// onboarding 存档成功(→true)与 Profile 重置命盘(→false)都会改这个 flag,
    /// @AppStorage 跨视图联动。本 Tab 是默认 Tab,onboarding sheet 盖上来时视图
    /// 从未消失,`.task` 在 sheet 弹出前已跑过(当时无命盘 → 卡 .chartMissing),
    /// dismiss 落地也不会重跑 → 靠这个 onChange 补一次重解析(2026-08-16 修复)。
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var vm: DailyFortuneViewModel?
    @State private var currentChartHash: String?
    @State private var currentZiHourRule: String = "zi_next_day"

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("每日运势")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
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
        .onChange(of: hasSeenOnboarding) { _, newValue in
            // 命盘存档增删的两个时刻(onboarding 提交成功 / Profile 重置)都落到这里。
            // 重解析会按 hash 是否变化决定是否强制重载(见 resolveCurrentChart)。
            AppLogger.app.info(
                "DailyFortuneView hasSeenOnboarding 变化 →\(newValue, privacy: .public),重新解析命盘"
            )
            Task { await resolveCurrentChart() }
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
            // 命盘身份变化(onboarding 落地 / 重置后重排换盘)时,必须先脱离旧状态,
            // 否则 VM.onAppear 的「已 ready 就跳过」守卫会让旧盘数据(或过期
            // .chartMissing)一直挂在屏幕上。同盘重进则不动,避免切 Tab 闪 loading。
            let hashChanged = snapshotHash != currentChartHash
            currentChartHash = snapshotHash
            if hashChanged {
                vm?.state = .empty
            }
            vm?.onAppear(
                currentChartHash: currentChartHash,
                ziHourRule: currentZiHourRule,
            )
        } catch {
            AppLogger.persistence.error(
                "op=dailyFortune.resolveChart failed error=\(String(describing: error), privacy: .public)"
            )
            // 不静默吞:把失败传给 UI(人话文案,原始 error 已记上方日志)
            vm?.state = .failed(.generic(message: "读取命盘存档失败,请重试"))
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
            case .ready(let response, let interpretState, let businessDate):
                DailyFortuneMainView(
                    vm: vm,
                    response: response,
                    interpretState: interpretState,
                    businessDate: businessDate,
                    chartHash: currentChartHash,
                    ziHourRule: currentZiHourRule,
                    imageClient: AnyDailyImageAPIClient(env.apiClient),
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
            ProgressView().tint(BaziTheme.cinnabar)
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
