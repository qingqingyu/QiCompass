import Foundation
import SwiftUI
import SwiftData

// MARK: - 状态机

/// 每日运势主状态机(决策 §3.1)。
enum DailyFortuneViewState: Equatable {
    case empty              // 瞬态:等命盘解析(onboarding 落地强制重载也走这里)
    case loading            // 首次 / 下拉刷新 / 跨业务日
    case chartMissing       // 命盘存档缺失(首启被 onboarding sheet 盖住、完成即自动重载;重置后重走 onboarding 前可见;不引导先做深度解析)
    case hourAmbiguousBlocked  // S09:日柱歧义盘全拦(D5)——没有日主,免费降级不成立,两类请求都不发起,直接拦截页
    case ready(DailyFortuneResponse, InterpretState, Date)  // 第三个 = 当前展示的 businessDate
    case failed(UserFacingError)

    static func == (lhs: DailyFortuneViewState, rhs: DailyFortuneViewState) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty): return true
        case (.loading, .loading): return true
        case (.chartMissing, .chartMissing): return true
        case (.hourAmbiguousBlocked, .hourAmbiguousBlocked): return true
        case (.failed(let a), .failed(let b)): return a == b
        case (.ready(let a1, let a2, let a3), .ready(let b1, let b2, let b3)):
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

// MARK: - 解读触发来源(2026-09-24 失败降级拍板)

/// AI 解读的触发来源:自动失败 → 调度**一次**后台静默重试,不循环。
enum InterpretTrigger {
    /// 进入页面自动生成(2026-09-07 拍板「一上来就直接解析」)
    case automatic
    /// 用户手动(离线恢复 CTA——.idle 态唯一按钮)。失败不调度静默重试——
    /// 用户正看着,再静默转圈只会困惑;手动恢复路径 = 下拉刷新
    /// (2026-10-06 Retry 按钮移除,失败小注已注明)。
    case manual
    /// 自动失败后调度的一次后台静默重试。失败即终态(模板文案 + 下拉刷新兜底)。
    case silentRetry
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

    /// S09 当前命盘的时辰未知判据(复用 S07 `HourUnknownGate`,单一事实源 =
    /// 存档 payload,VM/View 不另行推断)。`.ready` 时供 View 决定末尾静默
    /// 提示位是否显示(D7 触点 2,S10 已接线可点击);`.dayAmbiguous` 由
    /// runFullPipeline 拦在阶段 1 之前(见该函数注释)。
    private(set) var hourGate: HourUnknownGate = .hourKnown

    /// S10「我确实不知道」静默态(单一事实源 = 同一 payload 的
    /// `hour_unknown_accepted`,与 hourGate 同点位刷新)。静默态下末尾行文案
    /// 降中性(不再主动提示,行保留可点击)。
    private(set) var isHourUnknownAccepted: Bool = false

    // MARK: 业务日

    /// 当前展示的 businessDate(默认 now;下拉刷新/跨业务日时更新)。
    /// 2026-09-07 历史回看功能拔除后,该值恒为当日业务日。
    var selectedDate: Date = .now

    // MARK: 依赖

    private let orchestrator: DailyFortuneOrchestrator
    private let chartStore: ChartSnapshotStore
    private let dailyStore: DailyFortuneSnapshotStore
    private var determinantTask: Task<Void, Never>?
    private var interpretTask: Task<Void, Never>?

    // MARK: 失败降级(2026-09-24 拍板:模板文案 + 后台静默重试)

    /// 一次静默重试是否在飞/已调度(UI:失败卡显示引擎模板文案 + 「重试中」小注,
    /// Retry 链接隐藏避免双触发)。
    private(set) var isSilentRetrying = false

    /// 静默重试延迟。生产 6s;测试注入小值(不然用例要干等)。
    var silentRetryDelay: TimeInterval = 6

    /// 本轮管线静默重试是否已用过(一次为限,不循环;runFullPipeline 开头重置)。
    private var silentRetryUsed = false

