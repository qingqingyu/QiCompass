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

    // S10 补时辰升级闭环(D7 触点 2/3):末尾静默行 + 日柱歧义整拦页 CTA 共用。
    /// 补时辰 sheet VM(nil = 未打开)。
    @State private var addHourVM: AddHourViewModel?
    /// 装配失败的人话文案(alert 显式报错,不静默不开)。
    @State private var addHourError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("每日运势")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            // S10:补时辰 sheet。关闭统一刷新——重算换新盘 → resolveCurrentChart
            // 按 hash 变化全量重载(完整版运势);静默态写穿 → refreshHourFlags
            /// 轻量重读判据(末尾行文案降中性),不重跑排盘管线。
            .sheet(item: $addHourVM, onDismiss: { refreshAfterAddHour() }) { vm in
                AddHourSheet(
                    vm: vm,
                    onCancel: { addHourVM = nil },
                    onRecalculated: { _ in }
                )
            }
            .alert(
                "暂时无法补时辰",
                isPresented: Binding(
                    get: { addHourError != nil },
                    set: { if !$0 { addHourError = nil } }
                )
            ) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(addHourError ?? "")
            }
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
            case .hourAmbiguousBlocked:
                // S09 日柱歧义全拦(D5):没有日主 → 免费降级不成立,VM 已拦在
                // 阶段 1 之前(两类请求都不发起)。拦截表达复用 S07 组件;
                // S10 接线:CTA → 补时辰 sheet(补上确定时辰即解日柱歧义),
                // 静默态文案降中性。
                HourUnknownGateNotice(
                    title: L10n.PaywallGate.dailyFortuneTitle,
                    reason: L10n.PaywallGate.dailyFortuneReason,
                    silenced: vm.isHourUnknownAccepted,
                    onAddHour: { openAddHourSheet() }
                )
                .padding(.horizontal, 32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    // S10:D7 触点 2(末尾静默行)→ 补时辰 sheet
                    onAddHour: { openAddHourSheet() },
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

    // MARK: - S10 补时辰(装配 + 关闭刷新)

    /// 打开补时辰 sheet(目标 = 当前命盘;装配失败显式 alert,不静默不开)。
    @MainActor
    private func openAddHourSheet() {
        guard let hash = currentChartHash else {
            AppLogger.app.warning("op=dailyFortune.openAddHour skip reason=no_chart_hash")
            return
        }
        do {
            addHourVM = try AddHourViewModel.make(
                snapshotHash: hash,
                orchestrator: env.deepAnalysisOrchestrator,
                chartStore: env.chartSnapshotStore,
                linkStore: env.userSnapshotLinkStore
            )
        } catch {
            AppLogger.app.error(
                "op=dailyFortune.openAddHour failed hash=\(hash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            addHourError = (error as? LocalizedError)?.errorDescription ?? L10n.AddHour.errorRebuild
        }
    }

    /// sheet 关闭统一刷新:重算换新盘 → hash 变化触发全量重载(完整版运势 +
    /// 判据翻转);静默态写穿 → 轻量重读判据。取消 → 幂等。
    @MainActor
    private func refreshAfterAddHour() {
        Task {
            await resolveCurrentChart()
            vm?.refreshHourFlags(chartHash: currentChartHash)
        }
    }
}
