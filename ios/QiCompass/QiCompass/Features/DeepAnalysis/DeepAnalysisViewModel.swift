import Foundation
import SwiftUI

// MARK: - 状态机

/// 深度解析主状态机(方案 §一)。
///
/// 关键解耦:AI 命书失败 ≠ 排盘失败。
/// 排盘成功 → `.chartReady`(命盘可见);AI 子状态独立 `.failed` 可重试。
enum DeepAnalysisViewState: Equatable {
    case empty
    case calculating(stage: LoadingStage)
    case chartReady(BaziResponse, InterpretState)
    case chartFailed(UserFacingError)
    case formInvalid([String])

    static func == (lhs: DeepAnalysisViewState, rhs: DeepAnalysisViewState) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty): return true
        case (.calculating(let a), .calculating(let b)): return a == b
        case (.chartFailed(let a), .chartFailed(let b)): return a == b
        case (.formInvalid(let a), .formInvalid(let b)): return a == b
        case (.chartReady(let a1, let a2), .chartReady(let b1, let b2)):
            // response 用 contentHash 作相等性代理(完整比较太重,对齐 CompatibilityViewModel 实现)
            // 关键:必须比较 InterpretState(a2 == b2),否则 .idle → .fetching 会被判等,
            // 导致 @Observable 不触发 View 重渲染,按钮看起来"完全没反应"
            return a1.contentHash == b1.contentHash && a2 == b2
        default: return false
        }
    }
}

/// 排盘阶段细分文案(方案 §一 LoadingStage)。
enum LoadingStage: Equatable {
    case calculatingChart
    case archiving
    case generatingInterpret

    var text: String {
        switch self {
        case .calculatingChart:   return "排盘中…"
        case .archiving:          return "存档中…"
        case .generatingInterpret: return "生成命书中…"
        }
    }
}

// MARK: - ViewModel

/// 深度解析 ViewModel:@Observable + 状态机驱动。
///
/// 持有表单状态 + 主状态机,调用 DeepAnalysisOrchestrator 编排排盘/解读。
/// 错误显式传播:orchestrator 抛错转对应 state,不吞不静默。
@Observable
@MainActor
final class DeepAnalysisViewModel {

    // MARK: 表单状态

    var birthDate: Date = Date(timeIntervalSince1970: 638_000_000) // 默认 1990-03-15
    var gender: String = "male"
    var selectedCity: String = "北京"
    var useManualLongitude: Bool = false
    var manualLongitude: Double = 116.41
    var ziHourRule: String = "zi_next_day"

    // MARK: 主状态

    var state: DeepAnalysisViewState = .empty

    // MARK: 依赖

    private let orchestrator: DeepAnalysisOrchestrator
    /// M3c 新增:entitlement 查询(决定 module 切 _free / _paid)
    private let entitlementStore: EntitlementStore
    private(set) var lastRequest: BaziCalculateRequest?
    private var calculateTask: Task<Void, Never>?
    private var interpretTask: Task<Void, Never>?

    init(orchestrator: DeepAnalysisOrchestrator, entitlementStore: EntitlementStore) {
        self.orchestrator = orchestrator
        self.entitlementStore = entitlementStore
    }

    // MARK: - 表单校验

