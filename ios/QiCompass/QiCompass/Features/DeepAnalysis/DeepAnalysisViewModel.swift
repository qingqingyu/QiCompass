import Foundation
import SwiftUI

// MARK: - 状态机

/// 深度解析主状态机(方案 §一)。
///
/// 关键解耦:AI 命书失败 ≠ 排盘失败。
/// 排盘成功 → `.ready`(命盘可见);AI 子状态独立 `.failed` 可重试。
enum DeepAnalysisViewState: Equatable {
    case empty
    case calculating(stage: LoadingStage)
    case ready(BaziResponse, InterpretState)
    case chartFailed(UserFacingError)
    case formInvalid([String])

    static func == (lhs: DeepAnalysisViewState, rhs: DeepAnalysisViewState) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty): return true
        case (.calculating(let a), .calculating(let b)): return a == b
        case (.chartFailed(let a), .chartFailed(let b)): return a == b
        case (.formInvalid(let a), .formInvalid(let b)): return a == b
        case (.ready(let a1, let a2), .ready(let b1, let b2)):
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
    /// 出生地(S03:城市搜索选择;无默认城市,必选——砍「北京」默认是数据质量决策)
    var selectedPlace: CityRecord?
    /// 旧「手动经度」过渡开关(S05 升级为「自定义地点」:经度+时区必填)。
    /// 过渡期 timezone 用设备时区——出生地与设备时区一致的常见场景下正确。
    var useManualLongitude: Bool = false
    var manualLongitude: Double = 116.41
    var ziHourRule: String = "zi_next_day"
    /// 命盘别名(v2 PR1):默认"我自己",用户可改为"妈妈"/"男友"等区分多命盘。
    /// 提交时传给 orchestrator.runCalculation 写入 UserSnapshotLink。
    var alias: String = "我自己"

    // MARK: 主状态

    var state: DeepAnalysisViewState = .empty

    // MARK: v1 prompt 系统状态(Stage 7c 引入)

    /// 8 模块独立状态(M0-M7),与现有 InterpretState 并存。
    /// VM 用 generateV1AllModules() 链式编排,失败可单独重试(retryV1Module)。
    /// 老路径(generateInterpretation)用现有 InterpretState,不受此字段影响。
    var moduleStates: [ModuleID: ModuleState] = [:]

    /// v1 链式调用累积的字段(M0 输出的 structure_fingerprint / main_axis / core_loop 等),
    /// 跨多次 runV1Module 调用共享。M0 成功后填充,M1-M7 各自从这里取注入 context。
    /// 失败重试时复用已成功的上游字段(不重跑整个链)。
    private var v1ChainFields: [String: String] = [:]

    /// M4 用户输入(Stage 8):用户通过 HealthInputForm sheet 填写。
    /// nil = 用户尚未填 → M4 模块标 .needsInput,等用户填。
    /// 非 nil = 用户填过 → runSingleV1Module(.m4) 用此值调 orchestrator。
    /// 外部只读(submitM4Input 写入),避免绕过 submit 路径(不会触发 retry)。
    private(set) var m4UserInput: (age: Int, concern: String)?
    /// M5 用户输入(Stage 8):用户通过 WealthInputForm sheet 填写。
    /// nil = 用户尚未填 → M5 模块标 .needsInput,等用户填。
    /// 外部只读(submitM5Input 写入),避免绕过 submit 路径(不会触发 retry)。
    private(set) var m5UserInput: (assets: String, preference: String)?

    /// v1 链式调用 Task(用户重新触发或 reset 时取消)。
    private var v1ChainTask: Task<Void, Never>?

    // MARK: 依赖

    private let orchestrator: DeepAnalysisOrchestrator
    /// M3c 新增:entitlement 查询(决定 module 切 _free / _paid)
    private let entitlementStore: EntitlementStore
    private(set) var lastRequest: BaziCalculateRequest?
    private var calculateTask: Task<Void, Never>?
    private var interpretTask: Task<Void, Never>?

    /// 排盘连续失败计数(生肖阶段 3:连续 ≥3 次切 `.persistentFailure`,隐藏 retry 引导重启)。
    /// 生命周期 = VM 实例;成功一次即归零。非持久化(重启 App 自然重置,避免用户陷入死循环)。
    private var failureCount: Int = 0

    /// 排盘 + 存档(UserSnapshotLink)成功后回调一次。
    /// DeepAnalysisView 用它消费 `env.pendingReturnTab`,把用户切回原 Tab(合盘 / 每日运势)。
    /// nil 时无操作,保持当前 Tab。
    var onChartArchived: (() -> Void)?

    init(orchestrator: DeepAnalysisOrchestrator, entitlementStore: EntitlementStore) {
        self.orchestrator = orchestrator
        self.entitlementStore = entitlementStore
    }

    // MARK: - 出生地时区(WYSIWYG)

    /// 出生城市时区 Calendar:DatePicker/时辰快捷选挂它,表盘即出生地钟面。
    /// 只做显示与钟面提取,**不做 naive→UTC 换算**(后端 zoneinfo 负责,S02 契约)。
    var placeCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        if let tzName = effectiveTimezoneName, let tz = TimeZone(identifier: tzName) {
            calendar.timeZone = tz
        } else {
            calendar.timeZone = .current
        }
        return calendar
    }

    /// 请求用的 IANA 时区名:城市优先;手动经度过渡期用设备时区(S05 换掉)。
    private var effectiveTimezoneName: String? {
        selectedPlace?.timezone
    }

    /// 从 birthDate(绝对时刻)提取出生地**裸钟面**字符串(yyyy-MM-dd'T'HH:mm:ss)。
    /// S02 契约:钟面解释在后端 zoneinfo 完成。
    private static let wallFormatTemplate = "yyyy-MM-dd'T'HH:mm:ss"

    private func wallTimeString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Self.wallFormatTemplate
        formatter.timeZone = placeCalendar.timeZone
        return formatter.string(from: date)
    }

    // MARK: - 表单校验

    /// 校验表单,返回错误信息数组(空 = 通过)。
    func validateForm() -> [String] {
        var errors: [String] = []
        if birthDate > Date() {
            errors.append("出生时间不能晚于当下")
        }
        if !useManualLongitude && selectedPlace == nil {
            errors.append("请选择出生城市")
        }
        if useManualLongitude && !(-180.0...180.0).contains(manualLongitude) {
            errors.append("经度需在 -180 到 180 之间")
        }
        return errors
    }

    /// 从表单构造请求(S02 契约:裸钟面 + timezone + 物理真值)。
    /// place_name/geoname_id/latitude 是存档展示元数据,不参与 content_hash。
    func buildRequest() -> BaziCalculateRequest {
        let timezone: String
        let longitude: Double
        let latitude: Double?
        let placeName: String?
        let geonameId: Int?

        if let place = selectedPlace {
            timezone = place.timezone
            longitude = place.longitude
            latitude = place.latitude
            placeName = place.displayName
            geonameId = place.geonameId
        } else {
            // 手动经度过渡路径(S05 升级):时区暂用设备时区
            timezone = TimeZone.current.identifier
            longitude = manualLongitude
            latitude = nil
            placeName = nil
            geonameId = nil
        }

        return BaziCalculateRequest(
            birthDatetime: wallTimeString(for: birthDate),
            timezone: timezone,
            gender: gender,
            longitude: longitude,
            latitude: latitude,
            placeName: placeName,
            geonameId: geonameId,
            ziHourRule: ziHourRule
        )
    }

    // MARK: - 时辰快捷选

    /// 时辰快捷选:把 birthDate 的 hour 设为指定值(方案 §4.3)。
    /// 传入该时辰的中点小时(子=0, 丑=2, 寅=4 ... 亥=22)。
    /// 用出生城市 Calendar —— 表盘是出生地钟面(WYSIWYG),不随设备时区漂移。
    func setShichenHour(_ hour: Int) {
        if let newDate = placeCalendar.date(
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
        let selectedPlace = self.selectedPlace
        let useManualLongitude = self.useManualLongitude
        AppLogger.app.info("deepVM.calculate.start birth=\(birthDate.description) gender=\(gender, privacy: .public) place=\(selectedPlace?.displayName ?? "nil", privacy: .public) tz=\(selectedPlace?.timezone ?? TimeZone.current.identifier, privacy: .public) useManualLon=\(useManualLongitude, privacy: .public)")
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
                let response = try await orchestrator.runCalculation(request: request, alias: alias)
                if !Task.isCancelled {
                    AppLogger.app.info("deepVM.calculate.ok contentHash=\(response.contentHash, privacy: .public)")
                    failureCount = 0
                    state = .ready(response, .idle)
                    // 命盘 + link 已落档。若用户从合盘/每日运势 CTA 切来,触发切回。
                    onChartArchived?()
                }
            } catch is CancellationError {
                // 被取消,不更新状态(新 Task 会接管)
                AppLogger.app.info("deepVM.calculate.cancelled")
            } catch {
                if !Task.isCancelled {
                    failureCount += 1
                    // 规则 1:抛错前打 error + 当前失败次数(orchestrator 内部已打,VM 层再打 state 转换)
                    AppLogger.app.error("deepVM.calculate.failed count=\(self.failureCount) error=\(String(describing: error), privacy: .public)")
                    // 生肖阶段 3:连续 ≥3 次失败切 persistentFailure,引导重启 App(不显示 retry)
                    let userError: UserFacingError = failureCount >= 3
                        ? .persistentFailure
                        : UserFacingError.from(error, stage: .chart)
                    state = .chartFailed(userError)
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
        guard case .ready(let response, _) = state else {
            // 不静默吞(CLAUDE.md 全局约束):UI 收到点击说明状态机错乱,显式记录
            AppLogger.app.error("op=deepAnalysis.generateInterpretation invalid_state state=\(String(describing: self.state), privacy: .public)")
            return
        }
        guard let request = lastRequest else {
            AppLogger.app.error("op=deepAnalysis.generateInterpretation missing_request")
            state = .ready(response, .failed(message: "请求记录缺失,请重新排盘"))
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

        state = .ready(response, .fetching)

        interpretTask = Task {
            do {
                let resp = try await orchestrator.runInterpretation(
                    response: response,
                    request: request,
                    module: module
                )
                if !Task.isCancelled {
                    if hasEntitlement {
                        state = .ready(response, .okPaid(text: resp.interpretation, cached: resp.cached))
                    } else {
                        state = .ready(response, .okFree(text: resp.interpretation, cached: resp.cached))
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
                        state = .ready(response, .dailyLimitReached(nextReset: reset))
                    } else {
                        state = .ready(response, .failed(message: error.errorDescription ?? "未知错误"))
                    }
                }
            } catch {
                if !Task.isCancelled {
                    // 规则 1:其他错误抛错前打日志
                    AppLogger.app.error("deepVM.generateInterpretation.failed error=\(String(describing: error), privacy: .public)")
                    let userError = UserFacingError.from(error, stage: .interpret)
                    if case .dailyLimitReached(let reset) = userError {
                        state = .ready(response, .dailyLimitReached(nextReset: reset))
                    } else {
                        state = .ready(response, .failed(message: userError.errorDescription ?? "未知错误"))
                    }
                }
            }
        }
    }

    func retryInterpretation() {
        generateInterpretation()
    }

    // MARK: - v1 prompt 系统用户输入提交(Stage 8)

    /// M4 用户输入提交(HealthInputForm sheet 的 onSubmit 回调)。
    /// 写入 m4UserInput + 若 M4 当前是 .needsInput 则触发自动重试。
    /// 注:上游依赖(M0)是否 ok 由 runSingleV1Module 内部守卫处理(缺失时标 .pending)。
    func submitM4Input(age: Int, concern: String) {
        m4UserInput = (age, concern)
        // age 非敏感(concern 含健康信息 → privacy)
        AppLogger.app.info("deepVM.submitM4Input age=\(age) concern=\(concern, privacy: .private)")
        if moduleStates[.m4] == .needsInput {
            retryV1Module(.m4)
        }
    }

    /// M5 用户输入提交(WealthInputForm sheet 的 onSubmit 回调)。
    /// 写入 m5UserInput + 若 M5 当前是 .needsInput 则触发自动重试。
    /// 注:上游依赖(M0+M1+M3)是否 ok 由 runSingleV1Module 内部守卫处理。
    func submitM5Input(assets: String, preference: String) {
        m5UserInput = (assets, preference)
        // assets 含财务信息 → privacy;preference 三选一非敏感但跟随 private 保持一致
        AppLogger.app.info("deepVM.submitM5Input assets=\(assets, privacy: .private) preference=\(preference, privacy: .private)")
        if moduleStates[.m5] == .needsInput {
            retryV1Module(.m5)
        }
    }

    // MARK: - v1 prompt 系统链式调用(Stage 7c)

    /// 触发 v1 prompt 系统全链路调用(M0 → M1-M7 按依赖图执行)。
    ///
    /// 设计要点:
    /// - 8 模块独立状态机(`moduleStates` 字典),失败可单独重试
    /// - M0 失败 → 整链中断,标 M1-M7 保持 .pending(等用户重试 M0)
    /// - 其他模块失败 → 仅标自身 .failed,不影响其他模块(但下游可能因缺依赖卡 pending)
    /// - 链式字段保存在 v1ChainFields,跨重试累积(M0 重跑后会覆盖老 fingerprint)
    /// - 串行执行(简化版,M2/M3/M4/M5 理论可并行但 v1 先稳串行,优化留 v2)
    ///
    /// 计费:每模块独立消耗 1 次每日配额(orchestrator.runV1Module 实现),
    /// 全套 = 8 次/天。命中后端缓存 refund + 失败 refund。
    ///
    /// 用户场景:
    /// - 排盘成功后点 "开始 M0 分析"(ModuleCardView M0 pending 态 CTA)
    /// - 或购买 entitlement 后自动触发(M0+M1 免费,M2-M7 解锁)
    func generateV1AllModules() {
        guard case .ready(let response, _) = state else {
            AppLogger.app.error("op=deepAnalysis.generateV1AllModules invalid_state state=\(String(describing: self.state), privacy: .public)")
            return
        }

        AppLogger.app.info("deepVM.generateV1AllModules.start contentHash=\(response.contentHash, privacy: .public)")

        v1ChainTask?.cancel()

        // 重置所有模块为 .pending(全新开始;单模块重试走 retryV1Module)
        for module in ModuleID.allCases {
            moduleStates[module] = .pending
        }
        v1ChainFields.removeAll()

        v1ChainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runV1Chain(response: response)
        }
    }

    /// 单模块重试(用户点 ModuleCardView 的"重试"CTA)。
    ///
    /// 复用 v1ChainFields 中已成功的上游字段,不重跑整个链。
    /// 例:M4 失败,用户重试 → 只跑 M4,从 v1ChainFields 取 structure_fingerprint 注入。
    /// 若必需的上游字段缺失(罕见,理论上不会发生),抛错并标 .failed。
    func retryV1Module(_ module: ModuleID) {
        guard case .ready(let response, _) = state else {
            AppLogger.app.error("op=deepAnalysis.retryV1Module invalid_state state=\(String(describing: self.state), privacy: .public)")
            return
        }

        AppLogger.app.info("deepVM.retryV1Module.start module=\(module.rawValue, privacy: .public)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSingleV1Module(module, response: response)
        }
    }

    /// 链式调用主循环:按 ModuleID.allCases 顺序串行执行(M0 → M1 → ... → M7)。
    ///
    /// 注:简化版采用全串行;v2 可优化为按依赖图并行(M2/M3/M4/M5 可同时跑)。
    /// 串行好处:状态机简单,失败定位清晰,无并发竞争。
    @MainActor
    private func runV1Chain(response: BaziResponse) async {
        for module in ModuleID.allCases {
            if Task.isCancelled { return }
            await runSingleV1Module(module, response: response)
            // M0 失败 → 中断链(下游缺 structure_fingerprint 无法跑)
            if module == .m0 && moduleStates[.m0]?.isOk != true {
                AppLogger.app.warning("deepVM.runV1Chain m0_failed_breaking_chain contentHash=\(response.contentHash, privacy: .public)")
                return
            }
        }
    }

    /// 跑单个 v1 module。从 moduleStates 取依赖状态,从 v1ChainFields 取链式字段。
    /// 成功后解析 JSON 提取链式字段(structure_fingerprint 等)写入 v1ChainFields。
    ///
    /// Stage 8 改造:M4/M5 用户输入从 VM 状态字段(m4UserInput / m5UserInput)取,
    /// 替代 Stage 7c 的硬编码占位值。若 M4/M5 用户输入为 nil → 标 .needsInput,
    /// 不调 orchestrator(等用户填 sheet 提交后再重试)。
    @MainActor
    private func runSingleV1Module(_ module: ModuleID, response: BaziResponse) async {
        // M4 缺用户输入 → 标 .needsInput,不调 orchestrator
        if module == .m4 && m4UserInput == nil {
            moduleStates[module] = .needsInput
            AppLogger.app.info("deepVM.runSingleV1Module.m4_needs_input contentHash=\(response.contentHash, privacy: .public)")
            return
        }
        // M5 缺用户输入 → 标 .needsInput
        if module == .m5 && m5UserInput == nil {
            moduleStates[module] = .needsInput
            AppLogger.app.info("deepVM.runSingleV1Module.m5_needs_input contentHash=\(response.contentHash, privacy: .public)")
            return
        }

        // 上游依赖守卫:M1-M7 需要 structure_fingerprint;若 M0 未成功(v1ChainFields 缺字段),
        // 不发注定 422 的请求,标 .pending 等用户先重试 M0。
        // 场景:用户在 M4 needsInput 时填了输入 → submitM4Input 自动调 retryV1Module(.m4),
        // 但 M0 可能已失败(网络断 / 日限) → 此处拦回 .pending,不浪费次数。
        if module.requiresParentFingerprint && v1ChainFields["structure_fingerprint"] == nil {
            moduleStates[module] = .pending
            AppLogger.app.warning("deepVM.runSingleV1Module.missing_parent module=\(module.rawValue, privacy: .public) — 标 .pending 等上游重试")
            return
        }

        moduleStates[module] = .fetching

        do {
            let parentFingerprint: String? = module.requiresParentFingerprint
                ? v1ChainFields["structure_fingerprint"]
                : nil

            let resp = try await orchestrator.runV1Module(
                response: response,
                module: module.rawValue,
                parentFingerprint: parentFingerprint,
                m4Input: m4UserInput,
                m5Input: m5UserInput
            )

            if Task.isCancelled { return }

            // 解析 LLM 输出 JSON,提取链式字段给下游模块用
            // 失败不抛(下游模块可能仍能跑,只是字段缺失会触发后端 validate_context 422)
            extractChainFields(from: resp.interpretation, for: module)

            moduleStates[module] = .ok(text: resp.interpretation, cached: resp.cached)
            AppLogger.app.info("deepVM.runSingleV1Module.ok module=\(module.rawValue, privacy: .public) cached=\(resp.cached, privacy: .public)")
        } catch is CancellationError {
            AppLogger.app.info("deepVM.runSingleV1Module.cancelled module=\(module.rawValue, privacy: .public)")
        } catch let error as DeepAnalysisError {
            if !Task.isCancelled {
                AppLogger.app.warning("deepVM.runSingleV1Module.deepAnalysisError module=\(module.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
                moduleStates[module] = .failed(message: error.errorDescription ?? "未知错误")
            }
        } catch {
            if !Task.isCancelled {
                AppLogger.app.error("deepVM.runSingleV1Module.failed module=\(module.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
                let userError = UserFacingError.from(error, stage: .interpret)
                moduleStates[module] = .failed(message: userError.errorDescription ?? "未知错误")
            }
        }
    }

    /// 解析 LLM JSON 输出,提取下游模块需要的链式字段写入 v1ChainFields。
    /// 失败只 log 不抛(下游模块缺字段会触发后端 422,VM 收到再标 .failed)。
    @MainActor
    private func extractChainFields(from llmOutput: String, for module: ModuleID) {
        guard let data = llmOutput.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            AppLogger.app.warning("deepVM.extractChainFields.parse_failed module=\(module.rawValue, privacy: .public)")
            return
        }

        switch module {
        case .m0:
            // M0 产出:structure_fingerprint(字符串)+ main_axis + core_loop(dict)
            if let fp = parsed["structure_fingerprint"] as? String {
                v1ChainFields["structure_fingerprint"] = fp
            }
            if let mainAxis = parsed["main_axis"] {
                if let data = try? JSONSerialization.data(withJSONObject: mainAxis),
                   let str = String(data: data, encoding: .utf8) {
                    v1ChainFields["main_axis"] = str
                }
            }
            if let coreLoop = parsed["core_loop"] {
                if let data = try? JSONSerialization.data(withJSONObject: coreLoop),
                   let str = String(data: data, encoding: .utf8) {
                    v1ChainFields["core_loop"] = str
                }
            }
        case .m1:
            // M1 产出:innate / defensive(数组)+ one_leverage(字符串)
            for field in ["innate", "defensive", "trained"] {
                if let value = parsed[field] {
                    if let data = try? JSONSerialization.data(withJSONObject: value),
                       let str = String(data: data, encoding: .utf8) {
                        v1ChainFields[field] = str
                    }
                }
            }
            if let leverage = parsed["one_leverage"] as? String {
                v1ChainFields["one_leverage"] = leverage
            }
        case .m2:
            // M2 产出:threshold(dict)+ switch_actions(数组)
            if let threshold = parsed["threshold"] {
                if let data = try? JSONSerialization.data(withJSONObject: threshold),
                   let str = String(data: data, encoding: .utf8) {
                    v1ChainFields["threshold"] = str
                }
            }
            if let actions = parsed["switch_actions"] {
                if let data = try? JSONSerialization.data(withJSONObject: actions),
                   let str = String(data: data, encoding: .utf8) {
                    v1ChainFields["switch_actions"] = str
                }
            }
        case .m3:
            // M3 产出:ideal_life_structure(dict)+ environment_checklist(数组)
            if let ideal = parsed["ideal_life_structure"] {
                if let data = try? JSONSerialization.data(withJSONObject: ideal),
                   let str = String(data: data, encoding: .utf8) {
                    v1ChainFields["ideal_life_structure"] = str
                }
            }
            if let checklist = parsed["environment_checklist"] {
                if let data = try? JSONSerialization.data(withJSONObject: checklist),
                   let str = String(data: data, encoding: .utf8) {
                    v1ChainFields["environment_checklist"] = str
                }
            }
        case .m6:
            // M6 产出:leverage(dict)
            if let leverage = parsed["leverage"] {
                if let data = try? JSONSerialization.data(withJSONObject: leverage),
                   let str = String(data: data, encoding: .utf8) {
                    v1ChainFields["leverage"] = str
                }
            }
        case .m4, .m5, .m7:
            // M4/M5/M7 不产出下游需要的链式字段
            break
        }
    }

    // MARK: - 重置

    /// 回到表单态(保留表单输入)。
    /// 取消进行中的 Task,避免状态回退后被旧结果覆盖。
    /// failureCount 也清零(用户主动重置 ≠ 网络故障持续,不应被永久标记)。
    /// Stage 7c:同时取消 v1 链式调用 + 清 moduleStates + v1ChainFields。
    func reset() {
        calculateTask?.cancel()
        interpretTask?.cancel()
        v1ChainTask?.cancel()
        state = .empty
        lastRequest = nil
        failureCount = 0
        moduleStates.removeAll()
        v1ChainFields.removeAll()
        // Stage 8 修复:清 M4/M5 用户输入,避免跨命盘污染
        // (排盘 A 填的 concern 不能给排盘 B 用,违反「八字计算必须确定性」语义)
        m4UserInput = nil
        m5UserInput = nil
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
