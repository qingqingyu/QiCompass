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
    case failed(UserFacingError)

    static func == (lhs: DailyFortuneViewState, rhs: DailyFortuneViewState) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty): return true
        case (.loading, .loading): return true
        case (.chartMissing, .chartMissing): return true
        case (.failed(let a), .failed(let b)): return a == b
        case (.fortuneReady(let a1, let a2, let a3), .fortuneReady(let b1, let b2, let b3)):
            // DailyFortuneResponse 无 hash 字段,用业务关键字段做相等性代理
            // (dayPillar + lunarDate + currentHourIndex 在同一 businessDate 内能唯一定位一次响应)
            // 关键:必须比较 InterpretState(a2 == b2),否则 .idle → .fetching 会被判等,
            // 导致 @Observable 不触发 View 重渲染,"今日解读"按钮看起来"完全没反应"
            return a1.dayPillar == b1.dayPillar
                && a1.lunarDate == b1.lunarDate
                && a1.currentHourIndex == b1.currentHourIndex
                && a2 == b2
                && a3 == b3
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

    /// 离线查看角标(网络失败 fallback 到本地缓存时为 true)。
    var isOffline: Bool = false

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
        // 规则 2:用户主动触发(下拉刷新)入口日志
        AppLogger.app.info("dailyVM.refresh.start currentChartHash=\(currentChartHash ?? "nil", privacy: .public) ziHourRule=\(ziHourRule, privacy: .public)")
        guard let hash = currentChartHash else {
            AppLogger.app.warning("dailyVM.refresh.skip reason=no_chart_hash")
            state = .chartMissing
            return
        }
        isOffline = false
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
        guard let hash = currentChartHash else {
            // 不静默吞(CLAUDE.md 全局约束):UI 收到点击说明调用方传 nil 是逻辑错乱,显式记录
            AppLogger.app.error("op=dailyFortune.generateInterpretation missing_chartHash state=\(String(describing: self.state), privacy: .public)")
            return
        }
        guard case .fortuneReady(let response, _, let businessDate) = state else {
            AppLogger.app.error("op=dailyFortune.generateInterpretation invalid_state state=\(String(describing: self.state), privacy: .public)")
            return
        }
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
                        .okFree(text: resp.interpretation, cached: resp.cached),
                        businessDate,
                    )
                }
            } catch is CancellationError {
                return
            } catch let error as DeepAnalysisError {
                if !Task.isCancelled {
                    // dailyLimitReached 独立形态(方案 step 4):禁用生成按钮、不显示重试
                    if case .dailyLimitReached(let reset, _) = error {
                        state = .fortuneReady(
                            response,
                            .dailyLimitReached(nextReset: reset),
                            businessDate,
                        )
                    } else {
                        state = .fortuneReady(
                            response,
                            .failed(message: error.errorDescription ?? "未知错误"),
                            businessDate,
                        )
                    }
                }
            } catch {
                if !Task.isCancelled {
                    let userError = UserFacingError.from(error, stage: .interpret)
                    if case .dailyLimitReached(let reset) = userError {
                        state = .fortuneReady(
                            response,
                            .dailyLimitReached(nextReset: reset),
                            businessDate,
                        )
                    } else {
                        state = .fortuneReady(
                            response,
                            .failed(message: userError.errorDescription ?? "未知错误"),
                            businessDate,
                        )
                    }
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
        isOffline = false

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
        cachedChartPayload = nil

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
                guard let snapshot = try chartStore.get(contentHash: chartHash) else {
                    throw NSError(
                        domain: "DailyFortune", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "命盘存档未找到"]
                    )
                }
                let bazi = try chartStore.decodeResponse(from: snapshot)
                cachedChartPayload = ChartPayloadDTO.from(baziResponse: bazi)
            } catch {
                // chartStore 读取/解码失败:阶段 1 已成功(说明 runDeterministic 内部
                // 的同样调用成功了),此处失败属异常。不静默吞,记录日志并传到 UI。
                AppLogger.persistence.error(
                    "daily.runFullPipeline.chartPayload_failed hash=\(chartHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                throw error
            }

            // 若本地已有 AI 解读(24h 内)→ 直接显示 ok(cached=true),否则 idle
            var interpretState: InterpretState = .idle
            do {
                if let cached = try await orchestrator.cachedInterpretationIfFresh(
                    chartHash: chartHash, targetDate: businessDate
                ) {
                    interpretState = .okFree(text: cached.text, cached: true)
                }
            } catch {
                // 缓存读取失败必须传到 UI 的解读错误态,避免成功页隐藏异常。
                AppLogger.persistence.error(
                    "daily.cachedInterpretation_read_failed hash=\(chartHash, privacy: .public) targetDate=\(businessDate, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                interpretState = .failed(message: "读取每日解读缓存失败:\(error.localizedDescription)")
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
            await handleNetworkFailureFallback(
                error: error, chartHash: chartHash, businessDate: businessDate
            )
        }
    }

    /// 离线 fallback(方案 step 6):
    /// - 网络/超时错误 + 同 chartHash + businessDate 有缓存(即使 `cachedUntil` 已过)→ 展示缓存
    ///   + 不触发 AI、不扣次数 + isOffline 角标
    /// - 无缓存 → 进入 .failed(UserFacingError)
    /// 快照中的历史 AI 文本不作为当前身份缓存命中；无法联网确认身份时,
    /// 确定性内容仍可展示,AI 子状态显式进入 error。
    private func handleNetworkFailureFallback(
        error: Error, chartHash: String, businessDate: Date
    ) async {
        // 非网络类错误不进 fallback
        let isNetworkError: Bool = {
            if case .networkError(let urlError)? = error as? APIError,
               UserFacingError.isOffline(urlError) {
                return true
            }
            if let urlError = error as? URLError, UserFacingError.isOffline(urlError) {
                return true
            }
            return false
        }()

        guard isNetworkError else {
            // 非网络错误 → 显示"天意未明"墨溅卡
            if !Task.isCancelled {
                state = .failed(UserFacingError.from(error, stage: .dailyDeterministic))
            }
            return
        }

        // 网络错误：尝试宽容缓存（即使 cachedUntil 已过也展示）。
        // 存储读失败与"真无缓存"分开处理：前者 log 后按无缓存 UI 走。
        let cached: DailyFortuneSnapshot
        let cachedResponse: DailyFortuneResponse
        do {
            guard let snap = try dailyStore.get(chartHash: chartHash, targetDate: businessDate) else {
                // 真无缓存 → 显示"天意未明"墨溅卡
                if !Task.isCancelled {
                    state = .failed(UserFacingError.from(error, stage: .dailyDeterministic))
                }
                return
            }
            cached = snap
            cachedResponse = try dailyStore.response(from: cached)
        } catch {
            AppLogger.persistence.error(
                "daily.offline_fallback.store_read_failed hash=\(chartHash, privacy: .public) targetDate=\(businessDate, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            if !Task.isCancelled {
                state = .failed(UserFacingError.from(error, stage: .dailyDeterministic))
            }
            return
        }

        // 快照中的 AI 文本是历史记录。离线时无法通过 health 确认
        // 当前 provider/model,不能把它标成当前供应商缓存命中。
        let hasInterpretation = !cached.interpretation.trimmingCharacters(in: .whitespaces).isEmpty
        var interpState: InterpretState = hasInterpretation
            ? .failed(message: "已保留历史解读,联网后可确认当前 AI 来源")
            : .idle

        // 同步刷新 chartPayload(用户在线恢复后点"今日解读"可触发 AI)。
        // 先清空旧值,避免读取失败时沿用上一张命盘的 prompt 上下文。
        // chartStore 读取失败不阻塞已有离线解读展示;若没有离线解读,则把 AI 子态
        // 显式置为 failed,让用户知道当前不能生成新解读。
        cachedChartPayload = nil
        do {
            if let chartSnapshot = try chartStore.get(contentHash: chartHash) {
                let bazi = try chartStore.decodeResponse(from: chartSnapshot)
                cachedChartPayload = ChartPayloadDTO.from(baziResponse: bazi)
            } else {
                AppLogger.persistence.error(
                    "daily.offline_fallback.chartSnapshot_missing hash=\(chartHash, privacy: .public)"
                )
                if !hasInterpretation {
                    interpState = .failed(message: "命盘数据读取失败,请联网后下拉刷新重试")
                }
            }
        } catch {
            AppLogger.persistence.error(
                "daily.offline_fallback.chartPayload_failed hash=\(chartHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            if !hasInterpretation {
                interpState = .failed(message: "命盘数据读取失败,请联网后下拉刷新重试")
            }
        }

        isOffline = true
        if !Task.isCancelled {
            state = .fortuneReady(cachedResponse, interpState, businessDate)
        }
        AppLogger.app.info(
            "daily.offline_fallback hash=\(chartHash, privacy: .public) targetDate=\(businessDate, privacy: .public) hasInterpretation=\(hasInterpretation)"
        )
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