    /// 校验表单,返回错误信息数组(空 = 通过)。
    func validateForm() -> [String] {
        var errors: [String] = []
        if birthDate > Date() {
            errors.append("出生时间不能晚于当下")
        }
        if !useManualLongitude && selectedCity.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("请选择城市,或开启手动经度输入")
        }
        if useManualLongitude && !(-180.0...180.0).contains(manualLongitude) {
            errors.append("经度需在 -180 到 180 之间")
        }
        return errors
    }

    /// 从表单构造请求(useManualLongitude 时 city=nil,否则 longitude=nil)。
    func buildRequest() -> BaziCalculateRequest {
        let city: String? = useManualLongitude ? nil : selectedCity
        let longitude: Double? = useManualLongitude ? manualLongitude : nil
        return BaziCalculateRequest(
            birthDatetime: birthDate,
            gender: gender,
            city: city,
            longitude: longitude,
            ziHourRule: ziHourRule
        )
    }

    // MARK: - 时辰快捷选

    /// 时辰快捷选:把 birthDate 的 hour 设为指定值(方案 §4.3)。
    /// 传入该时辰的中点小时(子=0, 丑=2, 寅=4 ... 亥=22)。
    func setShichenHour(_ hour: Int) {
        let calendar = Calendar.current
        if let newDate = calendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: birthDate
        ) {
            birthDate = newDate
        }
    }

    // MARK: - 排盘

    /// 触发排盘:先校验表单,再调 orchestrator.runCalculation。
    /// 取消旧 Task 避免竞态(快速点击两次时后完成者不应覆盖新状态)。
    func calculate() {
        // 规则 2:用户主动触发的入口日志
        // 技术坑:OSLogMessage 字符串插值是 lazy capture,instance property 必须先提到 local
        let birthDate = self.birthDate
        let gender = self.gender
        let selectedCity = self.selectedCity
        let useManualLongitude = self.useManualLongitude
        AppLogger.app.info("deepVM.calculate.start birth=\(birthDate.description, privacy: .public) gender=\(gender, privacy: .public) city=\(selectedCity, privacy: .public) useManualLon=\(useManualLongitude, privacy: .public)")
        let errors = validateForm()
        if !errors.isEmpty {
            // 规则 1:表单校验失败抛错前打 warning(用户预期)
            AppLogger.app.warning("deepVM.calculate.form_invalid errors=\(errors.joined(separator: "; "), privacy: .public)")
            state = .formInvalid(errors)
            return
        }

        calculateTask?.cancel()

        let request = buildRequest()
        lastRequest = request
        state = .calculating(stage: .calculatingChart)

        calculateTask = Task {
            do {
                let response = try await orchestrator.runCalculation(request: request)
                if !Task.isCancelled {
                    AppLogger.app.info("deepVM.calculate.ok contentHash=\(response.contentHash, privacy: .public)")
                    state = .chartReady(response, .idle)
                }
            } catch is CancellationError {
                // 被取消,不更新状态(新 Task 会接管)
                AppLogger.app.info("deepVM.calculate.cancelled")
            } catch {
                if !Task.isCancelled {
                    // 规则 1:抛错前打 error(orchestrator 内部已打,VM 层再打 state 转换)
                    AppLogger.app.error("deepVM.calculate.failed error=\(String(describing: error), privacy: .public)")
                    state = .chartFailed(UserFacingError.from(error, stage: .chart))
                }
            }
        }
    }

    func retryCalculation() {
        calculate()
    }

    // MARK: - AI 命书

    /// 触发 AI 命书生成(用户点"生成命书"按钮 / 购买成功后重新触发)。
    /// 取消旧 Task 避免竞态(快速点击两次时后完成者不应覆盖新状态)。
    ///
    /// M3c 改造:查本地 entitlement 决定 module
    /// - 有 active entitlement → `bazi_deep_paid` → 成功显示 .okPaid(5 章)
    /// - 无 entitlement → `bazi_deep_free` → 成功显示 .okFree(2 章)
    /// 购买成功后(PaywallView dismiss)再次调用本方法,自动切到 _paid。
    func generateInterpretation() {
        guard case .chartReady(let response, _) = state else {
            // 不静默吞(CLAUDE.md 全局约束):UI 收到点击说明状态机错乱,显式记录
            AppLogger.app.error("op=deepAnalysis.generateInterpretation invalid_state state=\(String(describing: self.state), privacy: .public)")
            return
        }
        guard let request = lastRequest else {
            AppLogger.app.error("op=deepAnalysis.generateInterpretation missing_request")
            state = .chartReady(response, .failed(message: "请求记录缺失,请重新排盘"))
            return
        }

        // M3c 新增:查本地 entitlement 决定 module(基础名 "bazi_deep")
        let hasEntitlement = entitlementStore.getActive(
            contentHash: response.contentHash,
            module: EntitlementModule.baziDeep,
            userLocalId: UserIdentity.userLocalId
        ) != nil
        let module = hasEntitlement ? "bazi_deep_paid" : "bazi_deep_free"
        // 规则 2:用户主动触发 + 付费分支决策日志
        AppLogger.app.info("deepVM.generateInterpretation.start contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) hasEntitlement=\(hasEntitlement, privacy: .public)")

        interpretTask?.cancel()

        state = .chartReady(response, .fetching)

        interpretTask = Task {
            do {
                let resp = try await orchestrator.runInterpretation(
                    response: response,
                    request: request,
                    module: module
                )
                if !Task.isCancelled {
                    if hasEntitlement {
                        state = .chartReady(response, .okPaid(text: resp.interpretation, cached: resp.cached))
                    } else {
                        state = .chartReady(response, .okFree(text: resp.interpretation, cached: resp.cached))
                    }
                }
            } catch is CancellationError {
                // 被取消,不更新状态
                AppLogger.app.info("deepVM.generateInterpretation.cancelled")
            } catch let error as DeepAnalysisError {
                if !Task.isCancelled {
                    // 规则 1:DeepAnalysisError 抛错前打日志
                    AppLogger.app.warning("deepVM.generateInterpretation.deepAnalysisError error=\(String(describing: error), privacy: .public)")
                    // dailyLimitReached 独立形态(方案 step 4):禁用生成按钮、不显示重试
                    if case .dailyLimitReached(let reset, _) = error {
                        state = .chartReady(response, .dailyLimitReached(nextReset: reset))
                    } else {
                        state = .chartReady(response, .failed(message: error.errorDescription ?? "未知错误"))
                    }
                }
            } catch {
                if !Task.isCancelled {
                    // 规则 1:其他错误抛错前打日志
                    AppLogger.app.error("deepVM.generateInterpretation.failed error=\(String(describing: error), privacy: .public)")
                    let userError = UserFacingError.from(error, stage: .interpret)
                    if case .dailyLimitReached(let reset) = userError {
                        state = .chartReady(response, .dailyLimitReached(nextReset: reset))
                    } else {
                        state = .chartReady(response, .failed(message: userError.errorDescription ?? "未知错误"))
                    }
                }
            }
        }
    }

    func retryInterpretation() {
        generateInterpretation()
    }

    // MARK: - 重置

    /// 回到表单态(保留表单输入)。
    /// 取消进行中的 Task,避免状态回退后被旧结果覆盖。
    func reset() {
        calculateTask?.cancel()
        interpretTask?.cancel()
        state = .empty
        lastRequest = nil
    }

    // MARK: - 查询

    /// 剩余每日次数(用于 UI 展示)。
    var remainingReads: Int {
        orchestrator.remainingReads()
    }

    /// 下次每日重置时间(本地午夜,达上限时用于倒计时)。
    var nextDailyReset: Date {
        orchestrator.nextDailyReset()
    }

    /// 本地缓存的命书(用于 UI 瞬时显示,方案 §4.5 v1 不跳过网络)。
    func localCachedText(for response: BaziResponse) async throws -> String? {
        try await orchestrator.localCachedInterpretation(
            contentHash: response.contentHash,
            module: "bazi_deep"
        )?.text
    }
}