    private var silentRetryTask: Task<Void, Never>?

    /// 当前展示用的 chartPayload(在阶段 1 后缓存,阶段 2 复用)
    private var cachedChartPayload: ChartPayloadDTO?

    /// 管线世代号(2026-10-07 review 修复):每次 runFullPipeline 入口推进。
    /// L5 门控探针(`hasCrossLanguageDailySource`)在 `state = .ready` 之后引入
    /// 了挂起点——`refresh()` 直接 await runFullPipeline(不被 `load()` 的
    /// determinantTask?.cancel() 管辖),探针窗口内换盘会推进新管线;旧管线
    /// 复活后凭局部 interpretState == .idle 触发 generateInterpretation(旧
    /// chartHash × 当前 .ready 的**新盘** response/payload)→ 跨盘内容静默写
    /// 进旧盘 24h 缓存键。世代失配即自弃,镜像 deep VM translationGeneration。
    private var pipelineGeneration = 0

    /// S6 信号注释判据:喜忌是否可用(时辰未知/从格 → 后端喜忌双空)。
    /// nil = payload 未知(离线兜底边缘)——宿主不得据此断言"从格",不显示注释。
    /// 信号空表有两种真因:喜忌不可用(降级,该注释)与流日五行未命中喜忌
    /// (正常态,不该注释);本属性区分两者(后端 `_day_signal` 对无交集也返回空表)。
    var hasAvailableXiji: Bool? {
        guard let payload = cachedChartPayload else { return nil }
        return !payload.favorableElements.isEmpty || !payload.unfavorableElements.isEmpty
    }

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

    /// S3 每日运势插画:构建与阶段 1 同源的 POST 请求体。
    ///

