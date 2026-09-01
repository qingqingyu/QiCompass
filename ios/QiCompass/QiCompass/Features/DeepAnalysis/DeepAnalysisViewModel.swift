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

// MARK: - 时辰未知(D3 二值半夜问题)

/// 「你是否在半夜(约 11 点之后)出生?」三态答案(docs/时辰未知设计决策.md D3)。
///
/// 为什么不是直接 `Bool?`:契约里 nil 同时编码「不确定」与「不传」,但表单必须区分
/// **未选**(默认态,validateForm 拦截)与**不确定**(合法答案)——用枚举承载选择态,
/// 映射到 wire 值时才坍缩成 `Bool?`。
enum LateNightChoice: Equatable {
    case yes
    case no
    case unsure

    /// S01 契约 wire 值:是→true / 否→false / 不确定→nil
    var wireValue: Bool? {
        switch self {
        case .yes: return true
        case .no: return false
        case .unsure: return nil
        }
    }

    /// 展示文案(确认 sheet「未知(半夜:X)」/ chip 标题共用同一事实源)
    var displayText: String {
        switch self {
        case .yes: return L10n.BirthForm.lateNightYes
        case .no: return L10n.BirthForm.lateNightNo
        case .unsure: return L10n.BirthForm.lateNightUnsure
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

    /// 出生日期(S03 拆双 picker:date-only 绑定)。nil = 未选择初始态,
    /// validateForm 拦截「请选择出生日期」——修「默认 1990-03-15 可不碰就提交」的数据质量洞(D8)。
    var birthDate: Date?

    /// 出生时刻独立绑定(S03:与日期拆开)。默认锚点只取其钟面时分(出生地钟面),
    /// 日期分量不参与提交;时辰快捷选(setShichenHour)只改写本绑定。
    var birthTime: Date = DeepAnalysisViewModel.defaultBirthTimeAnchor

    /// 时刻行初始锚点 = 旧默认 1990-03-15 同一 instant(保留现状默认时刻语义,非提交默认日期)。
    static let defaultBirthTimeAnchor = Date(timeIntervalSince1970: 638_000_000)

    // MARK: 时辰未知(S04,D1 单一入口 + D3 二值半夜问题)

    /// 是否知道出生时刻(D1 单一入口系统分流)。默认 true = 老路径;
    /// false 时时刻行/时辰快捷选收起,提交走三柱降级契约(hour_known=false)。
    var hourKnown: Bool = true

    /// 半夜三态答案(D3)。nil = **未选**(勾选「不知道」后必须选一个才可提交,
    /// validateForm 拦截)——与 `.unsure`(合法答案)显式区分,见 `LateNightChoice`。
    /// 仅 hourKnown=false 时有意义;取消勾选由 `setHourKnown(true)` 重置。
    var lateNightChoice: LateNightChoice?

    /// 契约值(buildRequest 用):是→true / 否→false / 不确定→nil。
    /// hourKnown=true 时恒 nil(后端忽略,不传混淆值)。
    var lateNight: Bool? {
        guard !hourKnown else { return nil }
        return lateNightChoice?.wireValue
    }

    var gender: String = "male"
    /// 出生地(S03 城市搜索 / S05 自定义地点;无默认,必选——砍「北京」默认是数据质量决策)
    var selectedPlace: PlaceSelection?
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

    /// M4 用户输入(Stage 8;盘面小景 S3 起由阅读页页内表单 ChapterReadingInputForm 填写)。
    /// nil = 用户尚未填 → M4 模块标 .needsInput,等用户填。
    /// 非 nil = 用户填过 → runSingleV1Module(.m4) 用此值调 orchestrator。
    /// 外部只读(submitM4Input 写入),避免绕过 submit 路径(不会触发 retry)。
    private(set) var m4UserInput: (age: Int, concern: String)?
    /// M5 用户输入(Stage 8;盘面小景 S3 起由阅读页页内表单填写)。
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

    /// 出生地时区 Calendar:DatePicker/时辰快捷选挂它,表盘即出生地钟面。
    /// 只做显示与钟面提取,**不做 naive→UTC 换算**(后端 zoneinfo 负责,S02 契约)。
    /// 时区解析走 `BirthPlaceResolver` 单一事实源(城市/自定义地点,S05)。
    var placeCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        let tzName = BirthPlaceResolver.effectiveTimezoneName(selectedPlace)
        if let tzName, let tz = TimeZone(identifier: tzName) {
            calendar.timeZone = tz
        } else {
            calendar.timeZone = .current
        }
        return calendar
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

    // MARK: - 出生日期/时刻展示串(S03 拆双 picker;表单时刻行与确认 sheet 共用)

    /// 出生日期串(yyyy-MM-dd,出生地钟面);未选择 → nil(调用方自行展示占位/—)。
    var wallBirthDateString: String? {
        guard let birthDate else { return nil }
        return Self.fixedWallFormatter(template: "yyyy-MM-dd", timeZone: placeCalendar.timeZone)
            .string(from: birthDate)
    }

    /// 出生时刻串(HH:mm,出生地钟面;取 birthTime 的时分)。
    var wallBirthTimeString: String {
        Self.fixedWallFormatter(template: "HH:mm", timeZone: placeCalendar.timeZone)
            .string(from: birthTime)
    }

    /// 固定模板钟面 formatter(展示用,POSIX locale 防系统格式注入)。
    private static func fixedWallFormatter(template: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = template
        formatter.timeZone = timeZone
        return formatter
    }

    /// 合并日期行 + 时刻行 → 完整出生 Date(出生地钟面:Y/M/D 取 birthDate,H/M 取 birthTime,秒归 0)。
    /// birthDate 未选择 / Calendar 合成失败 → 显式抛错(错误显式传播,禁止 `?? Date()` 静默兜底);
    /// 提交路径(validateForm 先行)保证走到这里时 birthDate 已非空。
    /// 时辰未知(S04):hourKnown=false 时时分显式用 **12:00 占位**(后端归一同值,
    /// 双端一致减少歧义;birthTime 的时分被 flag 否定,不参与)。
    private func combinedBirthDate() throws -> Date {
        guard let birthDate else {
            throw UserFacingError.generic(message: L10n.BirthForm.errorDateRequired)
        }
        let calendar = placeCalendar
        let hour = hourKnown ? calendar.component(.hour, from: birthTime) : 12
        let minute = hourKnown ? calendar.component(.minute, from: birthTime) : 0
        guard let combined = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: birthDate
        ) else {
            throw UserFacingError.generic(message: L10n.BirthForm.errorCombineFailed)
        }
        return combined
    }

    /// 确认 sheet 时刻行文案(S04):已知 → HH:mm;未知 →「未知(半夜:是/否/不确定)」。
    /// 勾选但三态未选时确认 sheet 仍可先于校验出现(onSubmit → sheet → calculate),
    /// 此刻诚实展示「半夜:未答」,提交在 calculate 内被 formInvalid 拦截。
    var confirmBirthTimeText: String {
        guard !hourKnown else { return wallBirthTimeString }
        guard let choice = lateNightChoice else {
            return L10n.BirthForm.confirmTimeUnknownNoAnswer
        }
        return L10n.BirthForm.confirmTimeUnknown(choice.displayText)
    }

    // MARK: - 表单校验

    /// 校验表单,返回错误信息数组(空 = 通过)。
    /// S03:日期必选(未选择 → 「请选择出生日期」);「不晚于当下」按日期+时刻合成值校验(语义保留)。
    /// S04:勾选「不知道出生时刻」后半夜三态**必须选一个**(未选 → 拦截,不默认「不确定」
    /// ——避免又一层默认假答案);时辰未知时「不晚于当下」降为日期粒度(12:00 占位
    /// 不参与判定,当日出生不误拦)。
    func validateForm() -> [String] {
        var errors: [String] = []
        if birthDate == nil {
            errors.append(L10n.BirthForm.errorDateRequired)
        }
        if !hourKnown && lateNightChoice == nil {
            errors.append(L10n.BirthForm.errorLateNightRequired)
        }
        if let birthDate {
            do {
                if hourKnown {
                    if try combinedBirthDate() > Date() {
                        errors.append("出生时间不能晚于当下")
                    }
                } else if placeCalendar.compare(birthDate, to: Date(), toGranularity: .day) == .orderedDescending {
                    errors.append("出生时间不能晚于当下")
                }
            } catch {
                // 合成失败(理论不可达):不静默——打日志;提交路径 buildRequest 会显式抛错
                AppLogger.app.warning("deepVM.validateForm combine_failed error=\(String(describing: error), privacy: .public)")
            }
        }
        if selectedPlace == nil {
            errors.append("请选择出生城市")
        }
        if let selectedPlace, !selectedPlace.isCustomLongitudeValid {
            errors.append("经度需在 -180 到 180 之间")
        }
        return errors
    }

    /// 从表单构造请求(S02 契约:裸钟面 + timezone + 物理真值;S04 增 hour_known/late_night)。
    /// place_name/geoname_id/latitude 是存档展示元数据,不参与 content_hash。
    /// 出生地字段解析走 `BirthPlaceResolver` 单一事实源(S05:城市/自定义地点)。
    func buildRequest() throws -> BaziCalculateRequest {
        guard let selectedPlace else {
            // validateForm 先行拦截,理论不可达;显式抛错不静默(错误显式传播)
            throw UserFacingError.generic(message: "请选择出生城市")
        }
        // birthDate 未选择 / 合成失败在此显式抛错(combinedBirthDate 文档见上)
        let birthDateTime = try combinedBirthDate()
        let resolved = BirthPlaceResolver.resolve(selectedPlace)
        return BaziCalculateRequest(
            birthDatetime: wallTimeString(for: birthDateTime),
            timezone: resolved.timezone,
            gender: gender,
            longitude: resolved.longitude,
            latitude: resolved.latitude,
            placeName: resolved.placeName,
            geonameId: resolved.geonameId,
            ziHourRule: ziHourRule,
            hourKnown: hourKnown,
            lateNight: lateNight
        )
    }

    // MARK: - 时辰未知入口(D1)

    /// 切换「不知道出生时刻」。取消勾选(known=true)时**重置**三态答案
    /// ——回到有时刻路径,半夜答案作废(不残留到下一次勾选,避免假答案跨态泄漏);
    /// birthTime 保留原值(恢复时刻行时所见即所得)。
    func setHourKnown(_ known: Bool) {
        hourKnown = known
        if known {
            lateNightChoice = nil
        }
        AppLogger.app.info("deepVM.setHourKnown known=\(known, privacy: .public)")
    }

    // MARK: - 时辰快捷选

    /// 时辰快捷选:把 birthTime 的 hour 设为指定值(方案 §4.3;S03 起改写时刻绑定,日期不动)。
    /// 传入该时辰的中点小时(子=0, 丑=2, 寅=4 ... 亥=22)。
    /// 用出生城市 Calendar —— 表盘是出生地钟面(WYSIWYG),不随设备时区漂移。
    func setShichenHour(_ hour: Int) {
        if let newTime = placeCalendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: birthTime
        ) {
            birthTime = newTime
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
        AppLogger.app.info("deepVM.calculate.start birth=\(birthDate?.description ?? "nil") gender=\(gender, privacy: .public) place=\(selectedPlace?.displayLabel ?? "nil", privacy: .public)")
        let errors = validateForm()
        if !errors.isEmpty {
            // 规则 1:表单校验失败抛错前打 warning(用户预期)
            AppLogger.app.warning("deepVM.calculate.form_invalid errors=\(errors.joined(separator: "; "), privacy: .public)")
            state = .formInvalid(errors)
            return
        }

        calculateTask?.cancel()

        // validateForm 已拦截未选日期/地点;buildRequest throws 属防御性显式传播,
        // 失败原因透传给 formInvalid(不硬编码城市错误——S03 起也可能是日期/合成错误)
        let request: BaziCalculateRequest
        do {
            request = try buildRequest()
        } catch {
            AppLogger.app.warning("deepVM.calculate.buildRequest_failed error=\(String(describing: error), privacy: .public)")
            let message = (error as? UserFacingError)?.errorDescription
                ?? (error as? LocalizedError)?.errorDescription
                ?? "表单信息不完整,请检查后重试"
            state = .formInvalid([message])
            return
        }
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

    // MARK: - 存档直读(2026-08-16 深度解析 Tab 免重复填表)

    /// 从本地存档直读命盘(DeepAnalysisView 启动时 resolve 到最新 UserSnapshotLink 后调用)。
    ///
    /// 与 calculate() 的区别:不发网络请求、不重复存档(盘 + link 已在),只把 VM
    /// 拉到 .ready —— 对齐 2026-08-01 决策 #4「chart 立即可见」;AI 命书仍走
    /// β 点击触发(InterpretState 从 .idle 起步)。
    /// request 由 `ChartSnapshot.archivedDisplayRequest` 重建(仅展示/prompt context 用)。
    /// 不触发 onChartArchived:非新建存档;pendingReturnTab 消费场景只在无盘走表单
    /// 路径时发生(合盘空态 / 今日运势 chartMissing CTA 引流)。
    func loadArchivedChart(response: BaziResponse, request: BaziCalculateRequest) {
        // 换盘守卫(S10 补时辰 → 新 contentHash):旧盘的 moduleStates(章节文本)与
        // v1ChainFields(structure_fingerprint)对新盘失真——章节文本是 LLM 按旧盘
        // (无时辰)生成的,fingerprint 属旧盘结构;不清洗会让新盘目录显示旧盘「已读」、
        // 阅读页展示旧盘正文、续读把旧 fingerprint 注入新盘请求。同 hash 重入
        // (取消补时辰 / Tab 重挂)不清,保住既有章节态。
        if case .ready(let old, _) = state, old.contentHash != response.contentHash {
            v1ChainTask?.cancel()
            moduleStates.removeAll()
            v1ChainFields.removeAll()
            AppLogger.app.info(
                "deepVM.loadArchivedChart chart_changed oldHash=\(old.contentHash, privacy: .public) newHash=\(response.contentHash, privacy: .public) — v1 链状态已清洗"
            )
        }
        AppLogger.app.info(
            "deepVM.loadArchivedChart contentHash=\(response.contentHash, privacy: .public)"
        )
        lastRequest = request
        state = .ready(response, .idle)
    }

    // MARK: - AI 命书(盘面小景 S2:legacy 单文本路径已删,UI 只走 v1 捌章)

    // generateInterpretation / retryInterpretation / localCachedText(bazi_deep
    // 单文本老路径)随 DeepAnalysisResultView 删除一并移除:新 UI(主页目录 +
    // ChapterReadingView)只消费 moduleStates 的 v1 模块化路径。InterpretState
    // 枚举保留(state 机 .ready 关联值依赖)。老缓存数据不清库,只是不再展示。

    // MARK: - v1 prompt 系统用户输入提交(Stage 8)

    /// M4 用户输入提交(ChapterReadingView 页内表单的 onSubmit 回调)。
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

    /// M5 用户输入提交(ChapterReadingView 页内表单的 onSubmit 回调)。
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
        // S07 纵深防御:日柱歧义 → 免费 2 章(M0/M1)亦拦,不发任何 interpret 请求
        guard response.hourUnknownGate != .dayAmbiguous else {
            AppLogger.app.warning(
                "op=deepAnalysis.generateV1AllModules.skip reason=day_ambiguous contentHash=\(response.contentHash, privacy: .public)"
            )
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
        // S07 纵深防御:日柱歧义 → 免费模块重试亦拦(与 generateV1AllModules 同判据)
        guard response.hourUnknownGate != .dayAmbiguous else {
            AppLogger.app.warning(
                "op=deepAnalysis.retryV1Module.skip reason=day_ambiguous module=\(module.rawValue, privacy: .public)"
            )
            return
        }

        AppLogger.app.info("deepVM.retryV1Module.start module=\(module.rawValue, privacy: .public)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSingleV1Module(module, response: response)
        }
    }

    /// 购买成功后重跑全部 `.locked` 模块(PaywallView onPurchaseSuccess 调,v1 模式)。
    ///
    /// runSingleV1Module 顶部的付费守卫会重新求值(entitlement 已写入)→ 放行正常跑。
    /// 已 ok 的模块不动(不重刷),failed/pending/needsInput 维持原状。
    /// 2026-08-23 断链修复:M2-M7 此前从不置 .locked、购买成功回调走老路径,
    /// v1 链付费模块对用户不可达;本方法 + 守卫补全闭环。
    func retryLockedV1Modules() {
        guard case .ready(let response, _) = state else {
            AppLogger.app.error("op=deepAnalysis.retryLockedV1Modules invalid_state state=\(String(describing: self.state), privacy: .public)")
            return
        }

        let lockedModules = ModuleID.allCases.filter { moduleStates[$0] == .locked }
        guard !lockedModules.isEmpty else {
            AppLogger.app.info("deepVM.retryLockedV1Modules.no_locked_modules")
            return
        }

        AppLogger.app.info("deepVM.retryLockedV1Modules.start count=\(lockedModules.count, privacy: .public) contentHash=\(response.contentHash, privacy: .public)")

        Task { @MainActor [weak self] in
            guard let self else { return }
            for module in lockedModules {
                await self.runSingleV1Module(module, response: response)
            }
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
        // 同盘守卫(双 review P1 修复):retryV1Module / retryLockedV1Modules 的
        // 任务 fire-and-forget 不被持有,loadArchivedChart 换盘清洗只 cancel
        // v1ChainTask——旧盘在飞任务若不清拦,会把旧盘的 locked/needsInput/
        // fetching/ok/failed 写进新盘 moduleStates(跨盘污染:新盘目录显示旧盘
        // 「已读」、阅读页展示旧盘正文)。入口 + await 返回后双检,覆盖全部写点。
        guard isCurrentChart(response) else {
            AppLogger.app.warning(
                "deepVM.runSingleV1Module.stale_chart module=\(module.rawValue, privacy: .public) hash=\(response.contentHash, privacy: .public) — 旧盘任务丢弃"
            )
            return
        }

        // 付费守卫(2026-08-23 断链修复):M2-M7 无 active entitlement → .locked。
        // 不发注定 403 的请求、不消耗每日配额;onUnlock(已装配 PaywallView sheet)
        // 引导购买,购买成功后 retryLockedV1Modules 重跑(此处守卫重查放行)。
        // 守卫覆盖链式启动 / 单模块重试 / 购买后重跑三条路径(单点强制)。
        // locked 优先于 M4/M5 needsInput:未付费先引导解锁,再收用户输入。
        // module 用基础名 "bazi_deep" 查(单 SKU 解锁全部深度付费内容,
        // 与后端 entitlement_base_module 映射、redeem 写入形态三方对齐)。
        if module.isPaid, !hasDeepEntitlement(contentHash: response.contentHash) {
            moduleStates[module] = .locked
            AppLogger.app.info("deepVM.runSingleV1Module.paid_locked module=\(module.rawValue, privacy: .public) contentHash=\(response.contentHash, privacy: .public)")
            return
        }

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
            // 同盘守卫第二检:await 期间可能已换盘(loadArchivedChart 清洗过状态)
            guard isCurrentChart(response) else {
                AppLogger.app.warning(
                    "deepVM.runSingleV1Module.stale_chart_after_await module=\(module.rawValue, privacy: .public) hash=\(response.contentHash, privacy: .public) — 旧盘结果丢弃"
                )
                return
            }

            // 解析 LLM 输出 JSON,提取链式字段给下游模块用
            // 失败不抛(下游模块可能仍能跑,只是字段缺失会触发后端 validate_context 422)
            extractChainFields(from: resp.interpretation, for: module)

            moduleStates[module] = .ok(text: resp.interpretation, cached: resp.cached)
            AppLogger.app.info("deepVM.runSingleV1Module.ok module=\(module.rawValue, privacy: .public) cached=\(resp.cached, privacy: .public)")
        } catch is CancellationError {
            AppLogger.app.info("deepVM.runSingleV1Module.cancelled module=\(module.rawValue, privacy: .public)")
        } catch let error as DeepAnalysisError {
            if !Task.isCancelled && isCurrentChart(response) {
                AppLogger.app.warning("deepVM.runSingleV1Module.deepAnalysisError module=\(module.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
                moduleStates[module] = .failed(message: error.errorDescription ?? "未知错误")
            }
        } catch {
            if !Task.isCancelled && isCurrentChart(response) {
                AppLogger.app.error("deepVM.runSingleV1Module.failed module=\(module.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
                let userError = UserFacingError.from(error, stage: .interpret)
                moduleStates[module] = .failed(message: userError.errorDescription ?? "未知错误")
            }
        }
    }

    /// 同盘判定:入参 response 是否仍是当前 .ready 的命盘(换盘清洗的配套守卫)。
    @MainActor
    private func isCurrentChart(_ response: BaziResponse) -> Bool {
        if case .ready(let now, _) = state {
            return now.contentHash == response.contentHash
        }
        return false
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

    /// 本地 deep entitlement 只读查询(单源):VM 付费守卫(runSingleV1Module)、
    /// 主页目录行 / 沉底 CTA(DeepAnalysisHomeView)、阅读页翻章条 🔒 判定
    /// (ChapterReadingView)三处消费同一参数口径——单 SKU "bazi_deep" 解锁全部
    /// 深度付费章。只读不写,购买成功后 entitlementStore 写入即反映。
    func hasDeepEntitlement(contentHash: String) -> Bool {
        entitlementStore.getActive(
            contentHash: contentHash,
            module: EntitlementModule.baziDeep,
            userLocalId: UserIdentity.userLocalId
        ) != nil
    }

    /// 剩余每日次数(用于 UI 展示)。
    var remainingReads: Int {
        orchestrator.remainingReads()
    }

    /// 下次每日重置时间(本地午夜,达上限时用于倒计时)。
    var nextDailyReset: Date {
        orchestrator.nextDailyReset()
    }
}
