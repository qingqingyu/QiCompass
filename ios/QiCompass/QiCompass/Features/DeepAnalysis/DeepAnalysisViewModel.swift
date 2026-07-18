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
    private(set) var lastRequest: BaziCalculateRequest?
    private var calculateTask: Task<Void, Never>?
    private var interpretTask: Task<Void, Never>?

    init(orchestrator: DeepAnalysisOrchestrator) {
        self.orchestrator = orchestrator
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
        let errors = validateForm()
        if !errors.isEmpty {
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
                    state = .chartReady(response, .idle)
                }
            } catch is CancellationError {
                // 被取消,不更新状态(新 Task 会接管)
            } catch {
                if !Task.isCancelled {
                    state = .chartFailed(UserFacingError.from(error, stage: .chart))
                }
            }
        }
    }

    func retryCalculation() {
        calculate()
    }

    // MARK: - AI 命书

    /// 触发 AI 命书生成(用户点"生成命书"按钮)。
    /// 取消旧 Task 避免竞态(快速点击两次时后完成者不应覆盖新状态)。
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

        interpretTask?.cancel()

        state = .chartReady(response, .fetching)

        interpretTask = Task {
            do {
                let resp = try await orchestrator.runInterpretation(
                    response: response,
                    request: request
                )
                if !Task.isCancelled {
                    state = .chartReady(response, .okFree(text: resp.interpretation, cached: resp.cached))
                }
            } catch is CancellationError {
                // 被取消,不更新状态
            } catch let error as DeepAnalysisError {
                if !Task.isCancelled {
                    // dailyLimitReached 独立形态(方案 step 4):禁用生成按钮、不显示重试
                    if case .dailyLimitReached(let reset, _) = error {
                        state = .chartReady(response, .dailyLimitReached(nextReset: reset))
                    } else {
                        state = .chartReady(response, .failed(message: error.errorDescription ?? "未知错误"))
                    }
                }
            } catch {
                if !Task.isCancelled {
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