    /// 首次进入页面:检查命盘 → 计算业务日 → 触发链路。
    func onAppear(currentChartHash: String?, ziHourRule: String) {
        guard let hash = currentChartHash else {
            state = .chartMissing
            return
        }
        // 仅当当前没数据时进入 loading(避免每次切 Tab 都闪 loading)
        if case .ready = state { return }
        if case .loading = state { return }
        // businessDate 归一化(与 checkBusinessDateChanged / refresh 同源):裸 .now
        // 在 23:00-00:00 窗口(zi_next_day 已换业务日)会落后一个业务日——既导致
        // 首 tick 双跑管线,也会被 runFullPipeline 的跨业务日自动解读守卫误判跳过。
        selectedDate = BusinessDateCalculator.businessDate(
            now: .now, ziHourRule: ziHourRule,
        )
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
        // 当前展示日 ≠ 新业务日 → 自动 refetch(跨日当天自动换新盘+自动解读)
        if case .ready(_, _, let showing) = state {
            let showingNorm = Calendar.current.startOfDay(for: showing)
            let newNorm = Calendar.current.startOfDay(for: newBusinessDate)
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

    // MARK: - AI 解读触发

    /// 触发 AI 解读阶段(命中缓存则直接显示)。主路径 = runFullPipeline 缓存
    /// 未命中时自动调用(2026-09-07 拍板「一上来就直接解析」,trigger=.automatic);
    /// 手动入口(默认 .manual)只剩离线恢复一条 UI 路(.idle CTA)——.failed 的
    /// Retry 按钮 2026-10-06 拍板移除,失败恢复靠 .silentRetry 兜底 + 下拉刷新。
    /// 2026-09-24 失败降级:.automatic 失败 → 调度一次 .silentRetry 后台重试,
    /// 重试期间保持 .failed(UI 显示引擎模板文案),成功即转 .okFree。
    func generateInterpretation(
        currentChartHash: String?, trigger: InterpretTrigger = .manual
    ) {
        guard let hash = currentChartHash else {
            // 不静默吞(CLAUDE.md 全局约束):UI 收到点击说明调用方传 nil 是逻辑错乱,显式记录
            AppLogger.app.error("op=dailyFortune.generateInterpretation missing_chartHash state=\(String(describing: self.state), privacy: .public)")
            return
        }
        // S09 纵深防御(D5 全拦,S07 PaywallViewModel.purchase 同款第二把锁):
        // 日柱歧义盘不发起 interpret。runFullPipeline 已拦在阶段 1 之前
        // (.hourAmbiguousBlocked 进不了下面的 .ready 分支),能走到这里说明
        // 状态机被绕过——显式记录并拒绝,不静默放行。
        guard hourGate != .dayAmbiguous else {
            AppLogger.app.error("op=dailyFortune.generateInterpretation dayAmbiguous_intercepted hash=\(hash, privacy: .public) state=\(String(describing: self.state), privacy: .public)")
            return
        }
        guard case .ready(let response, _, let businessDate) = state else {
            AppLogger.app.error("op=dailyFortune.generateInterpretation invalid_state state=\(String(describing: self.state), privacy: .public)")
            return
        }
        guard let chartPayload = cachedChartPayload else {
            // chartPayload 缺失(runFullPipeline 离线兜底路径解档失败会留 nil)
            // → 显式报错,不静默返回(2026-09-28 S02:UI 小注不再露原文,补日志保可见性)
            AppLogger.app.error("op=dailyFortune.generateInterpretation chartPayload_missing hash=\(hash, privacy: .public)")
            state = .ready(
                response,
                .failed(message: L10n.DailyFortune.interpretChartReadFailed),
                businessDate,
            )
            return
        }

        interpretTask?.cancel()
        if trigger != .silentRetry {
            // 手动/自动触发:取消可能在飞的静默重试调度(用户动作优先,成功后
            // 再轮到旧调度会重复消耗),正常走 .fetching。
            silentRetryTask?.cancel()
            isSilentRetrying = false
            state = .ready(response, .fetching, businessDate)
        }
        // .silentRetry:保持当前 .failed(模板文案继续显示,不闪「推演中」),
        // isSilentRetrying 已在调度时置 true。

        // 世代号快照(2026-10-07 review):refresh() 直连 runFullPipeline,不经
        // load() 的 interpretTask 取消——旧解读任务晚到会覆写新管线内容
        // (典型:刷新后缓存命中,无新解读可取消旧任务)。写点全部比对世代,
        // 失配自弃(镜像 runFullPipeline 各写点的 pipelineGeneration 守卫)。
        let generation = pipelineGeneration
        interpretTask = Task {
            do {
                let resp = try await orchestrator.runInterpretation(
                    chartHash: hash,
                    chartPayload: chartPayload,
                    dailyResponse: response,
                    businessDate: businessDate,
                )
                if !Task.isCancelled, pipelineGeneration == generation {
                    isSilentRetrying = false
                    state = .ready(
                        response,
                        .okFree(text: resp.interpretation, cached: resp.cached),
                        businessDate,
                    )
                } else if !Task.isCancelled,
                          case .ready(let currentResponse, _, let currentDate) = state,
                          Calendar.current.isDate(currentDate, inSameDayAs: businessDate) {
                    // 同日迟到成功落地(2026-10-07 review #7):refresh() 直连
                    // runFullPipeline 不取消 interpretTask,解读在飞时下拉刷新
                    // 会推进世代号——此时成功结果**已扣次数**,按世代失配自弃
                    // = 白扣,次数恰好耗尽时用户看到达限卡盖住刚付费的内容。
                    // 同业务日的解读按 (chart, 业务日) 键缓存,内容不随管线重跑
                    // 错配;落**当前** response(不回写旧管线的 response)。跨业务
                    // 日 / 换盘照旧自弃(换盘走 load 会取消本任务,Task.isCancelled
                    // 兜底;跨日内容已无人可见,落地无意义)。
                    AppLogger.app.notice(
                        "op=dailyFortune.interpret.late_success_landed hash=\(hash, privacy: .public) gen=\(generation, privacy: .public) current=\(self.pipelineGeneration, privacy: .public) — 世代失配但同业务日,已扣次数的迟到成功照常展示"
                    )
                    isSilentRetrying = false
                    state = .ready(
                        currentResponse,
                        .okFree(text: resp.interpretation, cached: resp.cached),
                        currentDate,
                    )
                }
            } catch is CancellationError {
                return
            } catch let error as DeepAnalysisError {
                if !Task.isCancelled, pipelineGeneration == generation {
                    // dailyLimitReached 独立形态(方案 step 4):禁用生成按钮、不显示重试
                    if case .dailyLimitReached(let reset, _) = error {
                        isSilentRetrying = false
                        state = .ready(
                            response,
                            .dailyLimitReached(nextReset: reset, serverPool: false),
                            businessDate,
                        )
                    } else {
                        enterInterpretFailed(
                            message: error.errorDescription ?? L10n.Common.unknownError,
                            trigger: trigger, chartHash: hash,
                            response: response, businessDate: businessDate,
                        )
                    }
                }
            } catch {
                if !Task.isCancelled, pipelineGeneration == generation {
                    // 凭证失效(2026-10-08):403 重试无意义,不走 enterInterpretFailed
                    // (那会再排一次静默重试白打 403)——独立态渲染「重新排盘」出口
                    if APIError.isContextTokenError(error) {
                        isSilentRetrying = false
                        state = .ready(
                            response,
                            .contextTokenExpired,
                            businessDate,
                        )
                        return
                    }
                    let userError = UserFacingError.from(error, stage: .interpret)
                    if case .dailyLimitReached(let reset, let serverPool) = userError {
                        isSilentRetrying = false
                        state = .ready(
                            response,
                            .dailyLimitReached(nextReset: reset, serverPool: serverPool),
                            businessDate,
                        )
                    } else {
                        enterInterpretFailed(
                            message: userError.errorDescription ?? L10n.Common.unknownError,
                            trigger: trigger, chartHash: hash,
                            response: response, businessDate: businessDate,
                        )
                    }
                }
            }
        }
    }

    /// 解读失败统一落点:置 .failed + 按触发来源决定是否调度一次静默重试。
    private func enterInterpretFailed(
        message: String,
        trigger: InterpretTrigger,
        chartHash: String,
        response: DailyFortuneResponse,
        businessDate: Date
    ) {
        // 2026-09-28 S02:UI 小注不再显示原始错误(改「通用参考」口径),失败原因
        // 在此显式记日志,不让错误从两条通道同时消失(错误显式传播约束)。
        AppLogger.app.error(
            "op=dailyFortune.interpret.failed trigger=\(String(describing: trigger), privacy: .public) hash=\(chartHash, privacy: .public) message=\(message, privacy: .public)"
        )
        state = .ready(response, .failed(message: message), businessDate)
        if trigger == .automatic, !silentRetryUsed {
            scheduleSilentRetry(chartHash: chartHash)
        } else {
            isSilentRetrying = false
        }
    }

    /// 自动失败后的一次后台静默重试(2026-09-24 拍板):延迟后重发 interpret,
    /// UI 保持 .failed 模板文案 + 「重试中」小注。一次为限(silentRetryUsed),
    /// 重试失败即终态;调度与结果都显式记日志(静默 ≠ 吞错)。
    private func scheduleSilentRetry(chartHash: String) {
        silentRetryUsed = true
        isSilentRetrying = true
        let delay = silentRetryDelay
        AppLogger.app.notice(
            "op=dailyFortune.interpret.silentRetryScheduled delay=\(delay, privacy: .public) hash=\(chartHash, privacy: .public)"
        )
        silentRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.generateInterpretation(currentChartHash: chartHash, trigger: .silentRetry)
        }
    }

    // MARK: - S10 静默态轻量刷新

    /// 补时辰 sheet 关闭后的轻量刷新(静默态写穿 payload,hash 不变 → 不重跑
    /// 排盘管线,只重读存档判据;重算换新盘场景由 View 层 resolveCurrentChart 的
    /// hash 变化走全量重载)。读取失败显式记日志,保留旧判据(不静默吞,
    /// 也不拿失败掩盖已展示的内容)。
    func refreshHourFlags(chartHash: String?) {
        guard let hash = chartHash else { return }
        do {
            guard let snapshot = try chartStore.get(contentHash: hash) else {
                AppLogger.persistence.warning(
                    "op=dailyFortune.refreshHourFlags snapshot_missing hash=\(hash, privacy: .public)"
                )
                return
            }
            let bazi = try chartStore.decodeResponse(from: snapshot)
            hourGate = bazi.hourUnknownGate
            isHourUnknownAccepted = bazi.isHourSilenced
        } catch {
            AppLogger.persistence.error(
                "op=dailyFortune.refreshHourFlags failed hash=\(hash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - 查询

    var remainingReads: Int { orchestrator.remainingReads() }
    var nextDailyReset: Date { orchestrator.nextDailyReset() }

    // MARK: - Private

    private func load(
        chartHash: String, ziHourRule: String, forceRefresh: Bool
    ) {
        determinantTask?.cancel()
        // in-flight 解读任务一并取消:自动解读(2026-09-07)使进入页面即有 interpret
        // 在飞,跨业务日 rollover / 重载若不取消,旧任务完成会把 state 写回旧
        // businessDate 的 .ready(闪旧内容 + 下一 tick 重复触发 load)。取消无配额
        // 泄漏(orchestrator 失败路径含 refund),VM 侧捕 CancellationError 返回。
        interpretTask?.cancel()
        silentRetryTask?.cancel()
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
        // 世代号入口推进(load / refresh 两条入口都过这里):后到的管线作废
        // 在飞旧管线的尾部自动触发(见 pipelineGeneration 属性注释)。
        pipelineGeneration &+= 1
        let generation = pipelineGeneration
        cachedChartPayload = nil
        // 静默重试配额随管线重置(load / refresh / 跨业务日都过这里):
        // 新一轮管线允许失败后再静默重试一次;残留调度取消,防旧延迟任务
        // 在新管线成功后凭空再发一次 interpret。
        silentRetryTask?.cancel()
        silentRetryUsed = false
        isSilentRetrying = false

        do {
            // S09 时辰未知判据前置(判据单一事实源 = 存档 payload → S07
            // `HourUnknownGate`,此处只消费不重推):阶段 1 之前先解存档——
            // ① 日柱歧义盘全拦(见下方 if);② 顺带缓存 chartPayload 供阶段 2
            // 复用(原阶段 1 之后的二次取档解码上移到此处,数据口径不变:
            // 同一 store、同一 decodeResponse,失败走同一错误链)。
            guard let snapshot = try chartStore.get(contentHash: chartHash) else {
                throw DailyFortuneError.chartMissing
            }
            let bazi = try chartStore.decodeResponse(from: snapshot)
            hourGate = bazi.hourUnknownGate
            isHourUnknownAccepted = bazi.isHourSilenced
            cachedChartPayload = ChartPayloadDTO.from(baziResponse: bazi)

            // S09 / D5 日柱歧义全拦:没有日主,daily_fortune 的 REQUIRED 里
            // day_master / day_pillar / day_relation 全塌,「日柱×流日」免费
            // 降级叙事也不成立 → 拦在阶段 1 之前:daily-fortune 排盘与
            // interpret 两类请求都不发起(拦截页由 View 层渲染,与深度解析
            // 整拦页同款表达)。不猜日主、不做半盘运势。
            if hourGate == .dayAmbiguous {
                AppLogger.app.warning(
                    "daily.runFullPipeline.dayAmbiguous_blocked hash=\(chartHash, privacy: .public) note=S09_D5_日柱歧义全拦_两类请求均不发起"
                )
                // 世代号守卫(2026-10-07 review 修复 #4):refresh 直连本函数不经
                // determinantTask 取消,旧管线晚到不得覆写新管线 UI
                guard !Task.isCancelled, pipelineGeneration == generation else { return }
                state = .hourAmbiguousBlocked
                return
            }

            // 阶段 1
            let (response, _) = try await orchestrator.runDeterministic(
                chartHash: chartHash,
                ziHourRule: ziHourRule,
                businessDate: businessDate,
                forceRefresh: forceRefresh,
            )

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
                interpretState = .failed(message: L10n.DailyFortune.interpretCacheReadFailed)
            }

            // 世代号守卫(2026-10-07 review 修复 #4):refresh() 直连本函数、不经
            // load() 的 determinantTask 取消——A 盘下拉刷新后切 B 盘,旧刷新管线
            // 晚返回时会把 UI 写回 A 并给 A 自动扣一次解读。世代失配即自弃
            // (L5 探针世代言注释的姊妹守卫,本处覆盖 .ready 写点与自动触发)。
            guard !Task.isCancelled, pipelineGeneration == generation else { return }
            state = .ready(response, interpretState, businessDate)

            // 自动解读(2026-09-07 用户拍板「一上来就直接解析,不要点一下」):
            // 缓存未命中(.idle)且当日次数未耗尽 → 自动触发 AI 阶段。
            // 离线兜底路径不走 runFullPipeline 成功分支,不会无网空转;
            // 次数耗尽保持 .idle(UI 按 remainingReads 渲染达限卡);
            // 缓存读取失败(.failed)不自动重试,留手动入口。
            // 跨业务日守卫:管线跨过子时换日边界才完成时(如 22:59 发起、
            // 23:00 后落地),不为已被换日的旧 businessDate 自动消耗配额
            // (历史回看 UI 已拔除,旧日解读无人可见=纯浪费)。判据与
            // checkBusinessDateChanged 同源;tick 随即触发整页重载+新日自动解读。
            let isBusinessDateStillCurrent = Calendar.current.isDate(
                BusinessDateCalculator.businessDate(now: .now, ziHourRule: ziHourRule),
                inSameDayAs: businessDate
            )
            // 探测前置门(2026-10-07 review 修复 #5):.idle 之外(已有今日解读
            // .okFree / 读缓存失败 .failed)不发探测——探测含 identity resolve
            // (一次 health 往返),对注定不触发的管线是纯浪费;次数有余时零
            // 探测直接可触发。
            guard case .idle = interpretState, isBusinessDateStillCurrent else { return }
            // L5(2026-10-07 review 修复):次数耗尽但存在可翻译的跨语言源 →
            // 仍自动触发(翻译不耗次数,守住「换语言当天也有解读」拍板;
            // 此前 remainingReads > 0 一刀切,耗尽 + 切语言 = 当天无解读,
            // L5/F3 的承诺被本门槛挡死)。无源则维持原门槛:不发起注定
            // dailyLimitReached 的空调用,避免每次进页闪一段 fetching 转圈。
            var canAutoTrigger = remainingReads > 0
            if !canAutoTrigger {
                canAutoTrigger = await orchestrator.hasCrossLanguageDailySource(
                    chartHash: chartHash, targetDate: businessDate
                )
                // 探针挂起窗口内新管线可能已接管(refresh 不经
                // determinantTask 取消;换盘走 load 新管线)——本管线属旧
                // 世代时不得再触发:generateInterpretation 读当前 .ready,
                // 旧 chartHash × 新盘 response/payload 会把跨盘内容静默写
                // 进旧盘 24h 缓存键。
                guard pipelineGeneration == generation else {
                    let currentGeneration = self.pipelineGeneration
                    AppLogger.app.warning(
                        "daily.runFullPipeline.stale_generation_tail hash=\(chartHash, privacy: .public) gen=\(generation, privacy: .public) current=\(currentGeneration, privacy: .public) — 旧管线尾部自弃,不自动触发"
                    )
                    return
                }
                // 注:探针与后续链内 crossLanguageSourceIfFresh 会各查一次
                // (探针只判有无,链内取全行是权威读)——传行需穿透 VM→
                // orchestrator 三层 plumbing,此处留一次幂等 health+本地读,
                // 换取触发路径单一事实源。
            }
            if !Task.isCancelled, canAutoTrigger {
                generateInterpretation(currentChartHash: chartHash, trigger: .automatic)
            }
        } catch let error as DailyFortuneError where error == .chartMissing {
            guard !Task.isCancelled, pipelineGeneration == generation else { return }
            state = .chartMissing
        } catch is CancellationError {
            return
        } catch {
            await handleNetworkFailureFallback(
                error: error, chartHash: chartHash, businessDate: businessDate,
                generation: generation
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
        error: Error, chartHash: String, businessDate: Date, generation: Int
    ) async {
        // 世代号守卫(2026-10-07 review 修复 #4):本函数体内无挂起点(纯同步
        // 读),入口一次判定即覆盖全部写点——旧管线的离线/失败态同样不得
        // 覆写新管线 UI
        guard pipelineGeneration == generation else {
            AppLogger.app.warning(
                "daily.offline_fallback.stale_generation_drop hash=\(chartHash, privacy: .public) gen=\(generation, privacy: .public) — 旧管线失败态自弃"
            )
            return
        }
        // 非网络类错误不进 fallback(单一事实源 = UserFacingError.
        // isOfflineOrTimeout,第九轮 review #7 收编三份两层解包)
        guard UserFacingError.isOfflineOrTimeout(error) else {
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
        // 2026-09-28 修复:历史正文走 offlineLegacy 进视图渲染(此前塞 .failed 会被
        // 失败降级换成引擎模板,「已保留历史解读」名不副实)。
        // L6/F7:快照语言 ≠ 生效语言 → 加「离线 · 显示的是××版本」小注
        //(离线没有更好的选择,如实标注)。R6(2026-10-02 review):nil 老快照
        //(L6 之前写入)语言未知,不再断言——一律视为 zh 会把英文用户近 7 天
        // 的英文快照误标成「显示的是简体中文版本」;未知就不显示小注。
        var languageNote: String?
        if hasInterpretation,
           let snapshotLanguage = cached.interpretationLanguage,
           snapshotLanguage != AppLanguage.currentWire {
            languageNote = String(
                format: String(localized: "离线 · 显示的是%@版本"),
                AppLanguage.displayName(forWire: snapshotLanguage)
            )
        } else {
            languageNote = nil
        }
        var interpState: InterpretState = hasInterpretation
            ? .offlineLegacy(text: cached.interpretation, languageNote: languageNote)
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
                // S09:离线兜底路径同步刷新判据(runFullPipeline 网络失败时未走到
                // 前置判定;此处与主路径同源,不重推)
                hourGate = bazi.hourUnknownGate
                isHourUnknownAccepted = bazi.isHourSilenced
            } else {
                AppLogger.persistence.error(
                    "daily.offline_fallback.chartSnapshot_missing hash=\(chartHash, privacy: .public)"
                )
                if !hasInterpretation {
                    interpState = .failed(message: L10n.DailyFortune.interpretChartReadFailedOffline)
                }
            }
        } catch {
            AppLogger.persistence.error(
                "daily.offline_fallback.chartPayload_failed hash=\(chartHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            if !hasInterpretation {
                interpState = .failed(message: L10n.DailyFortune.interpretChartReadFailedOffline)
            }
        }

        isOffline = true
        if !Task.isCancelled {
            state = .ready(cachedResponse, interpState, businessDate)
        }
        AppLogger.app.info(
            "daily.offline_fallback hash=\(chartHash, privacy: .public) targetDate=\(businessDate, privacy: .public) hasInterpretation=\(hasInterpretation)"
        )
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
