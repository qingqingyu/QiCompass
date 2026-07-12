import Foundation
import SwiftUI
import SwiftData

// MARK: - 状态机

/// 每日运势主状态机(决策 §3.1)。
enum DailyFortuneViewState: Equatable {
    case empty              // 无命盘 → CTA
    case loading            // 首次 / 下拉刷新 / 跨业务日
    case chartMissing       // 显式提示「先做深度解析」
    case fortuneReady(DailyFortuneResponse, InterpretState, Date)  // 第三个 = 当前展示的 businessDate
    case failed(String)

    static func == (lhs: DailyFortuneViewState, rhs: DailyFortuneViewState) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty): return true
        case (.loading, .loading): return true
        case (.chartMissing, .chartMissing): return true
        case (.failed(let a), .failed(let b)): return a == b
        case (.fortuneReady, .fortuneReady): return true
        default: return false
        }
    }
}

// MARK: - ViewModel

/// 每日运势 ViewModel:@Observable + 状态机驱动。
///
/// 三重触发(决策 §3.7):
/// - `.NSCalendarDayChanged`(系统跨自然日)
/// - `scenePhase == .active`(App 回前台)
/// - `TimelineView(.periodic(by: 60))`(每分钟检查 businessDate 是否切)
@Observable
@MainActor
final class DailyFortuneViewModel {

    // MARK: 主状态

    var state: DailyFortuneViewState = .empty

    // MARK: 历史日期选择

    /// 当前选中的 businessDate(默认 today)。切 pill 时改变,触发重排(查本地或后端)。
    var selectedDate: Date = .now

    // MARK: 依赖

    private let orchestrator: DailyFortuneOrchestrator
    private let chartStore: ChartSnapshotStore
    private let dailyStore: DailyFortuneSnapshotStore
    private var determinantTask: Task<Void, Never>?
    private var interpretTask: Task<Void, Never>?

    /// 当前展示用的 chartPayload(在阶段 1 后缓存,阶段 2 复用)
    private var cachedChartPayload: ChartPayloadDTO?

    init(
        orchestrator: DailyFortuneOrchestrator,
        chartStore: ChartSnapshotStore,
        dailyStore: DailyFortuneSnapshotStore
    ) {
        self.orchestrator = orchestrator
        self.chartStore = chartStore
        self.dailyStore = dailyStore
    }

    // MARK: - onAppear

    /// 首次进入页面:检查命盘 → 计算业务日 → 触发链路。
    func onAppear(currentChartHash: String?, ziHourRule: String) {
        guard let hash = currentChartHash else {
            state = .chartMissing
            return
        }
        // 仅当当前没数据时进入 loading(避免每次切 Tab 都闪 loading)
        if case .fortuneReady = state { return }
        if case .loading = state { return }
        load(chartHash: hash, ziHourRule: ziHourRule, forceRefresh: false)
    }

    // MARK: - 子时换日触发

    /// 系统日变更 / 回前台 / Timeline tick 都调这个。
    /// 重新算 businessDate,若与当前 state 不同则重排。
    func checkBusinessDateChanged(currentChartHash: String?, ziHourRule: String) {
        guard let hash = currentChartHash else { return }
        let now = Date()
        let newBusinessDate = BusinessDateCalculator.businessDate(
            now: now, ziHourRule: ziHourRule,
        )
        // 若当前展示的是 selectedDate=today 且 now 已跨日 → 自动 refetch
        // 历史回看不自动切
        if case .fortuneReady(_, _, let showing) = state {
            let showingNorm = Calendar.current.startOfDay(for: showing)
            let newNorm = Calendar.current.startOfDay(for: newBusinessDate)
            if showingNorm != newNorm, isToday(showing) == false {
                // 当前在历史日,不自动切(用户主动选择)
                return
            }
            if showingNorm != newNorm {
                selectedDate = newBusinessDate
                load(chartHash: hash, ziHourRule: ziHourRule, forceRefresh: false)
            }
        }
    }

    // MARK: - 下拉刷新

    /// 强制重调后端两层缓存(决策 §3.5)。
    func refresh(currentChartHash: String?, ziHourRule: String) async {
        guard let hash = currentChartHash else {
            state = .chartMissing
            return
        }
        selectedDate = BusinessDateCalculator.businessDate(
            now: .now, ziHourRule: ziHourRule,
        )
        await runFullPipeline(
            chartHash: hash, ziHourRule: ziHourRule,
            businessDate: selectedDate, forceRefresh: true,
        )
    }

    // MARK: - 顶部日期 pill

    /// 用户选历史 pill:展示该日;本地无则调后端补生成。
    func selectHistoryDate(_ date: Date, currentChartHash: String?, ziHourRule: String) {
        guard let hash = currentChartHash else {
            state = .chartMissing
            return
        }
        selectedDate = date
        load(chartHash: hash, ziHourRule: ziHourRule, forceRefresh: false)
    }

