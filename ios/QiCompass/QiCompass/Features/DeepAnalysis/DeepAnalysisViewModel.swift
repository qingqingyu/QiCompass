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
/// 阶段文案走 L10n.ChartCalc(2026-09-08 可收起改造收敛:banner 与全屏等待页
/// 展示同一状态,双源必漂移;text 是计算属性不参与 Equatable,迁移无行为影响)。
enum LoadingStage: Equatable {
    case calculatingChart
    case archiving
    case generatingInterpret

    var text: String {
        switch self {
        case .calculatingChart:   return L10n.ChartCalc.stageChart
        case .archiving:          return L10n.ChartCalc.stageArchiving
        case .generatingInterpret: return L10n.ChartCalc.stageGenerating
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
    /// 日期分量不参与提交;时辰快捷选(setShichenHour)只改写本绑定;
    /// 深度表单未选态不显示表盘(空值),揭示时由视图播种正午(见 BirthFormView.timeEmptyState)。
    var birthTime: Date = DeepAnalysisViewModel.defaultBirthTimeAnchor

    /// 时刻是否被用户显式选择(2026-09-23 时刻去默认值,镜像 09-19 日期/性别改造):
    /// false = 未碰 wheel/时辰格的初始态,时刻行显灰占位、validateForm 拦截
    /// 「请选择出生时刻」——修「锚点被当真实值静默提交 → 错时柱」的数据质量洞。
    /// wheel 拨动(表单 binding set)/ setShichenHour 置 true;setHourKnown 不动它
    /// (未知 ↔ 已知来回切,已选时刻所见即所得)。
    var birthTimePicked = false

    /// 时刻/日期表盘初始锚点 = 1990-03-21 **正午 12:00(+08:00 钟面)** instant。
    /// 2026-09-23 二段从 638_000_000(+08 钟面 14:13:20)改为正午:旧值被用户读成
    /// 「默认 14:13」;正午是中性的表盘位置。位置非值——未拨动不构成提交。
    /// 共用:深度表单 birthTime / 合盘 tempBirthTime / AddHourSheet / 合盘日期表盘种子。
    static let defaultBirthTimeAnchor = Date(timeIntervalSince1970: 637_992_000)

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

    /// 性别(2026-09-19 去默认值:nil = 未选初始态,validateForm 拦「请选择性别」
    /// ——不替用户默认 male;选中值 "male"/"female" 与后端契约一致)。
    var gender: String?
    /// 出生地(S03 城市搜索 / S05 自定义地点;无默认,必选——砍「北京」默认是数据质量决策)
    var selectedPlace: PlaceSelection?
    var ziHourRule: String = "zi_next_day"
    /// 命盘别名(v2 PR1):默认"我自己"(2026-09-23 起走 L10n,EN 界面不再夹中文),
    /// 用户可改为"妈妈"/"男友"等区分多命盘。
    /// 提交时传给 orchestrator.runCalculation 写入 UserSnapshotLink。
    var alias: String = L10n.BirthForm.aliasDefault

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

    /// 翻译链 Task(2026-10-07 第五轮 review 补,与 v1ChainTask 对称持有)。
    /// 世代号守卫已拦旧链的状态写入,持有引用的净收益 = 换盘/reset 时能立刻
    /// `cancel()` 在飞翻译请求(协作取消让 URLSession 尽早断开、runSingleV1Module
    /// 提前短路),而非等它在下一个模块边界撞世代守卫自弃。cancel 后链内
    /// CancellationError / 世代失配的既有分诊语义不变(.interrupted 由 defer
    /// 按世代落账)。
    private var translationChainTask: Task<Void, Never>?

    /// v1 链是否在跑(2026-09-08 断点续跑:主页进度横幅 / CTA loading / resume 防重消费)。
    /// 注意 `v1ChainTask != nil` 不能当活跃判据(Task 结束后属性仍非 nil),
    /// 由 `runV1Chain` 的 defer 按世代号复位。
    private(set) var isChainRunning = false

    /// 链世代号:`generateV1AllModules` 取消旧链立刻起新链时,旧链在挂起点恢复后
    /// 的 defer 不得把新链的 `isChainRunning` 掐灭——只有「当代链」能清标志。
    private var chainGeneration = 0

    /// hydrateAndResume 防重入(loadArchivedChart 同 hash 重入 / calculate 并发)。
    /// `private(set)`:测试 teardown 需等回填任务落定再撤 ModelContainer
    /// (在飞 getLatest 踩死容器会 SIGTRAP,2026-09-08 全量测试实踩)。
    /// 注意:换盘/reset 会**同步**复位本标志放行新盘 hydrate,旧 hydrate 仍挂
    /// 在 await 中(世代失配自弃要等挂起点返回)——撤容器等待请用
    /// `inflightHydrateCount`,不要用本标志。
    private(set) var isHydrating = false

    /// 在飞 hydrate 计数(Bug6,2026-10-06):换盘/reset 同步复位 isHydrating 后,
    /// 本标志不再等价「无在飞 hydrate」——teardown 以本计数归零为撤容器依据
    /// (按旧标志等待会提前撤容器,在飞 getLatest 踩死容器 SIGTRAP)。
    /// 计数在 hydrateAndResume 全部早退守卫之后递增,defer 覆盖所有出口。
    private(set) var inflightHydrateCount = 0

    /// hydrate 世代号(换盘推进;2026-10-02 bug 分支修):旧盘 hydrate 在飞
    /// (performRestore await 中)时换盘,同步推进世代 + 复位 isHydrating 让
    /// 新盘 hydrate 不被 reentry 守卫整体吞掉(否则新盘的 M4/M5 读回与章节
    /// 回填全丢且无人重试);旧盘收尾凭世代失配自弃——镜像 chainGeneration
    /// 的同款竞态修法。
    private var hydrateGeneration = 0

    // MARK: 跨语言翻译(D10.4/D10.5,S7)

    /// 翻译提议:当前语言 miss 的模块在其它语言有既有解读 → 先显示原文,
    /// L3/F1(修订 D10.5)起打开即自动翻译;提示条只在失败时出现(重试)。
    struct TranslationOffer: Equatable {
        /// 原文语言(wire 值,zh / zh-hant / en)
        let sourceLanguage: String
        /// 有原文可译的模块(命中跨语言缓存的模块)
        let modules: Set<ModuleID>
    }

    /// 当前翻译提议(nil = 无跨语言原文 / 已完成翻译)。
    private(set) var translationOffer: TranslationOffer?

    /// L3/F1(2026-10-01 拍板,修订 D10.5):跨语言命中 → 打开即自动翻译。
    /// 提示条只在失败时出现(重试入口);翻译中走章首「正在译为××」小注。
    enum AutoTranslationDisplay: Equatable {
        /// 自动翻译在飞(提示条隐藏,章首小注驱动)
        case inProgress
        /// 翻译失败(非离线类):提示条「部分章节翻译失败 · 重试」,手动重试
        case failed
        /// 离线类失败:提示条「联网后重新打开 App 即自动译为××」(R7 文案,
        /// 与回前台触发的实际行为一致),回前台再自动触发一次
        /// (请求未达后端零 LLM 成本;二次失败转 .failed 只走手动)
        case offlinePending
    }

    /// 自动翻译展示态(nil = 无自动翻译在飞/失败——提示条不显示)。
    private(set) var autoTranslationState: AutoTranslationDisplay?

    /// 自动翻译会话去重 + 结局分诊(2026-10-06 修订):同一 (contentHash, target)
    /// 自动只起一次(防网络抖动 / 反复进出页面循环烧 LLM);但记录的是上次尝试
    /// 的**结局**而非裸「尝试过」——被换盘/reset 打断或离线等待不算失败,重进
    /// 允许再自动续译剩余原文(修复前一律恢复 .failed:中断被谎报成失败,
    /// 离线「联网后续译」承诺丢失,剩余原文卡死到手动重试)。真失败(非离线)
    /// 才恢复失败提示条走手动。
    private enum AutoTranslationOutcome: Equatable {
        /// 中断(换盘/reset 掐断)或离线等待——重进可再自动续译
        case interrupted
        /// 落定失败(非离线类)——恢复失败提示条,只走手动重试
        case failed
    }
    private var autoTranslationOutcomes: [String: AutoTranslationOutcome] = [:]

    /// 离线自动重试已用标记(每个提议周期至多一次回前台自动重试;二次失败
    /// 转 .failed 走手动)。新提议产生时复位。
    private var offlineRetryUsed = false

    /// 跨语言原文行(模块 → 缓存行,含 language / promptVersion / interpretation),
    /// acceptTranslation 消费;成功译完一个模块即移除(重试只译剩余)。
    private var crossLanguageRows: [ModuleID: InterpretationCache] = [:]

    /// 翻译失败章标记(R2,2026-10-02 bug 分支):失败时**保留 .ok 原文显示**
    /// (不再标 .failed——那会把原文从屏幕上抹掉,只剩错误文案),用本集合
    /// 驱动章首「翻译失败 · 重试」小注;译成/重生成/换盘/reset 时清除。
    private(set) var translationFailedModules: Set<ModuleID> = []
    /// 翻译链凭证失效标记(doc E,2026-10-08 维持不修决策评审):翻译 403
    /// CONTEXT_TOKEN_* 时置位,提示条由「翻译失败 · 重试」(重试必再 403 的
    /// 死循环入口)改渲染「重新排盘」指引。不新增 autoTranslationState 态——
    /// 仍落 .failed,由本标记分叉文案。
    private(set) var translationTokenExpired = false

    /// F5(2026-10-02;2026-10-06 持久化;2026-10-07 去内存镜像):M0 原文已
    /// STALE 降级重生成的 (contentHash|targetLang) 集合,事实源 = UserDefaults
    /// (读写收口见 `DeepStaleM0MarkerPersistence`)。**不驻 VM 内存镜像**:
    /// resetAllData 清磁盘后,活着的 VM 实例下次写穿会把内存快照整份写回
    /// (旧标记复活,重置等于没做)——所有读写直连持久化层(读改写),单
    /// VM 实例下无并发写者。生命周期:提议收空 / 兜底弃行 / 全部译完时按
    /// 键清除;换盘与 reset() **不**清(键按盘隔离,切回/reset→重启的同盘
    /// 提议重建要靠它把下游继续导向重生成);全量清走 ProfileView.resetAllData。

    /// 链式翻译在飞(提示条转 loading;与 isChainRunning 互不影响——
    /// 翻译不消耗次数、不跑生成链)。
    private(set) var isTranslatingChain = false

    /// 翻译链世代号(换盘/reset 推进;2026-10-02 双 review 补):换盘守卫与
    /// reset() 会**同步**清 isTranslatingChain=false,但旧翻译链仍挂在翻译
    /// 请求的 await 中——其尾部 `defer { isTranslatingChain = false }` 恢复执行
    /// 时会把**新链**刚置位的标志清掉(新链全程标志失真:「正在译为」章首
    /// 小注消失、acceptTranslation 重入门禁失效)。世代号让旧链 defer 按失配
    /// 自弃——镜像 chainGeneration 的同款手法(快照在 acceptTranslation 与
    /// 置标志同一同步块完成,作参数传入链体,不留任务体起跳时序窗口)。
    private var translationGeneration = 0

    // MARK: 依赖

    private let orchestrator: DeepAnalysisOrchestrator
    /// M3c 新增:entitlement 查询(决定 module 切 _free / _paid)
    private let entitlementStore: EntitlementStore
    private(set) var lastRequest: BaziCalculateRequest?
    private var calculateTask: Task<Void, Never>?

    /// 排盘连续失败计数(仅日志用,成功一次即归零)。
    /// 2026-09-07 拔除「≥3 次切 persistentFailure 隐藏 retry」死胡同:真机用户网络
    /// 短暂不佳连点三次就被锁死、只能重启 App,体验差于让用户继续重试;重试入口永久保留。
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

    /// 确认 sheet 时刻行文案(S04):已知 → HH:mm(2026-09-23 起:已知但未选 →
    /// 诚实展示「未选择时刻」,与日期「—」/半夜未答同口径);未知 →「未知(半夜:是/否/不确定)」。
    /// 勾选但三态未选时确认 sheet 仍可先于校验出现(onSubmit → sheet → calculate),
    /// 此刻诚实展示「半夜:未答」,提交在 calculate 内被 formInvalid 拦截。
    var confirmBirthTimeText: String {
        if hourKnown {
            return birthTimePicked ? wallBirthTimeString : L10n.BirthForm.confirmTimeUnpicked
        }
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
    /// 2026-09-23 时刻去默认值:已知路径时刻未显式选择 → 拦「请选择出生时刻」
    /// (表盘锚点/正午种子只是位置非值,镜像日期「未选择,拨动表盘完成选择」处理)。
    func validateForm() -> [String] {
        var errors: [String] = []
        if birthDate == nil {
            errors.append(L10n.BirthForm.errorDateRequired)
        }
        if hourKnown && !birthTimePicked {
            errors.append(L10n.BirthForm.errorTimeRequired)
        }
        if !hourKnown && lateNightChoice == nil {
            errors.append(L10n.BirthForm.errorLateNightRequired)
        }
        if let birthDate {
            do {
                if hourKnown {
                    if try combinedBirthDate() > Date() {
                        errors.append(String(localized: "出生时间不能晚于当下"))
                    }
                } else if placeCalendar.compare(birthDate, to: Date(), toGranularity: .day) == .orderedDescending {
                    errors.append(String(localized: "出生时间不能晚于当下"))
                }
            } catch {
                // 合成失败(理论不可达):不静默——打日志;提交路径 buildRequest 会显式抛错
                AppLogger.app.warning("deepVM.validateForm combine_failed error=\(String(describing: error), privacy: .public)")
            }
        }
        if gender == nil {
            // 2026-09-19 去默认值:性别不再默认 male,未选必选(与出生地同原则)
            errors.append(L10n.BirthForm.errorGenderRequired)
        }
        if selectedPlace == nil {
            errors.append(String(localized: "请选择出生城市"))
        }
        if let selectedPlace, !selectedPlace.isCustomLongitudeValid {
            errors.append(String(localized: "经度需在 -180 到 180 之间"))
        }
        return errors
    }

    /// 从表单构造请求(S02 契约:裸钟面 + timezone + 物理真值;S04 增 hour_known/late_night)。
    /// place_name/geoname_id/latitude 是存档展示元数据,不参与 content_hash。
    /// 出生地字段解析走 `BirthPlaceResolver` 单一事实源(S05:城市/自定义地点)。
    func buildRequest() throws -> BaziCalculateRequest {
        guard let selectedPlace else {
            // validateForm 先行拦截,理论不可达;显式抛错不静默(错误显式传播)
            throw UserFacingError.generic(message: String(localized: "请选择出生城市"))
        }
        // 性别未选(2026-09-19 去默认值):validateForm 先行拦截,理论不可达;
        // 契约字段非 Optional,在此显式解包抛错,不静默兜 "male"
        guard let gender else {
            throw UserFacingError.generic(message: L10n.BirthForm.errorGenderRequired)
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
    /// 2026-09-23:显式选择即置 `birthTimePicked`(合成失败不置——值没写回,
    /// 不谎报已选)。
    func setShichenHour(_ hour: Int) {
        if let newTime = placeCalendar.date(
            bySettingHour: hour,
            minute: 0,
            second: 0,
            of: birthTime
        ) {
            birthTime = newTime
            birthTimePicked = true
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
        AppLogger.app.info("deepVM.calculate.start birth=\(birthDate?.description ?? "nil") gender=\(gender ?? "nil", privacy: .public) place=\(selectedPlace?.displayLabel ?? "nil", privacy: .public)")
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
                ?? String(localized: "表单信息不完整,请检查后重试")
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
                    // 2026-09-08 拍板:排盘成功即自动起链(推翻 08-01「β 点击触发」)。
                    // 走 hydrate 管线而非直接起链:同 hash 重排时先回填旧缓存,避免重生成。
                    await hydrateAndResume(response: response)
                }
            } catch is CancellationError {
                // 被取消,不更新状态(新 Task 会接管)
                AppLogger.app.info("deepVM.calculate.cancelled")
            } catch {
                if !Task.isCancelled {
                    failureCount += 1
                    // 规则 1:抛错前打 error + 当前失败次数(orchestrator 内部已打,VM 层再打 state 转换)
                    AppLogger.app.error("deepVM.calculate.failed count=\(self.failureCount) error=\(String(describing: error), privacy: .public)")
                    state = .chartFailed(UserFacingError.from(error, stage: .chart))
                }
            }
        }
    }

    func retryCalculation() {
        calculate()
    }

    /// 排盘是否进行中(收起态表单 CTA 置灰 / 横幅显隐共用判定)。
    var isCalculating: Bool {
        if case .calculating = state { return true }
        return false
    }

    /// 用户主动取消排盘(2026-09-08 排盘等待页可收起:横幅「×」入口)。
    /// 只取消排盘请求并复位到表单态;不动链任务/已存档章节(取消时必然尚无盘)。
    /// 与 reset() 的区别:reset 连 m4/m5 输入等表单外状态一起清,语义是「整页重来」;
    /// 这里保留表单输入,用户改一两个字就能再发。
    func cancelCalculation() {
        guard isCalculating else { return }
        calculateTask?.cancel()
        state = .empty
        AppLogger.app.info("deepVM.calculate.cancelled_by_user")
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
            // 同步作废旧链(世代号推进 → 旧链 defer 不再动标志)并复位链标志:
            // 只 cancel 不复位会有窗口——旧链取消要等协作挂起点落地才清 isChainRunning,
            // 期间新盘 hydrate 收尾的 resume 会被旧标志误拦,新盘链停摆到下次触发。
            chainGeneration &+= 1
            isChainRunning = false
            // hydrate 同款竞态修(2026-10-02 bug 分支):旧盘 hydrate 在飞
            // (performRestore await 中)时,只靠 hydrateAndResume 的
            // !isHydrating 守卫会拦掉新盘 hydrate 且无人重试。同步复位标志 +
            // 推进世代,旧盘收尾按世代失配自弃。
            hydrateGeneration &+= 1
            isHydrating = false
            moduleStates.removeAll()
            v1ChainFields.removeAll()
            // 翻译提议属旧盘(D10.5):换盘一并清洗,防旧盘提示条挂新盘
            translationOffer = nil
            crossLanguageRows.removeAll()
            translationFailedModules.removeAll()
            translationTokenExpired = false
            // 同步清标志 + 推进世代(2026-10-02 双 review 补):旧翻译链在网络
            // await 中,只清标志不推进世代的话,旧链尾部 defer 会把新链刚置位的
            // 标志再清掉(见 translationGeneration 注释)。
            translationGeneration &+= 1
            translationChainTask?.cancel()
            isTranslatingChain = false
            autoTranslationState = nil
            // #7(2026-10-02):M4/M5 用户输入也属旧盘——残留会让新盘沿用旧盘
            // 输入生成(user_input_hash 错位 → 缓存 miss 扣次数,内容还是别人
            // 的年龄/关注点)。清空后下方 hydrate 起手按新 hash 读回该盘自己
            // 的已存输入(补时辰 remap 已迁移则无缝衔接)。
            // R4 修订(2026-10-06 review 核实):拔掉「三柱一致 + 时柱从无到有
            // 即判同人」的兜底 remap——同一天出生的两个人(双胞胎/亲友)同样
            // 命中该判据,会把 A 的年龄/健康关注等隐私输入串进 B 的盘并持久化
            // (loadArchivedChart 是通用换盘入口,无法确认「新盘由补时辰而来」,
            // sheet dismiss 含取消/静默完成等非重算形态)。同人补时辰的输入沿用
            // 只走 AddHourViewModel.submit 的显式 remap——按 sheet 打开时的老盘
            // hash 精确迁移,同人不靠猜;此处恒清内存,由 hydrate 按新 hash
            // 读回各盘自己的持久化输入。
            m4UserInput = nil
            m5UserInput = nil
            AppLogger.app.info(
                "deepVM.loadArchivedChart chart_changed oldHash=\(old.contentHash, privacy: .public) newHash=\(response.contentHash, privacy: .public) — v1 链状态已清洗"
            )
        }
        AppLogger.app.info(
            "deepVM.loadArchivedChart contentHash=\(response.contentHash, privacy: .public)"
        )
        lastRequest = request
        state = .ready(response, .idle)
        // 断点续跑:冷启动/补时辰刷新后回填已完成章,再自动续跑未完成的。
        // 同 hash 重入由 hydrate 内部防重入守卫兜住;换盘场景(上方守卫已清洗
        // moduleStates)由 hydrate 前后 isCurrentChart 双检丢弃旧盘结果。
        Task { @MainActor [weak self] in
            await self?.hydrateAndResume(response: response)
        }
    }

    // MARK: - 断点续跑(2026-09-08:排盘成功即自动起链 + 冷启动回填)

    /// 回填本地缓存的已完成章,然后自动续跑未完成的链。
    ///
    /// 触发点:calculate 成功 / loadArchivedChart(冷启动、补时辰刷新)。
    /// 回填范围:moduleStates 为 nil(重启后未恢复)或 .failed(上次链被掐,
    /// 但该章可能已完成并落本地缓存)的章;**不覆盖** ok/fetching/pending/
    /// locked/needsInput(保住既有语义态,同 hash 重入不清状态)。
    /// 回填失败(identity 解析失败 / SwiftData 读失败)→ 记日志跳过自动续跑,
    /// 不打断 UI(错误显式传播到日志层;目录呈未读,用户点开卷可手动重试)。
    ///
    /// 结构注意:isHydrating 复位**必须**先于尾部 resume——resume 的
    /// `!isHydrating` 守卫若在标志复位前被调到会自锁(首版实踩:链永远起不来)。
    @MainActor
    private func hydrateAndResume(response: BaziResponse) async {
        // 世代号快照(2026-10-02 bug 分支):旧盘 hydrate 在飞时换盘,chart_changed
        // 同步推进世代 + 复位 isHydrating(见彼处),旧盘 await 返回后凭世代失配
        // 丢弃收尾(不 autoTranslate / 不 resume / 不复位新盘在飞的 isHydrating)
        // ——镜像 chainGeneration 的同款手法。
        let generation = hydrateGeneration
        guard isCurrentChart(response) else { return }
        guard response.hourUnknownGate != .dayAmbiguous else {
            AppLogger.app.warning(
                "deepVM.hydrateAndResume.skip reason=day_ambiguous hash=\(response.contentHash, privacy: .public)"
            )
            return
        }
        guard !isHydrating else {
            AppLogger.app.info("deepVM.hydrateAndResume.already_hydrating hash=\(response.contentHash, privacy: .public)")
            return
        }
        // 凭证失效态降级(2026-10-08 第十五轮 #6):同 hash 重入(Tab 重挂/
        // 补时辰取消回退)时,快照 token 可能已被任何重算路径 upsert 翻新
        //(排盘确定性 → 同 hash 新 token 内容等价)——.contextTokenExpired
        // 章节降级 .pending,让链用当前 token 重试;若 token 仍失效,链首章
        // 再 403 回落失效态并断链(断链前置检查兜底),有界不多烧。翻译链
        // 提示条同口径清除(reset 路径既有语义;此处覆盖同 hash 无 reset 的
        // 恢复路径,否则重排后翻译指引条残留到手动操作)。
        for (module, state) in moduleStates {
            if case .contextTokenExpired = state {
                AppLogger.app.info(
                    "deepVM.hydrateAndResume token_expired_demoted module=\(module.rawValue, privacy: .public)"
                )
                moduleStates[module] = .pending
            }
        }
        translationTokenExpired = false
        // L2/F4 起手读回持久化的 M4/M5 输入(重启后 m4UserInput/m5UserInput 为
        // nil——翻译链缺输入会把已生成章标 .needsInput,原文从屏幕消失)。
        // 内存已有值不覆盖(同会话重入 hydrate 不吞掉刚提交的新输入)。
        if m4UserInput == nil,
           let saved = DeepUserInputPersistence.loadM4(contentHash: response.contentHash) {
            m4UserInput = (saved.age, saved.concern)
            AppLogger.app.info("deepVM.hydrateAndResume.m4_input_restored hash=\(response.contentHash, privacy: .public)")
        }
        if m5UserInput == nil,
           let saved = DeepUserInputPersistence.loadM5(contentHash: response.contentHash) {
            m5UserInput = (saved.assets, saved.preference)
            AppLogger.app.info("deepVM.hydrateAndResume.m5_input_restored hash=\(response.contentHash, privacy: .public)")
        }
        inflightHydrateCount += 1
        defer { inflightHydrateCount -= 1 }  // 覆盖所有出口(含世代失配自弃)
        isHydrating = true
        let outcome = await performRestore(response: response)
        // 世代失配 = await 期间已换盘:isHydrating 由新盘 hydrate 持有,此处
        // 不得复位(提前解除会放行第三次重入);收尾(autoTranslate/resume)
        // 同样属旧盘,整体丢弃。performRestore 内部已有 isCurrentChart 双检,
        // 旧盘回填写入本就到不了这里。
        guard hydrateGeneration == generation else {
            AppLogger.app.warning(
                "deepVM.hydrateAndResume.stale_generation hash=\(response.contentHash, privacy: .public) — 旧盘 hydrate 收尾丢弃"
            )
            return
        }
        isHydrating = false
        // L3/F1(修订 D10.5):跨语言原文命中 → 打开即自动翻译,不等用户点
        // 提示条(必须等 isHydrating 复位后调——acceptTranslation 守卫拦截
        // hydrate 在飞时段)。次序先于 resume:翻译提议挂着时 resume 本就被
        // translation_pending 守卫拦住,译文落键收尾自会补跑缺失章。
        autoTranslateIfNeeded(response: response)
        // 换盘中途(staleChart)也续跑:此时 state 已是新盘,resume 会按新盘起链
        if outcome != .restoreFailed {
            resumeV1ChainIfNeeded()
        }
    }

    /// L3/F1 自动翻译入口:有跨语言提议且本会话未自动过 → 直接起翻译链。
    /// 去重键 (contentHash, target):失败后重进页面不再自动(手动重试),
    /// 防网络抖动 / 反复进出循环烧 LLM(翻译不扣用户次数但有成本)。
    private func autoTranslateIfNeeded(response: BaziResponse) {
        guard translationOffer != nil else { return }
        guard !isTranslatingChain, !isHydrating else { return }
        guard isCurrentChart(response) else { return }
        let key = response.contentHash + "|" + AppLanguage.currentWire
        if let outcome = autoTranslationOutcomes[key] {
            guard outcome != .failed else {
                // F2(2026-10-02 修复;2026-10-06 收窄到「真失败」):上次尝试
                // 落定失败后不再自动重试(防烧 LLM 语义不变),但必须恢复失败态
                // ——静默 return 会让 autoTranslationState 停留 nil(提示条不渲染),
                // 同时 offer 非 nil 拦死 resumeV1ChainIfNeeded 的
                // translation_pending 守卫:既不翻译、也不生成、无重试入口,死路。
                autoTranslationState = .failed
                AppLogger.app.info("deepVM.autoTranslate.skip reason=already_failed key=\(key, privacy: .public) — 恢复失败提示条(手动重试)")
                return
            }
            // .interrupted:上次自动翻译被换盘/reset 打断或离线等待——不是失败,
            // 直接续译剩余原文(成功即收口;真失败会改记 .failed,防循环烧 LLM)
            AppLogger.app.info("deepVM.autoTranslate.resume reason=interrupted key=\(key, privacy: .public) — 续译剩余原文")
        }
        autoTranslationOutcomes[key] = .interrupted
        AppLogger.app.info("deepVM.autoTranslate.start hash=\(response.contentHash, privacy: .public)")
        acceptTranslation()
    }

    /// 离线类失败后的回前台重触发(DeepAnalysisView scenePhase → active 调)。
    /// 仅 .offlinePending 态且未用过重试额度时生效;重试后若再离线失败,
    /// runTranslationChain 会按 offlineRetryUsed 转 .failed——即每个提议
    /// 周期至多一次回前台自动重试,不无限循环。
    func retryOfflineTranslationIfNeeded() {
        guard autoTranslationState == .offlinePending, !offlineRetryUsed else { return }
        guard translationOffer != nil, !isTranslatingChain, !isHydrating else { return }
        offlineRetryUsed = true
        AppLogger.app.info("deepVM.autoTranslate.offline_retry_after_foreground")
        acceptTranslation()
    }

    /// 章首「正在译为××」小注判据(L3/F1):翻译链在飞且该章仍是待译原文
    /// (crossLanguageRows 未消费)——原文照常展示,小注提示即将替换。
    func isChapterTranslationPending(_ module: ModuleID) -> Bool {
        isTranslatingChain && crossLanguageRows[module] != nil
    }

    /// 章首「翻译失败 · 重试」小注判据(R2,2026-10-02 bug 分支):本章翻译
    /// 失败且当前无翻译链在飞(在飞时由「正在译为」小注接管展示)。
    /// 原文照常展示,失败事实由小注表达,点击小注 = 重试翻译。
    func isChapterTranslationFailed(_ module: ModuleID) -> Bool {
        translationFailedModules.contains(module) && !isTranslatingChain
    }

    /// 该章是否有未消费的跨语言原文行(R2):章节级「重试」CTA 的分流判据——
    /// 有原文行时重试语义是**重译**(不扣次数),否则才是重新生成。
    func hasCrossLanguageOriginal(for module: ModuleID) -> Bool {
        crossLanguageRows[module] != nil
    }

    /// hydrate 结果(决定尾部是否续跑)。
    private enum HydrateOutcome {
        case restored
        /// await 期间换盘,旧盘回填已丢弃(尾部 resume 按当前盘重新判定)
        case staleChart
        /// identity 解析 / SwiftData 读失败(离线等)→ 跳过自动续跑
        case restoreFailed
    }

    /// 回填状态谓词(单一事实源):仅 nil(重启未恢复)/ .failed(上次链被掐,
    /// 但可能已落本地缓存)的章可回填;ok/fetching/pending/locked/needsInput
    /// 是既有语义态,不覆盖。查询清单(await 前)与写回重检(await 后)共用,
    /// 防两处口径漂移。
    private static func isRestorableModuleState(_ state: ModuleState?) -> Bool {
        switch state {
        case nil, .failed: return true
        case .ok, .fetching, .pending, .locked, .needsInput, .contextTokenExpired,
             .dailyLimitReached:
            return false
        }
    }

    /// 回填执行体(调用方保证 isHydrating 已置位)。
    @MainActor
    private func performRestore(response: BaziResponse) async -> HydrateOutcome {
        let modulesToRestore = ModuleID.allCases.filter { Self.isRestorableModuleState(moduleStates[$0]) }
        guard !modulesToRestore.isEmpty else { return .restored }

        do {
            let hits = try await orchestrator.restoreCachedV1Modules(
                contentHash: response.contentHash,
                modules: modulesToRestore.map(\.rawValue)
            )
            // await 期间可能换盘(补时辰重算/存档切换):旧盘回填丢弃
            guard isCurrentChart(response) else {
                AppLogger.app.warning(
                    "deepVM.hydrateAndResume.stale_chart_after_await hash=\(response.contentHash, privacy: .public) — 回填丢弃"
                )
                return .staleChart
            }
            // 按 allCases 顺序写;extractChainFields 幂等重建下游链字段
            // (structure_fingerprint 等,续跑 M1-M7 时注入 context 用)。
            // 写回时**重检**状态:await 窗口内用户可能已点开卷/重试(模块翻
            // .pending/.fetching/.ok)——回填只落在仍可回填的章,
            // 兑现「不覆盖既有语义态」的文档承诺(过滤清单只在 await 前算过一次)。
            var writtenCount = 0
            var skippedByRecheck: [String] = []
            for module in ModuleID.allCases {
                guard let cache = hits[module.rawValue] else { continue }
                guard Self.isRestorableModuleState(moduleStates[module]) else {
                    skippedByRecheck.append(module.rawValue)
                    continue
                }
                moduleStates[module] = .ok(text: cache.interpretation, cached: true)
                extractChainFields(from: cache.interpretation, for: module)
                writtenCount += 1
            }
            // 重检跳过留痕(排障区分「缓存无命中」与「await 窗口内翻非可回填态」)
            if !skippedByRecheck.isEmpty {
                AppLogger.app.info(
                    "deepVM.hydrateAndResume.writeback_skipped_by_recheck hash=\(response.contentHash, privacy: .public) modules=\(skippedByRecheck.joined(separator: ","), privacy: .public)"
                )
            }
            AppLogger.app.info(
                "deepVM.hydrateAndResume.restored hash=\(response.contentHash, privacy: .public) queried=\(modulesToRestore.count) hits=\(hits.count) written=\(writtenCount)"
            )

            // D10.5(S7):当前语言 miss 的可回填章,探测其它语言的既有解读 →
            // 先显示原文 + 自动翻译(L3/F1 修订 D10.5)。链字段用原文重建
            // (译文落键前,下游生成/翻译请求都用这套字段——acceptTranslation
            // 译完 M0 后会以译后字段覆盖)。best-effort:探测失败(离线等)
            // 只跳过提示条走正常生成,不阻断已成功的主恢复——错误留痕不吞。
            let stillMissing = modulesToRestore.filter { moduleStates[$0]?.isOk != true }
            if !stillMissing.isEmpty {
                do {
                    if let (sourceLanguage, sourceHits) = try await orchestrator
                        .restoreCrossLanguageV1Modules(
                            contentHash: response.contentHash,
                            modules: stillMissing.map(\.rawValue)
                        ), !sourceHits.isEmpty {
                        guard isCurrentChart(response) else { return .staleChart }
                        for module in ModuleID.allCases where sourceHits[module.rawValue] != nil {
                            guard Self.isRestorableModuleState(moduleStates[module]),
                                  moduleStates[module]?.isOk != true else { continue }
                            let row = sourceHits[module.rawValue]!
                            crossLanguageRows[module] = row
                            moduleStates[module] = .ok(text: row.interpretation, cached: true)
                            extractChainFields(from: row.interpretation, for: module)
                        }
                        if !crossLanguageRows.isEmpty {
                            offlineRetryUsed = false  // 新提议周期:离线自动重试额度复位
                            translationOffer = TranslationOffer(
                                sourceLanguage: sourceLanguage,
                                modules: Set(crossLanguageRows.keys)
                            )
                            AppLogger.app.info(
                                "deepVM.hydrateAndResume.cross_language hash=\(response.contentHash, privacy: .public) source=\(sourceLanguage, privacy: .public) modules=\(self.crossLanguageRows.keys.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)"
                            )
                        }
                    }
                } catch {
                    AppLogger.app.warning(
                        "deepVM.hydrateAndResume.cross_language_failed hash=\(response.contentHash, privacy: .public) error=\(String(describing: error), privacy: .public) — 跳过翻译提示,走正常生成"
                    )
                }
            }
            return .restored
        } catch {
            if Task.isCancelled {
                // calculateTask 被重触发取消(常规用户动作):取消沿 URLSession 传导
                // 成异常——与真失败分级,info 足够,不污染 error 通道;新 calculate
                // 会自带一轮完整 hydrate。
                AppLogger.app.info(
                    "deepVM.hydrateAndResume.cancelled hash=\(response.contentHash, privacy: .public)"
                )
                return .restoreFailed
            }
            // 不静默吞:显式日志 + 跳过自动续跑(离线时续跑注定失败,不制造满屏 failed)
            AppLogger.app.error(
                "deepVM.hydrateAndResume.restore_failed hash=\(response.contentHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return .restoreFailed
        }
    }

    /// 自动续跑守卫入口(hydrate 收尾 / 回前台 scenePhase 触发)。
    ///
    /// 守卫链:非 ready 不跑;日柱歧义不跑(S07 纵深防御);链在跑不重复起
    /// (含后台被掐后 Task 挂起场景,回前台自然恢复);hydrate 在飞不抢跑
    /// (由 hydrate 收尾统一触发);无可跑未完成章不空转(.ok 已完成 / .locked
    /// 等购买 / .needsInput 等用户填表 / .fetching 有单章重试在飞均排除);
    /// 每日次数耗尽不跑(CTA limit ghost 已有人话,自动跑只会满屏 failed);
    /// 翻译提议挂着不跑(D10.5:原文缺失的模块应由译后 M0 的目标语言链字段
    /// 驱动生成,自动跑会用原文 fingerprint 造成缓存键错位——翻译收尾再续跑)。
    func resumeV1ChainIfNeeded() {
        // 达限态过期归一(十四轮外评 #2)须在 .ready 守卫前:回前台
        // scenePhase 触发本方法,先解除已过 nextReset 的达限态,下方
        // hasRunnableUnfinished 才会把这些章视为可续跑。
        expireStaleServerQuotaStates()
        guard case .ready(let response, _) = state else {
            AppLogger.app.info("deepVM.resumeV1ChainIfNeeded.skip reason=not_ready")
            return
        }
        guard translationOffer == nil else {
            AppLogger.app.info("deepVM.resumeV1ChainIfNeeded.skip reason=translation_pending")
            return
        }
        guard response.hourUnknownGate != .dayAmbiguous else {
            AppLogger.app.warning("deepVM.resumeV1ChainIfNeeded.skip reason=day_ambiguous")
            return
        }
        guard !isChainRunning else { return }
        guard !isHydrating else { return }
        let entitled = { (module: ModuleID) in
            !module.isPaid || self.hasDeepEntitlement(contentHash: response.contentHash)
        }
        let hasRunnableUnfinished = ModuleID.allCases.contains { module in
            switch moduleStates[module] {
            case .ok, .locked, .needsInput, .fetching:
                return false
            case nil, .pending, .failed:
                return entitled(module)
            case .contextTokenExpired:
                // 凭证失效:续跑必再 403(2026-10-08),恢复走「重新排盘」,
                // 不进自动续跑清单
                return false
            case .dailyLimitReached:
                // 服务端配额 429(2026-10-08 外评 #6):续跑必再 429,
                // 恢复走 UTC 零点重置,不进自动续跑清单
                return false
            }
        }
        guard hasRunnableUnfinished else {
            AppLogger.app.info("deepVM.resumeV1ChainIfNeeded.skip reason=no_runnable_unfinished")
            return
        }
        guard remainingReads > 0 else {
            AppLogger.app.info("deepVM.resumeV1ChainIfNeeded.skip reason=daily_limit")
            return
        }
        AppLogger.app.info("deepVM.resumeV1ChainIfNeeded.start hash=\(response.contentHash, privacy: .public)")
        startV1Chain(response: response)
    }

    // MARK: - AI 命书(盘面小景 S2:legacy 单文本路径已删,UI 只走 v1 捌章)

    // generateInterpretation / retryInterpretation / localCachedText(bazi_deep
    // 单文本老路径)随 DeepAnalysisResultView 删除一并移除:新 UI(主页目录 +
    // ChapterReadingView)只消费 moduleStates 的 v1 模块化路径。InterpretState
    // 枚举保留(state 机 .ready 关联值依赖)。老缓存数据不清库,只是不再展示。

    // MARK: - v1 prompt 系统用户输入提交(Stage 8)

    /// M4 用户输入提交(ChapterReadingView 页内表单的 onSubmit 回调)。
    /// 写入 m4UserInput + 持久化(L2/F4:切语言必重启,重启后翻译链/续跑
    /// 需要 user_input_hash 对齐,输入丢失会把已生成章翻成「待填写」)+ 若
    /// M4 当前是 .needsInput 则触发自动重试。
    /// 注:上游依赖(M0)是否 ok 由 runSingleV1Module 内部守卫处理(缺失时标 .pending)。
    func submitM4Input(age: Int, concern: String) {
        m4UserInput = (age, concern)
        DeepUserInputPersistence.saveM4(
            .init(age: age, concern: concern), contentHash: currentContentHashForPersistence
        )
        // age 非敏感(concern 含健康信息 → privacy)
        AppLogger.app.info("deepVM.submitM4Input age=\(age) concern=\(concern, privacy: .private)")
        if moduleStates[.m4] == .needsInput {
            retryV1Module(.m4)
        }
    }

    /// M5 用户输入提交(ChapterReadingView 页内表单的 onSubmit 回调)。
    /// 写入 m5UserInput + 持久化(L2/F4 同上)+ 若 M5 当前是 .needsInput
    /// 则触发自动重试。
    /// 注:上游依赖(M0+M1+M3)是否 ok 由 runSingleV1Module 内部守卫处理。
    func submitM5Input(assets: String, preference: String) {
        m5UserInput = (assets, preference)
        DeepUserInputPersistence.saveM5(
            .init(assets: assets, preference: preference), contentHash: currentContentHashForPersistence
        )
        // assets 含财务信息 → privacy;preference 三选一非敏感但跟随 private 保持一致
        AppLogger.app.info("deepVM.submitM5Input assets=\(assets, privacy: .private) preference=\(preference, privacy: .private)")
        if moduleStates[.m5] == .needsInput {
            retryV1Module(.m5)
        }
    }

    /// 当前盘的 contentHash(持久化键用);.ready 外(表单态)为 nil → 不落盘。
    private var currentContentHashForPersistence: String? {
        if case .ready(let response, _) = state { return response.contentHash }
        return nil
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
    /// 用户场景(2026-09-08 起主路径为自动触发):
    /// - 排盘成功后自动起链(calculate → hydrateAndResume → resumeV1ChainIfNeeded)
    /// - 冷启动回填后自动续跑未完成章(loadArchivedChart → hydrateAndResume)
    /// - 用户点 "开卷" CTA / 目录行(链已停且章节未读时;链在跑被幂等守卫拦下)
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
        // 幂等守卫(2026-09-08 自动起链):链在跑时不再 reset 重跑——单点覆盖
        // .openFirst CTA 链跑中点按、目录行、未来调用方,防止把在飞链拦腰重置。
        guard !isChainRunning else {
            AppLogger.app.info("deepVM.generateV1AllModules.skip reason=chain_active")
            return
        }

        AppLogger.app.info("deepVM.generateV1AllModules.start contentHash=\(response.contentHash, privacy: .public)")

        v1ChainTask?.cancel()

        // 重置所有模块为 .pending(全新开始;单模块重试走 retryV1Module)。
        // 幂等守卫保证走到这里时无在飞链,reset 只影响失败残留(无 ok 可丢)。
        for module in ModuleID.allCases {
            moduleStates[module] = .pending
        }
        v1ChainFields.removeAll()

        startV1Chain(response: response)
    }

    /// 起链 Task 装配点(全链开始与断点续跑共用)。
    /// 世代号 +1:旧链(已被 cancel)在挂起点恢复后,其 defer 不得清当代链的
    /// `isChainRunning`(详见 runV1Chain 的 defer)。
    private func startV1Chain(response: BaziResponse) {
        expireStaleServerQuotaStates()
        chainGeneration &+= 1
        let generation = chainGeneration
        isChainRunning = true
        v1ChainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runV1Chain(response: response, generation: generation)
        }
    }

    /// 服务端配额达限态的过期归一(十四轮外评 #2):`.dailyLimitReached` 落态
    /// 后,resume 守卫/链前检/断链三处都不看 `nextReset`——UTC 零点已过、
    /// 服务端额度已重置,状态却残留达限,该章及下游在 App 重启前永久卡死
    /// (章节页达限态禁重试,hydrate 也不回填)。归一 = nextReset 已过 →
    /// 回 `.failed`(可重试/可回填/可自动续跑,三处守卫与重试按钮自然接管;
    /// 再 429 会重新落达限态,幂等)。message 复用达限标题(描述先前失败,
    /// 自动续跑路径下该态瞬时不可见,不新增 xcstrings key)。
    private func expireStaleServerQuotaStates() {
        let now = Date()
        for (module, state) in moduleStates {
            if case .dailyLimitReached(let nextReset) = state, nextReset <= now {
                moduleStates[module] = .failed(message: L10n.Errors.limitTitle)
                AppLogger.app.info(
                    "deepVM.quotaStateExpired module=\(module.rawValue, privacy: .public) nextReset=\(nextReset.description, privacy: .public) — 服务端配额已重置,达限态解除"
                )
            }
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

        // 世代号快照(2026-10-07 review):重试任务此前不持引用、传 nil 走
        // isCurrentChart 语义——A→B→A 换回后 isCurrentChart 重新放行旧盘重试,
        // 与新链并发写 moduleStates/v1ChainFields。快照 translationGeneration
        // (换盘/换回清洗都推进),复用 runSingleV1Module 四处世代守卫,与翻译
        // 降级链同规;同盘内的翻译/重试互不推进世代,不受影响。
        let generation = translationGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSingleV1Module(module, response: response, chainGeneration: generation)
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

        // 世代号快照同 retryV1Module(2026-10-07 review):A→B→A 换回后旧批
        // 重试按世代失配丢弃,不与新链并发写状态
        let generation = translationGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            for module in lockedModules {
                await self.runSingleV1Module(module, response: response, chainGeneration: generation)
            }
        }
    }

    /// 链式调用主循环:按 ModuleID.allCases 顺序串行执行(M0 → M1 → ... → M7)。
    ///
    /// 断点续跑(2026-09-08):已 `.ok` 的章直接跳过(缓存回填/前次链已完成的
    /// 部分不重跑,缓存命中 refund 语义虽不耗次,但跳过连请求都不发);世代号
    /// 保证只有「当代链」能清 `isChainRunning`(取消竞态见 startV1Chain)。
    ///
    /// 注:简化版采用全串行;v2 可优化为按依赖图并行(M2/M3/M4/M5 可同时跑)。
    /// 串行好处:状态机简单,失败定位清晰,无并发竞争。
    /// (doc + @MainActor 于 9da2444 合并消解 normalizeExpiredLimitStates 时被
    /// 连带误删,2026-10-08 双 review 恢复——两父提交均有,类级 @MainActor
    /// 下隔离语义不变,纯文档失而复得)
    @MainActor
    private func runV1Chain(response: BaziResponse, generation: Int) async {
        defer {
            // 只有当代链能清标志:旧链(cancel 后在挂起点恢复)不得掐灭新链横幅
            if chainGeneration == generation {
                isChainRunning = false
            }
        }
        for module in ModuleID.allCases {
            if Task.isCancelled { return }
            if moduleStates[module]?.isOk == true { continue }
            // 单章重试在飞(阅读页「重试本章」)→ 不重复发请求;该重试自担成败,
            // 失败标 .failed 后由下次 resume/用户重试接管
            if moduleStates[module] == .fetching {
                if module == .m0 {
                    // M0 重试在飞 ≠ M0 失败:本链让位(重试落定 ok 后由下次
                    // resume/CTA 接力下游),不误报 m0_failed_breaking_chain
                    AppLogger.app.info(
                        "deepVM.runV1Chain m0_retry_in_flight_deferring contentHash=\(response.contentHash, privacy: .public)"
                    )
                    return
                }
                continue
            }
            // 断链前置检查(2026-10-08 外评 #6 续修):链因达限/凭证失效断过后
            // 状态残留,resume/回前台重启链时**不得重跑**这些章——下方 runV1Chain
            // 尾部的断链只在「本次刚跑完」时生效,重启场景由这里拦(resume 守卫
            // 的 nil-下游判据拦不住:M1-M7 为 nil 时 hasRunnableUnfinished 恒真)。
            // 达限断链对齐本地池断链先验(重跑必再 429;付费章等 UTC 重置);
            // 凭证失效同一 token 全链必 403,同断。
            switch moduleStates[module] {
            case .dailyLimitReached:
                AppLogger.app.warning(
                    "deepVM.runV1Chain server_quota_break_precheck module=\(module.rawValue, privacy: .public)"
                )
                return
            case .contextTokenExpired:
                AppLogger.app.warning(
                    "deepVM.runV1Chain token_expired_break_precheck module=\(module.rawValue, privacy: .public)"
                )
                return
            default:
                break
            }
            await runSingleV1Module(module, response: response)
            // M0 失败 → 中断链(下游缺 structure_fingerprint 无法跑)
            if module == .m0 && moduleStates[.m0]?.isOk != true {
                AppLogger.app.warning("deepVM.runV1Chain m0_failed_breaking_chain contentHash=\(response.contentHash, privacy: .public)")
                return
            }
            // 每日次数耗尽 → 剩余章 tryConsume 必逐个失败,提前断链不制造满屏 failed
            if case .failed = moduleStates[module], remainingReads <= 0 {
                AppLogger.app.warning(
                    "deepVM.runV1Chain daily_limit_break module=\(module.rawValue, privacy: .public)"
                )
                return
            }
            // 服务端配额达限(2026-10-08 外评 #6):剩余章必再 429,提前断链
            // (与上方本地池断链同款;双池不同源,本地 remaining 判不了服务端)
            if case .dailyLimitReached = moduleStates[module] {
                AppLogger.app.warning(
                    "deepVM.runV1Chain server_quota_break module=\(module.rawValue, privacy: .public)"
                )
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
    private func runSingleV1Module(
        _ module: ModuleID, response: BaziResponse, quotaExempt: Bool = false,
        chainGeneration: Int? = nil
    ) async {
        // 同盘守卫(双 review P1 修复):retryV1Module / retryLockedV1Modules 的
        // 任务 fire-and-forget 不被持有,loadArchivedChart 换盘清洗只 cancel
        // v1ChainTask——旧盘在飞任务若不清拦,会把旧盘的 locked/needsInput/
        // fetching/ok/failed 写进新盘 moduleStates(跨盘污染:新盘目录显示旧盘
        // 「已读」、阅读页展示旧盘正文)。入口 + await 返回后双检,覆盖全部写点。
        // chainGeneration(2026-10-07 review 修复 A):翻译链降级路径传入链世代
        // ——isCurrentChart 只比 contentHash,A→B→A 换回后旧链(旧世代)会被
        // 重新放行,与新链并发写 moduleStates/v1ChainFields(双花 LLM + 译后
        // 指纹互覆)。世代号在换盘/换回/reset 都推进,是链所有权的强判据;
        // 非(翻译)链调用方传 nil,维持 isCurrentChart 原语义。
        guard isCurrentChart(response) else {
            AppLogger.app.warning(
                "deepVM.runSingleV1Module.stale_chart module=\(module.rawValue, privacy: .public) hash=\(response.contentHash, privacy: .public) — 旧盘任务丢弃"
            )
            return
        }
        if let chainGeneration, translationGeneration != chainGeneration {
            AppLogger.app.warning(
                "deepVM.runSingleV1Module.stale_generation module=\(module.rawValue, privacy: .public) hash=\(response.contentHash, privacy: .public) gen=\(chainGeneration, privacy: .public) current=\(self.translationGeneration, privacy: .public) — 旧链降级任务丢弃(A→B→A 防并发)"
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

        // 上游依赖守卫:M1-M7 需要 structure_fingerprint + 本模块必带链式字段
        // (requiredChainFields,来自上游模块输出);v1ChainFields 缺任一,
        // 不发注定 422 的请求,标 .pending 等用户先重试上游模块。
        // 场景:用户在 M4 needsInput 时填了输入 → submitM4Input 自动调 retryV1Module(.m4),
        // 但 M0 可能已失败(网络断 / 日限) → 此处拦回 .pending,不浪费次数。
        // 2026-09-25 扩展:原来只查 structure_fingerprint,漏查 main_axis 等
        // 链式字段 → m1 真机每次必 422"prompt 渲染缺字段:['main_axis','core_loop']"。
        if module.requiresParentFingerprint {
            let missing = (v1ChainFields["structure_fingerprint"] == nil ? ["structure_fingerprint"] : [])
                + module.requiredChainFields.filter { v1ChainFields[$0] == nil }
            if !missing.isEmpty {
                moduleStates[module] = .pending
                AppLogger.app.warning(
                    "deepVM.runSingleV1Module.missing_parent module=\(module.rawValue, privacy: .public) missing=\(missing.joined(separator: ","), privacy: .public) — 标 .pending 等上游重试"
                )
                return
            }
        }

        moduleStates[module] = .fetching

        do {
            let parentFingerprint: String? = module.requiresParentFingerprint
                ? v1ChainFields["structure_fingerprint"]
                : nil
            // 链式字段注入(2026-09-25 修复:此前提取后从未随请求发送,
            // m1/m2/m5/m6/m7 真机必 422)。上游守卫已保证 required 全在。
            let chainFields: [String: String] = module.requiredChainFields.reduce(into: [:]) { acc, field in
                if let value = v1ChainFields[field] {
                    acc[field] = value
                }
            }

            let resp = try await orchestrator.runV1Module(
                response: response,
                module: module.rawValue,
                parentFingerprint: parentFingerprint,
                m4Input: m4UserInput,
                m5Input: m5UserInput,
                chainFields: chainFields,
                quotaExempt: quotaExempt
            )

            if Task.isCancelled { return }
            // 同盘守卫第二检:await 期间可能已换盘(loadArchivedChart 清洗过状态)
            guard isCurrentChart(response) else {
                AppLogger.app.warning(
                    "deepVM.runSingleV1Module.stale_chart_after_await module=\(module.rawValue, privacy: .public) hash=\(response.contentHash, privacy: .public) — 旧盘结果丢弃"
                )
                return
            }
            // 世代第二检(2026-10-07 修复 A):A→B→A 换回后 isCurrentChart 会
            // 重新放行旧链——此时 moduleStates/v1ChainFields 已被新链接管,
            // 旧链结果(extractChainFields/.ok 落态)必须丢弃
            if let chainGeneration, translationGeneration != chainGeneration {
                AppLogger.app.warning(
                    "deepVM.runSingleV1Module.stale_generation_after_await module=\(module.rawValue, privacy: .public) hash=\(response.contentHash, privacy: .public) gen=\(chainGeneration, privacy: .public) current=\(self.translationGeneration, privacy: .public) — 旧链结果丢弃"
                )
                return
            }

            // 解析 LLM 输出 JSON,提取链式字段给下游模块用
            // 失败不抛(下游模块可能仍能跑,只是字段缺失会触发后端 validate_context 422)
            extractChainFields(from: resp.interpretation, for: module)

            moduleStates[module] = .ok(text: resp.interpretation, cached: resp.cached)
            // 跨语言原文行作废(2026-10-02 修复):本章已按当前语言重新生成,
            // 残留的原文行会让翻译重试把这一章按旧原文再翻一遍——版本已
            // bump 的原文触发 STALE_SOURCE 时,好的 .ok 会被覆盖成 .failed。
            // R2(bug 分支):翻译失败标记一并清(本章已是目标语言成品)。
            translationFailedModules.remove(module)
            if crossLanguageRows.removeValue(forKey: module) != nil {
                syncTranslationOfferWithRows()
            }
            AppLogger.app.info("deepVM.runSingleV1Module.ok module=\(module.rawValue, privacy: .public) cached=\(resp.cached, privacy: .public)")
        } catch is CancellationError {
            AppLogger.app.info("deepVM.runSingleV1Module.cancelled module=\(module.rawValue, privacy: .public)")
        } catch let error as DeepAnalysisError {
            // 世代门(2026-10-07 review 修复 A 补齐):失败落态与成功落态同判——
            // A→B→A 换回后旧链失败不得以 .failed 覆写新链已接管的 moduleStates
            // (慢旧链会盖掉新链刚落的 .ok);丢弃时留痕不吞。
            guard !Task.isCancelled, isCurrentChart(response),
                  chainGeneration == nil || translationGeneration == chainGeneration
            else {
                AppLogger.app.warning(
                    "deepVM.runSingleV1Module.stale_failure_drop module=\(module.rawValue, privacy: .public) hash=\(response.contentHash, privacy: .public) error=\(String(describing: error), privacy: .public) — 旧链失败丢弃,不落新链状态"
                )
                return
            }
            AppLogger.app.warning("deepVM.runSingleV1Module.deepAnalysisError module=\(module.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
            moduleStates[module] = .failed(message: error.errorDescription ?? L10n.Common.unknownError)
        } catch {
            guard !Task.isCancelled, isCurrentChart(response),
                  chainGeneration == nil || translationGeneration == chainGeneration
            else {
                AppLogger.app.warning(
                    "deepVM.runSingleV1Module.stale_failure_drop module=\(module.rawValue, privacy: .public) hash=\(response.contentHash, privacy: .public) error=\(String(describing: error), privacy: .public) — 旧链失败丢弃,不落新链状态"
                )
                return
            }
            AppLogger.app.error("deepVM.runSingleV1Module.failed module=\(module.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public)")
            // 凭证失效(2026-10-08):老快照盘生成/翻译必 403,「重试本章」按钮
            // 点了必然再 403——独立态渲染「重新排盘」出口
            if APIError.isContextTokenError(error) {
                moduleStates[module] = .contextTokenExpired
                return
            }
            let userError = UserFacingError.from(error, stage: .interpret)
            // 服务端免费配额 429(2026-10-08 外评 #6):与本地 10 次/日池不同源,
            // 「重试本章」+ 回前台自动续跑只会反复 429——达限态禁重试 + 倒计时
            // (含本地池耗尽的 DeepAnalysisError.dailyLimitReached,UserFacingError
            // .from 已把两路收编成同一分类)。章节级 ModuleState 暂不接
            // serverPool 登录引导(本地池先触发,该面 429 罕见;两池同渲染
            // 倒计时,serverPool 只影响 InterpretState 侧文案)。
            if case .dailyLimitReached(let reset, _) = userError {
                moduleStates[module] = .dailyLimitReached(nextReset: reset)
                return
            }
            moduleStates[module] = .failed(message: userError.errorDescription ?? L10n.Common.unknownError)
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

    // MARK: - 跨语言翻译执行(D10.4,S7)

    /// 翻译执行入口(L3/F1 起双来源:hydrate 自动触发 + 失败提示条手动重试;
    /// 原 D10.5「点按钮才翻」已修订为打开即自动)。按 M0 → M7 顺序翻译
    /// crossLanguageRows 剩余模块(重试只译剩余)。翻译不消耗每日次数
    /// (orchestrator 不动 counter);付费模块无 entitlement 跳过(后端同检
    /// 403,客户端不白发)。
    func acceptTranslation() {
        guard let offer = translationOffer, !isTranslatingChain, !isHydrating else { return }
        guard case .ready(let response, _) = state else { return }
        // 世代号快照与置标志同一同步块(镜像 startV1Chain 的装配点形态):
        // 若快照留在任务体首行,Task 起跳若晚于「换盘推进世代 + 新链已置
        // 标志」,旧链会快照到推进后的世代——与守卫语义失配(见
        // translationGeneration 注释)。
        let generation = translationGeneration
        isTranslatingChain = true
        autoTranslationState = .inProgress
        translationTokenExpired = false
        AppLogger.app.info(
            "deepVM.acceptTranslation source=\(offer.sourceLanguage, privacy: .public) modules=\(self.crossLanguageRows.keys.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)"
        )
        // isTranslatingChain 幂等守卫已挡并发链,再 cancel 属防御位(镜像
        // interpretTask?.cancel() 模式),代价为零;兼防「换盘同步清标志后
        // 旧任务仍在飞、新链立刻起跑」的窗口双发。
        translationChainTask?.cancel()
        translationChainTask = Task { @MainActor [weak self] in
            await self?.runTranslationChain(
                response: response,
                sourceLanguage: offer.sourceLanguage,
                generation: generation
            )
        }
    }

    /// 跨语言原文行集合变化后收口翻译提议(2026-10-02):行空 → 撤提议
    /// (提示条消失,resume 的 translation_pending 守卫解除);行在 →
    /// modules 集合刷新(提议与剩余待译章保持一致,防陈旧集合误导重试)。
    private func syncTranslationOfferWithRows() {
        if crossLanguageRows.isEmpty {
            translationOffer = nil
            // F5 标记随提议收空清除(单章重试/生成把行清完的路径);结局键同清
            // ——未来同键新提议(如再次版本 bump)可重新自动翻译
            if case .ready(let response, _) = state {
                let settledKey = response.contentHash + "|" + AppLanguage.currentWire
                DeepStaleM0MarkerPersistence.clear(settledKey)
                autoTranslationOutcomes.removeValue(forKey: settledKey)
            }
        } else if let offer = translationOffer {
            translationOffer = TranslationOffer(
                sourceLanguage: offer.sourceLanguage,
                modules: Set(crossLanguageRows.keys)
            )
        }
    }

    /// 翻译链主循环(串行 M0 → M7,镜像 runV1Chain 形态)。
    ///
    /// D10.4 关键不变式:**先译 M0**,译后 `extractChainFields` 以目标语言的
    /// structure_fingerprint / main_axis / core_loop 覆盖 v1ChainFields——
    /// M1-M7 的翻译请求(与目标语言正常生成同键)由译后字段驱动,缓存键
    /// 对齐才成立。任一模块失败即断链(已译成的保留 .ok + 双层缓存已落;
    /// 失败章标 .failed,提示条保留供重试——retryTranslation 只译剩余;
    /// 继续翻下游会混用「译后 fingerprint + 原文 innate」造出正常生成永不
    /// 会用的键,白烧 LLM,不如显式停下)。
    /// L4/F5 例外:STALE_SOURCE(原文版本过期)不断链——降级为目标语言重
    /// 生成该章(豁免配额);M0 过期时下游原文一并转重生成,防叙事错配。
    @MainActor
    private func runTranslationChain(
        response: BaziResponse,
        sourceLanguage: String,
        generation: Int
    ) async {
        // staleKey 提前到 defer 之前:defer 要在**所有**出口(含入口自弃)记录
        // 结局,必须先于 defer 可用。
        let staleKey = response.contentHash + "|" + AppLanguage.currentWire
        // 结局快照(2026-10-07 review 修复):defer 写 .interrupted 前必须比对
        // 本链起跑时的值——期间若新链已落定 .failed(重进只应手动)或成功清键,
        // 旧链 defer 一律覆写会把 .failed 冲成 .interrupted(重进变自动重试,
        // 在已知失败的上游反复烧 LLM)或把已清的键复活。值相等才允许写:
        // 覆盖「本链自己先失败(.failed)后手动重试又被换盘掐断」的升级场景。
        let outcomeAtChainStart = autoTranslationOutcomes[staleKey]
        // 世代号由 acceptTranslation 在置标志的同一同步块快照传入(镜像
        // runV1Chain(response:generation:) 的装配形态):await 期间换盘/reset
        // 已同步清标志并推进世代——本链属旧世代时 defer 不得再动标志(那会
        // 覆写新链刚置位的 true)。
        defer {
            if translationGeneration == generation {
                isTranslatingChain = false
            } else if autoTranslationOutcomes[staleKey] == outcomeAtChainStart {
                // 旧世代链 = 被换盘/reset 掐断:结局记 .interrupted——重进同盘
                // hydrate 重建提议后可再自动续译(修复前该场景恢复 .failed 假失败)
                autoTranslationOutcomes[staleKey] = .interrupted
            }
        }
        // 入口世代复检(2026-10-02 双 review):Task 起跳若晚于换盘/reset 的
        // 世代推进(offer/rows 已同步清空),旧链会以空 rows 跑完循环并落入
        // 尾块——清 F5 标记 / 提前 resume 都写在**新盘**上。此处按失配整体
        // 自弃,镜像 defer 的同款判据。
        guard translationGeneration == generation else {
            AppLogger.app.warning(
                "deepVM.runTranslationChain.stale_generation hash=\(response.contentHash, privacy: .public) gen=\(generation, privacy: .public) — 旧链起跳自弃(入口复检)"
            )
            return
        }
        // L4/F5(2026-10-01):M0 原文 STALE 降级重生成后,下游原文基于旧 M0,
        // 继续翻译会混叙事 → 下游原文章全部转重生成(同样豁免配额)。
        // F5(2026-10-02):标记提升为 VM 状态(按 contentHash|targetLang)——
        // 重试进链时 M0 行已不在 crossLanguageRows,局部变量重置会把基于旧
        // M0 的下游原文拿去翻译而非重生成(混叙事 + 缓存键错位)。
        // F5(2026-10-06):标记再落 UserDefaults——重启后提议重建仍靠它导向。
        // 损坏一次性修复(2026-10-07 外评再修,原「?? true 全局按已降级」):
        // nil = 存储损坏、集合未知——全局降级会让**所有盘所有语言**永远走
        // 豁免重生成(每盘切语言 8 次完整 LLM 生成,持续烧钱),且 clear()
        // 读改写在坏数据上恒 no-op(损坏永不自愈)、mark() 只覆写当前键(别盘
        // 「未知」被静默裁成「未降级」,混叙事原文重新可翻译)。改为:检测
        // 当场 heal + 当前键补 mark(中途断链重进仍导向重生成),本链按已
        // 降级处理(安全侧不变)。取舍:别盘键的未知状态就此一次性裁为
        // 「未标记」——残留是别盘恰有基于旧 M0 的下游原文时会走翻译,与
        // 「持续烧钱」二选一,拍板取一次性(healCorruptedStorage 注释有全账)。
        let staleM0MarkerSet = DeepStaleM0MarkerPersistence.load()
        if staleM0MarkerSet == nil {
            DeepStaleM0MarkerPersistence.healCorruptedStorage()
            DeepStaleM0MarkerPersistence.mark(staleKey)
        }
        var staleM0Downgraded = staleM0MarkerSet?.contains(staleKey) ?? true
        // 降级重生成有失败(网络等):保留原行供重试,终态走失败提示条,不 resume
        var staleRegenFailed = false
        for module in ModuleID.allCases {
            if Task.isCancelled { return }
            guard crossLanguageRows[module] != nil else { continue }
            // 世代号检查(2026-10-07 review 修复):isCurrentChart 只比 contentHash,
            // A→B→A 换回后旧链(旧世代)会被重新放行,与新链并发——双倍 LLM
            // 调用 + 交错覆写 moduleStates/v1ChainFields(旧链的译后指纹可能
            // 冲掉新链的)。世代号在任何换盘/换回/reset 都推进,是链所有权的
            // 强判据;isCurrentChart 仍保留(覆盖 state 非 .ready 的中间态)。
            guard translationGeneration == generation else {
                AppLogger.app.warning(
                    "deepVM.runTranslationChain.stale_generation_loop hash=\(response.contentHash, privacy: .public) gen=\(generation, privacy: .public) module=\(module.rawValue, privacy: .public) — 旧链中止,剩余原文保留"
                )
                return
            }
            guard isCurrentChart(response) else {
                AppLogger.app.warning("deepVM.runTranslationChain.stale_chart — 中止,剩余原文保留")
                return
            }
            if staleM0Downgraded {
                // M0 已按目标语言重生成:本章节原文基于旧 M0,翻译只会混叙事,
                // 改走正常生成(exempt 豁免;链字段来自重生成后的新 M0,键对齐)。
                // 付费无 entitlement / M4/M5 缺输入:镜像下方翻译路径口径处理。
                if module.isPaid, !hasDeepEntitlement(contentHash: response.contentHash) {
                    crossLanguageRows[module] = nil
                    continue
                }
                if module == .m4 && m4UserInput == nil {
                    moduleStates[module] = .needsInput
                    crossLanguageRows[module] = nil
                    continue
                }
                if module == .m5 && m5UserInput == nil {
                    moduleStates[module] = .needsInput
                    crossLanguageRows[module] = nil
                    continue
                }
                await runSingleV1Module(module, response: response, quotaExempt: true, chainGeneration: generation)
                // 世代复检(2026-10-02 双 review):上方 await 是秒级 interpret
                // 网络窗,期间换盘/reset 的话 runSingleV1Module 自身同盘守卫
                // 会静默丢弃(不写 moduleStates)——若继续按 moduleStates 判
                // 成败,旧链会把 staleRegenFailed/.failed 展示态写在新盘上。
                guard translationGeneration == generation else {
                    AppLogger.app.warning(
                        "deepVM.runTranslationChain.stale_generation_after_regen hash=\(response.contentHash, privacy: .public) gen=\(generation, privacy: .public) module=\(module.rawValue, privacy: .public) — 旧盘收尾丢弃"
                    )
                    return
                }
                if moduleStates[module]?.isOk == true {
                    crossLanguageRows[module] = nil
                } else {
                    // #6(2026-10-02):降级重生成失败 → 断链(原为 continue)。
                    // 继续走会让下游用**未降级**的源语言链字段(v1ChainFields
                    // 仍是失败章的原文提取值)翻译,产生正常生成永远不会用的
                    // 混合缓存键,白烧 LLM——与普通失败分支的 return 对齐。
                    // 原行保留,终态走失败提示条,重试再降级。
                    staleRegenFailed = true
                    break
                }
                continue
            }
            guard let source = crossLanguageRows[module] else { continue }
            // 付费无 entitlement:跳过翻译,保持 .ok 原文显示(后端也会拦;
            // 不标 .locked——原文已可见,锁上反而丢内容)
            if module.isPaid, !hasDeepEntitlement(contentHash: response.contentHash) {
                AppLogger.app.info("deepVM.runTranslationChain.paid_locked_skip module=\(module.rawValue, privacy: .public)")
                crossLanguageRows[module] = nil
                continue
            }
            // M4/M5 缺用户输入:翻译请求需要 user_input 维度(键对齐);
            // 改标 .needsInput,用户重填后走正常生成(目标语言,叙事一致)
            if module == .m4 && m4UserInput == nil {
                moduleStates[module] = .needsInput
                crossLanguageRows[module] = nil
                continue
            }
            if module == .m5 && m5UserInput == nil {
                moduleStates[module] = .needsInput
                crossLanguageRows[module] = nil
                continue
            }
            // 下游链字段守卫(镜像 runSingleV1Module:译后 M0 字段缺 = 提取失败)
            if module.requiresParentFingerprint {
                let missing = (v1ChainFields["structure_fingerprint"] == nil ? ["structure_fingerprint"] : [])
                    + module.requiredChainFields.filter { v1ChainFields[$0] == nil }
                if !missing.isEmpty {
                    AppLogger.app.warning(
                        "deepVM.runTranslationChain.missing_parent module=\(module.rawValue, privacy: .public) missing=\(missing.joined(separator: ","), privacy: .public)"
                    )
                    moduleStates[module] = .pending
                    // 翻译链断头兜底(2026-10-02 修复):上游原文缺失(M0 无行
                    // 可译,如中毒行被清)/译后字段提不出时,翻译路线对剩余
                    // 模块整体不可达;原样 return 会把 translationOffer 挂成
                    // 死状态——resumeV1ChainIfNeeded 的 translation_pending
                    // 守卫永远拦住自动续跑,模块卡 .pending 无人推进。弃剩余
                    // 原文行转正常生成(付费未解锁的行镜像 paid_locked_skip:
                    // 保持 .ok 原文显示,不标 .pending 等不可能到来的解锁)。
                    // L3 合并注:autoTranslationState 一并清(提议已弃,不再出
                    // 失败提示条;缺章续跑由下方 resume 接管)。
                    for remaining in crossLanguageRows.keys
                    where !remaining.isPaid
                        || hasDeepEntitlement(contentHash: response.contentHash) {
                        moduleStates[remaining] = .pending
                    }
                    crossLanguageRows.removeAll()
                    translationFailedModules.removeAll()
                    translationTokenExpired = false
                    translationOffer = nil
                    autoTranslationState = nil
                    // 提议已弃,F5 标记一并清(残留会让未来同键提议的下游
                    // 误走重生成——本路径已明确转正常生成);结局键同清(未来
                    // 同键新提议可重新自动翻译)
                    DeepStaleM0MarkerPersistence.clear(staleKey)
                    autoTranslationOutcomes.removeValue(forKey: staleKey)
                    resumeV1ChainIfNeeded()
                    return  // 上游译后字段缺失,继续只会混键,显式停
                }
            }
            moduleStates[module] = .fetching
            do {
                let parentFingerprint: String? = module.requiresParentFingerprint
                    ? v1ChainFields["structure_fingerprint"]
                    : nil
                let chainFields: [String: String] = module.requiredChainFields.reduce(into: [:]) { acc, field in
                    if let value = v1ChainFields[field] {
                        acc[field] = value
                    }
                }
                let resp = try await orchestrator.translateV1Module(
                    response: response,
                    module: module.rawValue,
                    parentFingerprint: parentFingerprint,
                    m4Input: module == .m4 ? m4UserInput : nil,
                    m5Input: module == .m5 ? m5UserInput : nil,
                    chainFields: chainFields,
                    sourceLanguage: sourceLanguage,
                    sourcePromptVersion: source.promptVersion,
                    sourceInterpretation: source.interpretation
                )
                guard translationGeneration == generation else {
                    AppLogger.app.warning(
                        "deepVM.runTranslationChain.stale_generation_after_translate hash=\(response.contentHash, privacy: .public) gen=\(generation, privacy: .public) module=\(module.rawValue, privacy: .public) — 旧链收尾丢弃(A→B→A 换回防并发)"
                    )
                    return
                }
                guard isCurrentChart(response) else { return }
                // 译后 M0 的链字段覆盖 v1ChainFields(目标语言链,D10.4 #1)
                extractChainFields(from: resp.interpretation, for: module)
                moduleStates[module] = .ok(text: resp.interpretation, cached: resp.cached)
                crossLanguageRows[module] = nil
                translationFailedModules.remove(module)
                AppLogger.app.info("deepVM.runTranslationChain.ok module=\(module.rawValue, privacy: .public) cached=\(resp.cached, privacy: .public)")
            } catch is CancellationError {
                AppLogger.app.info("deepVM.runTranslationChain.cancelled")
                return
            } catch {
                guard translationGeneration == generation else {
                    AppLogger.app.warning(
                        "deepVM.runTranslationChain.stale_generation_in_catch hash=\(response.contentHash, privacy: .public) gen=\(generation, privacy: .public) module=\(module.rawValue, privacy: .public) — 旧链失败收尾丢弃"
                    )
                    return
                }
                guard isCurrentChart(response) else { return }
                // L4/F5:STALE_SOURCE 自动降级——原文 prompt 版本过期
                // (PROMPT_VERSIONS bump 后的老缓存行),翻译会把旧版叙事固化进
                // 新版本键空间。该章改走目标语言正常生成(quotaExempt:语言切换
                // 引发,用户无过错),不断链,其余章继续翻译。M0 过期则下游全部
                // 转重生成(见 staleM0Downgraded)。
                if APIError.isStaleSource(error) {
                    AppLogger.app.warning(
                        "deepVM.runTranslationChain.stale_source_downgrade module=\(module.rawValue, privacy: .public) — 转目标语言重生成(豁免配额)"
                    )
                    // F5(2026-10-02):M0 降级即写入 VM 标记(重试进链靠它
                    // 把下游继续导向重生成;M0 行移除后局部变量不可恢复)。
                    // 2026-10-06:标记同步落盘——重启后提议重建仍需它导向
                    if module == .m0 {
                        staleM0Downgraded = true
                        DeepStaleM0MarkerPersistence.mark(staleKey)
                    }
                    await runSingleV1Module(module, response: response, quotaExempt: true, chainGeneration: generation)
                    // 世代复检(2026-10-02 双 review,同上方 staleM0Downgraded
                    // 分支):此 await 期间换盘/reset 的话,成败判定与行清除
                    // 都属旧盘收尾,不得落在新盘状态上。
                    guard translationGeneration == generation else {
                        AppLogger.app.warning(
                            "deepVM.runTranslationChain.stale_generation_after_downgrade hash=\(response.contentHash, privacy: .public) gen=\(generation, privacy: .public) module=\(module.rawValue, privacy: .public) — 旧盘收尾丢弃"
                        )
                        return
                    }
                    if moduleStates[module]?.isOk == true {
                        crossLanguageRows[module] = nil
                    } else {
                        // 重生成失败(网络等):原行保留供重试;M0 失败则下游无从
                        // 起链。#6(2026-10-02):非 M0 失败同样断链(原为
                        // continue)——继续翻译下游会混用未降级的源语言链字段,
                        // 白烧 LLM 产混合键。终态走失败提示条,重试再降级。
                        staleRegenFailed = true
                        break
                    }
                    continue
                }
                // 凭证失效(doc E,2026-10-08 维持不修决策评审):老快照盘翻译
                // 必 403,提示条与章首小注的「重试」都是死循环入口——原文保留
                // 显示 + 提示条改「重新排盘」指引(不入 translationFailedModules,
                // 章首小注即不渲染);断链:同 token 后续章必再 403,不白烧。
                if APIError.isContextTokenError(error) {
                    AppLogger.app.warning(
                        "deepVM.runTranslationChain.context_token_expired module=\(module.rawValue, privacy: .public) — 原文保留,提示条改重新排盘指引,断链"
                    )
                    moduleStates[module] = .ok(text: source.interpretation, cached: true)
                    translationTokenExpired = true
                    autoTranslationOutcomes[staleKey] = .failed
                    autoTranslationState = .failed
                    return
                }
                AppLogger.app.warning(
                    "deepVM.runTranslationChain.failed module=\(module.rawValue, privacy: .public) error=\(String(describing: error), privacy: .public) — 原文保留显示,已译成保留,剩余可重试"
                )
                // R2(2026-10-02 bug 分支):失败保留原文显示——恢复 .ok(原文),
                // 不再标 .failed(那会让这一章只剩错误文案,原文从屏幕消失)。
                // 失败事实用 translationFailedModules 标记,章首小注「翻译失败 ·
                // 重试」驱动手动重试。章节级「重试」同理转发翻译(见
                // ChapterReadingView):走重生成会扣每日次数,且 M0 重新生成后
                // 下游原文仍按旧叙事翻译,正是 staleM0Downgraded 要避免的错配。
                moduleStates[module] = .ok(text: source.interpretation, cached: true)
                translationFailedModules.insert(module)
                // L3/F1 失败分诊:离线类(且自动重试额度未用)→ 联网后回前台
                // 自动重试一次;其余 → 失败提示条(手动重试)。译完的保留,
                // 重试只译剩余。结局同步分诊(2026-10-06):离线等待记
                // .interrupted(重进/联网后自动续译的承诺保留);非离线失败记
                // .failed(重进恢复提示条走手动)。
                let offlinePending = Self.isOfflineTranslationError(error) && !offlineRetryUsed
                autoTranslationOutcomes[staleKey] = offlinePending ? .interrupted : .failed
                autoTranslationState = offlinePending ? .offlinePending : .failed
                return  // 断链:下游会混用译后指纹+原文链字段,显式停
            }
        }
        // 收尾:L4/F5 降级重生成有失败 → 失败提示条(重试 = 重走本链,原行
        // 还在);不清 offer、不 resume(resume 起链的重生成不带豁免,会把
        // 语言切换成本转嫁到用户配额)。结局记 .failed(重进恢复提示条走手动)。
        if staleRegenFailed {
            autoTranslationOutcomes[staleKey] = .failed
            autoTranslationState = .failed
            return
        }
        // 收尾:全部译完 → 清提议 + 清自动翻译展示态;原文没有的缺失模块此时
        // 按目标语言自动续跑(链上游已是译后/重生成后的 M0,叙事一致,D10.4 #3)
        if crossLanguageRows.isEmpty {
            translationOffer = nil
            autoTranslationState = nil
            translationTokenExpired = false
            DeepStaleM0MarkerPersistence.clear(staleKey)
            autoTranslationOutcomes.removeValue(forKey: staleKey)
            AppLogger.app.info("deepVM.runTranslationChain.all_translated")
            resumeV1ChainIfNeeded()
        }
    }

    /// 翻译失败的离线分诊(L3/F1):**确定未出网**的离线类 → true(联网后可
    /// 自动重试,请求未达后端零 LLM 成本);其余一律 → false(手动重试)。
    /// 判定收窄(2026-10-07 review 修复 E):只认 `.notConnectedToInternet` /
    /// `.dataNotAllowed` / `.internationalRoamingOff`——这三种系统保证请求
    /// 根本没出设备。此前的超时**不算**离线(.timedOut 可能已达后端、模型
    /// 已在生成),同理 `.networkConnectionLost`(连接中断,请求可能已送达)/
    /// `.cannotConnectToHost` / `.cannotFindHost`(连接被拒/DNS 失败,中间层
    /// 可能已转发)也不算——这些路径归 .interrupted 会让每次重进都自动重试
    /// (hydrate 每轮重建提议都复位 offlineRetryUsed,额度形同虚设),模型
    /// 调用费无上限;现在统一按真失败走 .failed + 手动重试。
    private static func isOfflineTranslationError(_ error: Error) -> Bool {
        if case .networkError(let urlError)? = error as? APIError {
            switch urlError.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                return false
            }
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
    /// failureCount 也清零(2026-09-07 起仅日志用,重置后计数从新盘重新起算)。
    /// Stage 7c:同时取消 v1 链式调用 + 清 moduleStates + v1ChainFields。
    /// 断点续跑:作废在飞链的 defer 写回(世代号推进后旧链 defer 不再动标志)。
    /// isHydrating 同步复位 + hydrateGeneration 推进(2026-10-02 双 review 补,
    /// 推翻了「不在此复位」的旧注释):reset → 表单 → calculate(新盘) 不经
    /// loadArchivedChart 换盘守卫(state 已 .empty)——在飞旧盘 hydrate 凭
    /// `!isHydrating` 守卫会把**新盘** hydrate 整体吞掉且无人重试(M4/M5 读回、
    /// 章节回填、跨语言提议全丢),旧盘收尾 resume 还会替新盘绕过 hydrate 直
    /// 接起链。镜像 chart_changed 守卫同款:旧盘收尾按世代失配自弃。
    func reset() {
        calculateTask?.cancel()
        v1ChainTask?.cancel()
        state = .empty
        lastRequest = nil
        failureCount = 0
        isChainRunning = false
        chainGeneration &+= 1
        hydrateGeneration &+= 1
        isHydrating = false
        moduleStates.removeAll()
        v1ChainFields.removeAll()
        // Stage 8 修复:清 M4/M5 用户输入,避免跨命盘污染
        // (排盘 A 填的 concern 不能给排盘 B 用,违反「八字计算必须确定性」语义)
        m4UserInput = nil
        m5UserInput = nil
        // 翻译侧状态一并复位(2026-10-02 bug 分支三查):reset → 表单 → 新盘走
        // calculate(),不经 loadArchivedChart 的换盘守卫(state 已 .empty,守卫
        // 不触发)——残留会让新盘健康章挂陈旧「翻译失败 · 重试」小注;offer/rows
        // 残留更会让 autoTranslateIfNeeded 把旧盘原文行按新盘 hash 发翻译(串台)。
        translationOffer = nil
        crossLanguageRows.removeAll()
        translationFailedModules.removeAll()
        translationTokenExpired = false
        // 同步清标志 + 推进世代(同 loadArchivedChart 换盘守卫;旧链 defer 按世代
        // 失配自弃,不再覆写新链标志)。
        translationGeneration &+= 1
        translationChainTask?.cancel()
        isTranslatingChain = false
        // L3/F1:回表单态清自动翻译展示态(提示条/章首小注随页面退场)
        autoTranslationState = nil
        // F5(2026-10-06 持久化):降级标记**不**随 reset 清——reset → 重启 →
        // 同盘提议重建的场景仍需它把下游导向重生成(清了会重新打开「旧 M0
        // 下游原文 × 新 M0 指纹混拼进共享键」的洞)。内存标记与落盘副本同源,
        // 由提议收空/兜底弃行按键清除;全量清走 ProfileView.resetAllData。
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

// MARK: - M4/M5 用户输入持久化(L2/F4,2026-10-01 语言切换走查)

/// 按 contentHash 持久化 M4/M5 用户输入(UserDefaults,JSON 编码)。
///
/// 为什么不用 SwiftData:数据小(两个短字段 × 每盘一行)、无查询需求、
/// 新 @Model = pbxproj 4 处登记 + 迁移风险,UserDefaults 足够。
/// 生命周期:写入 = submitM4/5Input;读回 = hydrateAndResume 起手(内存
/// 缺值时);清扫 = ProfileView.resetAllData(前缀全清)。**link 删除不清**
/// ——与 UserSnapshotLinkStore.delete 的「ChartSnapshot 不动,历史缓存可
/// 回溯」语义对齐(盘还在,输入就该在)。
/// 隐私:仅本机,与命盘数据同等级;「重置命盘」随全量数据一并清除。
enum DeepUserInputPersistence {

    static let m4KeyPrefix = "deep.m4Input."
    static let m5KeyPrefix = "deep.m5Input."

    struct M4Payload: Codable, Equatable {
        let age: Int
        let concern: String
    }

    struct M5Payload: Codable, Equatable {
        let assets: String
        let preference: String
    }

    static func saveM4(_ payload: M4Payload, contentHash: String?) {
        guard let contentHash else {
            // submit 只在 .ready 态可发起(阅读页表单);nil = 状态机错乱,显式留痕不落盘
            AppLogger.persistence.warning("op=deepUserInput.saveM4.skip reason=no_content_hash")
            return
        }
        guard let data = encode(payload) else { return }  // 失败跳过写入(不落空 Data 掩盖)
        UserDefaults.standard.set(data, forKey: m4KeyPrefix + contentHash)
    }

    static func saveM5(_ payload: M5Payload, contentHash: String?) {
        guard let contentHash else {
            AppLogger.persistence.warning("op=deepUserInput.saveM5.skip reason=no_content_hash")
            return
        }
        guard let data = encode(payload) else { return }  // 同上
        UserDefaults.standard.set(data, forKey: m5KeyPrefix + contentHash)
    }

    /// 读回;解码失败显式日志 + 返回 nil(不静默吞——按无输入走 .needsInput,
    /// 用户重填,不拿坏数据冒充)。
    static func loadM4(contentHash: String) -> M4Payload? {
        decode(M4Payload.self, forKey: m4KeyPrefix + contentHash)
    }

    static func loadM5(contentHash: String) -> M5Payload? {
        decode(M5Payload.self, forKey: m5KeyPrefix + contentHash)
    }

    /// 前缀全清(resetAllData「清除全部数据」)。
    static func clearAll() {
        let defaults = UserDefaults.standard
        let removed = defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(m4KeyPrefix) || $0.hasPrefix(m5KeyPrefix) }
        removed.forEach { defaults.removeObject(forKey: $0) }
        if !removed.isEmpty {
            AppLogger.persistence.info("op=deepUserInput.clearAll removed=\(removed.count, privacy: .public)")
        }
    }

    /// S10 补时辰换新 hash:把老 hash 下的 M4/M5 输入迁移到新 hash
    /// (#7,2026-10-02)。不迁移的话补时辰后输入不落新键——内存值清空后
    /// (换盘清洗)重启即丢,L2(ff26a00)要保的「重启后输入还在」在补时辰
    /// 场景失效。新 hash 已有输入则**不覆盖**(用户可能在补时辰重算后改过);
    /// 老 key 保留,与 link/ChartSnapshot 的「可回溯」语义一致。
    static func remapHash(from oldHash: String, to newHash: String) {
        guard oldHash != newHash else { return }
        var migrated: [String] = []
        if let m4 = loadM4(contentHash: oldHash),
           loadM4(contentHash: newHash) == nil {
            saveM4(m4, contentHash: newHash)
            migrated.append("m4")
        }
        if let m5 = loadM5(contentHash: oldHash),
           loadM5(contentHash: newHash) == nil {
            saveM5(m5, contentHash: newHash)
            migrated.append("m5")
        }
        if !migrated.isEmpty {
            AppLogger.persistence.info(
                "op=deepUserInput.remap_hash old=\(oldHash, privacy: .public) new=\(newHash, privacy: .public) migrated=\(migrated.joined(separator: ","), privacy: .public)"
            )
        }
    }

    // MARK: - Private

    /// 编码失败 → nil 且**不写入**(2026-10-02 review:此前返回空 Data 被照常
    /// set 进 UserDefaults,用默认值掩盖失败——坏数据潜伏到下次读取才以
    /// decode_failed 二次报错。调用方 nil 即跳过写入,错误当场留痕)。
    /// Codable 合成编码两字段 struct 实际不可能失败,此处为防御位。
    private static func encode<T: Encodable>(_ value: T) -> Data? {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            AppLogger.persistence.error(
                "op=deepUserInput.encode_failed type=\(String(describing: T.self), privacy: .public) error=\(String(describing: error), privacy: .public) — 跳过写入"
            )
            return nil
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            AppLogger.persistence.error(
                "op=deepUserInput.decode_failed key=\(key, privacy: .public) error=\(String(describing: error), privacy: .public) — 按无输入处理"
            )
            return nil
        }
    }
}

// MARK: - F5 降级标记持久化(2026-10-06 review 核实;2026-10-07 去内存镜像)

/// M0 STALE 降级标记的单一事实源(UserDefaults,JSON 编码 Set<String>),
/// 照 DeepUserInputPersistence 模式。
///
/// 为什么持久化(修复前仅 VM 内存):M0 STALE 降级重生成成功后、下游重生成
/// 完成前杀 App,重启 hydrate 会重建跨语言提议并自动续跑——内存标记丢失让
/// 下游走「翻译」而非「重生成」:新 M0 指纹 × 旧 M0 叙事原文混拼,写进正常
/// 生成的目标语言缓存键(后端按 content_hash 全局共享,毒化波及同盘所有
/// 用户)。生命周期:提议收空 / 兜底弃行 / 全部译完时按键清除;换盘与 reset
/// 都不清(键按盘隔离,见 VM 属性注释);清扫 = ProfileView.resetAllData
/// (与 M4/M5 输入同批)。
///
/// 为什么不留 VM 内存镜像(2026-10-07 review 修复):镜像 + 写穿的模式下,
/// resetAllData 只清了磁盘,活着的 VM 实例下次写穿会把内存快照**整份写回**
/// ——旧标记复活,重置等于没做。mark/clear 一律从磁盘读改写(单 VM 实例,
/// 无并发写者),读取方(runTranslationChain 起手)也直读磁盘。
enum DeepStaleM0MarkerPersistence {

    static let storageKey = "deep.staleM0DowngradedKeys"

    /// 读回;解码失败显式日志 + 返回 **nil(≠ 空集)**。
    /// 空集 = 确定无标记;nil = 存储损坏、标记集合**未知**——消费方
    /// (runTranslationChain)按「当前键已降级」处理(下游转豁免重生成):
    /// 安全侧是宁可多一次豁免重生成,也不能把基于旧 M0 的下游原文拿去翻译
    /// 混叙事进共享缓存(2026-10-07 外评重提核实:「部分进度后重启 + 解码
    /// 失败」时 M0 行已清、下游行仍在,按空集走翻译,M0 的 409 自愈救不了
    /// 没有 M0 行的重试链;原「空集自愈」理由只覆盖 M0 行还在的场景)。
    /// 检测到 nil 的主修复路径 = `healCorruptedStorage()`(调用方随即补
    /// mark 当前键),坏数据不会长期驻留。
    static func load() -> Set<String>? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        do {
            return try JSONDecoder().decode(Set<String>.self, from: data)
        } catch {
            AppLogger.persistence.error(
                "op=deepStaleM0Marker.decode_failed error=\(String(describing: error), privacy: .public) — 标记集合未知,消费方按已降级处理(安全侧:宁多重生成不混叙事)"
            )
            return nil
        }
    }

    /// 写入;编码失败显式日志跳过(标记退化为会话内,错误当场留痕不落空 Data)。
    static func save(_ keys: Set<String>) {
        do {
            let data = try JSONEncoder().encode(keys)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            AppLogger.persistence.error(
                "op=deepStaleM0Marker.encode_failed error=\(String(describing: error), privacy: .public) — 跳过写入(标记退化为会话内)"
            )
        }
    }

    /// 存储损坏的一次性修复(2026-10-07 外评 🔴):以合法**空集合**覆写坏数据。
    /// 调用点 = runTranslationChain 起手检测到 load() == nil(集合未知),调用方
    /// 随后 mark(staleKey) 落当前键——中途断链重进仍导向重生成。别盘键的未知
    /// 状态就此一次性裁为「未标记」(残留:别盘恰有基于旧 M0 的下游原文时会走
    /// 翻译混叙事)——与「全局永远按已降级(每盘切语言 8 次完整 LLM 生成,
    /// 持续烧钱)且 clear() 恒 no-op、损坏永不自愈」二选一,拍板取一次性修复。
    static func healCorruptedStorage() {
        AppLogger.persistence.error(
            "op=deepStaleM0Marker.heal_corrupted — 空集合覆写坏数据(一次性修复,当前键由调用方补 mark)"
        )
        save([])
    }

    /// 标记(读改写,磁盘为事实源):已存在则跳过落盘。解码失败(nil)按空集
    /// 起读、save 顺手以合法 JSON 覆盖——这是**罕见的二次损坏兜底**(检测点
    /// heal 之后窗口内又损坏),语义同为「只剩当前键」;主修复路径见
    /// healCorruptedStorage。
    static func mark(_ key: String) {
        var keys = load() ?? []
        guard keys.insert(key).inserted else { return }
        save(keys)
    }

    /// 清除(读改写):无此键时跳过落盘,防无谓写。坏数据上恒 no-op(集合
    /// 未知时不臆造「已清」)——损坏留给下次链起手的 healCorruptedStorage。
    static func clear(_ key: String) {
        var keys = load() ?? []
        guard keys.remove(key) != nil else { return }
        save(keys)
    }

    /// 全清(resetAllData「清除全部数据」)。
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