    // MARK: - AI 解读触发

    /// 用户点「今日解读」按钮 → 触发 AI 阶段(若已命中缓存则直接显示)。
    func generateInterpretation(currentChartHash: String?) {
        guard let hash = currentChartHash else { return }
        guard case .fortuneReady(let response, _, let businessDate) = state else { return }
        guard let chartPayload = cachedChartPayload else {
            // chartPayload 解码失败(见 runFullPipeline 的 catch)→ 显式报错,不静默返回
            state = .fortuneReady(
                response,
                .failed(message: "命盘数据读取失败,请下拉刷新重试"),
                businessDate,
            )
            return
        }

        interpretTask?.cancel()
        state = .fortuneReady(response, .fetching, businessDate)

        interpretTask = Task {
            do {
                let resp = try await orchestrator.runInterpretation(
                    chartHash: hash,
                    chartPayload: chartPayload,
                    dailyResponse: response,
                    businessDate: businessDate,
                )
                if !Task.isCancelled {
                    state = .fortuneReady(
                        response,
                        .ok(text: resp.interpretation, cached: resp.cached),
                        businessDate,
                    )
                }
            } catch let error as DeepAnalysisError {
                if !Task.isCancelled {
                    state = .fortuneReady(
                        response,
                        .failed(message: error.errorDescription ?? "未知错误"),
                        businessDate,
                    )
                }
            } catch {
                if !Task.isCancelled {
                    state = .fortuneReady(
                        response,
                        .failed(message: error.localizedDescription),
                        businessDate,
                    )
                }
            }
        }
    }

    // MARK: - 历史列表

    /// 取 7 天历史(throw 不静默;UI 失败时显示 toast)。
    func loadHistory(chartHash: String) throws -> [DailyFortuneSnapshot] {
        try dailyStore.getHistory(chartHash: chartHash, limit: 7)
    }

    // MARK: - 查询

    var remainingReads: Int { orchestrator.remainingReads() }
    var nextDailyReset: Date { orchestrator.nextDailyReset() }

    // MARK: - Private

    private func load(
        chartHash: String, ziHourRule: String, forceRefresh: Bool
    ) {
        determinantTask?.cancel()
        state = .loading

        determinantTask = Task {
            await runFullPipeline(
                chartHash: chartHash, ziHourRule: ziHourRule,
                businessDate: selectedDate, forceRefresh: forceRefresh,
            )
        }
    }

    private func runFullPipeline(
        chartHash: String, ziHourRule: String,
        businessDate: Date, forceRefresh: Bool
    ) async {
        // 阶段 1
        do {
            let (response, _) = try await orchestrator.runDeterministic(
                chartHash: chartHash,
                ziHourRule: ziHourRule,
                businessDate: businessDate,
                forceRefresh: forceRefresh,
            )
            // 缓存 chartPayload 供阶段 2 复用
            do {
                let snapshot = try chartStore.get(contentHash: chartHash)
                let bazi = try chartStore.decodeResponse(from: snapshot)
                cachedChartPayload = ChartPayloadDTO.from(baziResponse: bazi)
            } catch {
                // chartStore 读取/解码失败:阶段 1 已成功(说明 runDeterministic 内部
                // 的同样调用成功了),此处失败属异常。不静默吞,记录日志。
                // cachedChartPayload 保持 nil,用户点"今日解读"时 guard 会拦截。
                AppLogger.persistence.error(
                    "daily.runFullPipeline.chartPayload_failed hash=\(chartHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }

            // 若本地已有 AI 解读(24h 内)→ 直接显示 ok(cached=true),否则 idle
            var interpretState: InterpretState = .idle
            do {
                if let cached = try orchestrator.cachedInterpretationIfFresh(
                    chartHash: chartHash, targetDate: businessDate
                ) {
                    interpretState = .ok(text: cached.text, cached: true)
                }
            } catch {
                // 非关键路径:缓存读取失败只 log,不影响主流程(interpretState 保持 idle)
                AppLogger.persistence.error(
                    "daily.cachedInterpretation_read_failed hash=\(chartHash, privacy: .public) targetDate=\(businessDate, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }

            if !Task.isCancelled {
                state = .fortuneReady(response, interpretState, businessDate)
            }
        } catch let error as DailyFortuneError where error == .chartMissing {
            if !Task.isCancelled {
                state = .chartMissing
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func isToday(_ date: Date) -> Bool {
        Calendar.current.isDateInToday(date)
    }
}

// MARK: - DailyFortuneError Equatable(仅用于 == 比较)

extension DailyFortuneError: Equatable {
    public static func == (lhs: DailyFortuneError, rhs: DailyFortuneError) -> Bool {
        switch (lhs, rhs) {
        case (.chartMissing, .chartMissing): return true
        }
    }
}
