import Foundation
import SwiftUI
import SwiftData

// MARK: - 状态机

/// 合盘主状态机(单选改造 + S02 detail 态)。
///
/// 七态(2026-09-07 单选直达:算成 → detail 主路径,list 退化为兜底;
/// 2026-09-29 结果页主页化:.configuring 渲染为结果壳 P5/P6 态,配置页退役):
/// - loading:命盘列表加载中
/// - empty:0 存档,引导去深度解析
/// - configuring:结果壳内容区接管——名单空 = P5 内联添加表单,非空无已选 = P6
///   提示行(2026-08-16 起 context 恒 "general")
/// - computing(completed, total):确定性合盘进行中(决策 D3 串行;单选恒 1 对)
/// - list:兜底结果列表(compute 失败/时辰拦截时承载单卡 + 重试/补时辰 CTA;
///   summaries 存 VM 字段)
/// - detail(summary, response, interpretState):单对详情(主路径;跨启动恢复直达),
///   复用 CompatibilityMainView
/// - failed(message):显式错误(S01 整体级;S03 后仅系统级)
///
/// `.list` 不内嵌 summaries:summaries 存 VM 字段。
enum CompatibilityViewState: Equatable {
    case loading
    case empty
    case configuring
    case computing(completed: Int, total: Int)
    case list
    case detail(PairSummary, CompatibilityResponse, InterpretState)
    case failed(UserFacingError)

    static func == (lhs: CompatibilityViewState, rhs: CompatibilityViewState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading): return true
        case (.empty, .empty): return true
        case (.configuring, .configuring): return true
        case (.computing(let c1, let t1), .computing(let c2, let t2)):
            return c1 == c2 && t1 == t2
        case (.list, .list): return true
        case (.detail(let s1, let r1, let i1), .detail(let s2, let r2, let i2)):
            // response 用 compatibilityHash 作相等性代理(完整比较太重)
            return s1.id == s2.id && r1.compatibilityHash == r2.compatibilityHash && i1 == i2
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - 补时辰目标(P1-1,2026-09-30)

/// 补时辰 sheet 的目标盘(视图开 sheet 时记录,dismiss 后由
/// `CompatibilityViewModel.continueAfterAddHourRemap` 消费——续接选人)。
enum AddHourTarget {
    /// 命主自己的盘(A 侧;头部「补时辰」入口 / 自己无时辰的拦截卡 CTA)。
    case selfChart
    /// 他人存档盘(B 侧;换人 sheet 无时辰行 / 他人无时辰拦截卡 CTA)。
    /// hash = 开 sheet 时的老盘 contentHash(与 dismiss 后的 remap.old 对账)。
    case partnerChart(hash: String)
}

// MARK: - ViewModel

/// 合盘 ViewModel:@Observable + 状态机驱动(单选改造 + S02 detail 按对化)。
///
/// 单选 + detail 核心(2026-09-07 单选改造,修订 08-13 多选 D1-D13 中的勾选语义):
/// - `roster: [RosterEntry]`(决策 D2 混合名单,上限 8;单选不改容量语义——
///   名单 = 对方池,勾选 = 本次排盘的那一位)
/// - `selectedEntryIds: Set<String>`(≤1 个元素;2026-09-03 名单成员资格与勾选解耦,
///   2026-09-07 起勾选单选——勾第二位自动取消第一位)
/// - `summaries: [PairSummary]`(list 兜底态用)
/// - `compute()` 串行批量 → 唯一一对算成**直达 detail**;失败/时辰拦截 → 单卡 list
///   兜底(S03 重试 / S10 补时辰 CTA 保留)
/// - `openDetail(summary)` → detail 态(查 cache + 解 response + 构造 InterpretState)
/// - `generateInterpretation()` 按 detail 态的 summary.compatibilityHash 触发(决策 D3 AI 逐对按需)
/// - 临时人隐式落地 ChartSnapshot **不建 UserSnapshotLink**(红线 D6)
///
/// 错误显式传播:名单校验失败、快照 upsert 失败、cache decode 失败照常 throw / 上抛,不用默认值掩盖。
@Observable
@MainActor
final class CompatibilityViewModel {

    /// 名单持久化根结构短名(R1,2026-09-30)。
    private typealias PersistedRoster = CompatibilityRosterPersistence.PersistedRoster

    // MARK: 配置字段

    /// 已存档命盘列表(从 UserSnapshotLink + ChartSnapshot 取)
    var archivedCharts: [ArchivedChart] = []
    var selectedChartAIndex: Int = 0

    /// B 名单(决策 D2 混合名单 = 存档勾选 + 临时输入)。
    /// 上限 8 人(`rosterMax`,决策 D2 全局池配套)。
    ///
    /// 2026-09-03 语义拆分:roster = 「名单成员资格」(添加即入册,与本次排盘无关);
    /// 是否参与本次合盘由 `selectedEntryIds` 决定。存档池行的成员资格与勾选仍等价
    /// (toggleArchived 同步维护两边);解耦只发生在临时人 / 跨启动恢复行
    /// (无存档池行可回落,取消勾选必须保留在名单里)。
    var roster: [RosterEntry] = []

    /// 名单内已勾选 entry id 集合(= 本次要排盘的人;**单选**,2026-09-07)。
    /// 不变量:
    /// - 集合至多 1 个元素(勾第二位自动让位第一位——`toggleEntrySelection` /
    ///   `toggleArchived` 换选时经 `deselectCurrentSelection` 维护)
    /// - 存档池行(`isPoolBacked(hash:)` == true):entry 在 roster ⇔ id 在本集合
    ///   (toggleArchived 维护;换选时原池行随取消勾选移出名单)
    /// - 临时人/恢复行:添加**不**入本集合(2026-09-03 拆分:「加名单」≠「选入合盘」),
    ///   由 `toggleEntrySelection` 显式勾选;换选/取消勾选都保留名单成员资格
    /// - 跨启动恢复:勾选 = 持久化的 `selectedEntryID`(R3,2026-09-30);
    ///   不在名单内 → 清空不预勾(createdAt 猜「上次那位」只在老 key 迁移时兜底一次)
    var selectedEntryIds: Set<String> = []

    /// 单临时人表单(S04 草稿态:每次「添加」push 一条 .temp 到 roster,然后表单清空)。
    /// 多条独立 .temp 在 roster 内互不干扰。
    /// 默认值单一事实源:`CompatibilityRosterPersistence.defaultTempDraft`(VM init 会用持久化草稿覆盖)。
    /// 2026-09-19 去默认值 + 拆双字段(镜像深度表单 S03):
    /// - tempBirthDate 改 Date?(nil = 未选初始态,validateTempForm 拦截——
    ///   不再预填 1990-03-15,那是替用户填的假值)
    /// - tempBirthTime 新增独立绑定(时刻表盘恒有锚点,日期未选不阻塞拨时刻;
    ///   锚点与深度表单共用 DeepAnalysisViewModel.defaultBirthTimeAnchor 单一事实源),
    ///   提交时 combinedTempBirthDate() 合成、秒归 0
    /// - tempGender 改 String?(nil = 未选初始态,不再默认 male——不替用户做决定)
    var tempBirthDate: Date? = CompatibilityRosterPersistence.defaultTempDraft.birthDate
    var tempBirthTime: Date = DeepAnalysisViewModel.defaultBirthTimeAnchor
    var tempGender: String? = CompatibilityRosterPersistence.defaultTempDraft.gender
    /// 出生地(全球城市搜索 / S05 自定义地点;无默认,必选)
    var tempPlace: PlaceSelection? = CompatibilityRosterPersistence.defaultTempDraft.place
    /// S04 新增:临时人可选「称呼」字段(会话内显示)。
    /// 空字符串视为未填 → 跨启动兜底名「对方+出生日期」。
    var tempAlias: String = ""

    /// 临时人出生地时区 Calendar(WYSIWYG:表盘与钟面提取按出生地,不随设备漂移)。
    /// 城市与自定义地点共用 BirthPlaceResolver 单一事实源(S05)。
    var tempPlaceCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        let tzName = BirthPlaceResolver.effectiveTimezoneName(tempPlace)
        if let tz = tzName.flatMap({ TimeZone(identifier: $0) }) {
            calendar.timeZone = tz
        } else {
            calendar.timeZone = .current
        }
        return calendar
    }

    /// 合并 tempBirthDate + tempBirthTime → 完整出生 Date(对方出生地钟面合成;
    /// 镜像 DeepAnalysisViewModel.combinedBirthDate:Y/M/D 取日期行、H/M 取时刻行、秒归 0)。
    /// 日期未选 / Calendar 合成失败 → 显式抛错(错误显式传播;提交路径 validateTempForm 先行)。
    private func combinedTempBirthDate() throws -> Date {
        guard let tempBirthDate else {
            throw UserFacingError.generic(message: L10n.BirthForm.errorDateRequired)
        }
        let calendar = tempPlaceCalendar
        let hour = calendar.component(.hour, from: tempBirthTime)
        let minute = calendar.component(.minute, from: tempBirthTime)
        guard let combined = calendar.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: tempBirthDate
        ) else {
            throw UserFacingError.generic(message: L10n.BirthForm.errorCombineFailed)
        }
        return combined
    }

    /// 临时人钟面 → 裸钟面字符串(S02 契约;城市/自定义地点时区,S05)。
    /// 2026-09-19 拆双字段后由 combinedTempBirthDate() 合成取值(日期未选在此显式抛错)。
    private func tempWallTimeString() throws -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = tempPlaceCalendar.timeZone
        return formatter.string(from: try combinedTempBirthDate())
    }

    /// 合盘维度。2026-08-16 决策:维度 picker(通用/婚姻/事业)移除,固定 "general"。
    /// 原因:context 参与 compatibilityHash,可切换导致同一对人换维度重复付 $11.99;
    /// 且「婚姻/事业」预设与 08-14「两人磁场」单轨定位矛盾。
    /// 数据层/后端契约保留 context 字段,仅客户端源头固定(历史非 general 快照不再恢复展示)。
    let context = "general"

    // MARK: 主状态 + summaries

    var state: CompatibilityViewState = .loading

    /// 兜底 list 态的卡片摘要(compute 失败/拦截的单卡 + 单对重试)。
    /// 进入 detail 时不清空,跨启动恢复时装「上次那位」的单条 summary。
    var summaries: [PairSummary] = []

    /// S03:正在重试的对 id 集合(UI 据此 disable 重试按钮,避免同对并发双请求)。
    var retryingIds: Set<String> = []

    // MARK: 依赖

    private let orchestrator: CompatibilityOrchestrator
    private let chartStore: ChartSnapshotStore
    private let compatibilityStore: CompatibilitySnapshotStore
    private let entitlementStore: EntitlementStore
    private let modelContext: ModelContext

    private var computeTask: Task<Void, Never>?
    /// 本 VM 是否已接管本地名单(恢复过,或本地原本无名单时首写成功)。
    /// false 时 `persistRoster` 遇本地已有非空名单拒写(防未恢复的空内存名单覆盖)。
    private var ownsPersistedRoster = false
    private var interpretTask: Task<Void, Never>?
    /// detail 态进入时的 cache 查询 task(完成后续刷新 interpretState)。
    private var cacheReadTask: Task<Void, Never>?
    /// 引擎规则版本失配快照的后台重算 task(2026-10-07;openDetail 触发,
    /// 落定后仍在本对则原位刷新评估卡)。
    private var engineRefreshTask: Task<Void, Never>?
    /// 门内生成(runGatedGeneration)的 task(第九轮 review #4):手动重试 /
    /// 购买回调先过引擎规则门再转 generateInterpretation,门等待期的 Task 必须
    /// 持有——不持有 = 购买回调的 Task 无人管,退出/换对后与自动链并发双起
    /// generateInterpretation(双 LLM + 双扣次数)。openDetail /
    /// clearDetailKeepRoster 取消。
    private var interpretGateTask: Task<Void, Never>?

    /// 最近一次引擎重算(refreshStaleEngineAssessment)的**按对**结局;
    /// 重算成功记 .success、真失败记 .failure,取消不记(那是换对,不是重算
    /// 失败,2026-10-07 review #2)。引擎规则门拦下生成时按对透出真实根因
    /// (错误显式传播:不拿固定「网络不可用」冒充 500/解码失败);第九轮
    /// review #5:原全局单值会显示别对的错误、被别对的成功清掉,改按
    /// compatibilityHash 键控。门尾还消费 .success 语义:重算成功而版本仍
    /// 落后(部署倒挂/旧后端不回 rule_version)时放行生成(见
    /// engineRuleBecameFresh 尾注)。
    private var engineRefreshOutcomes: [String: Result<Void, Error>] = [:]

    // MARK: 跨语言翻译(D10.5,S7)

    /// 翻译提议(当前语言缓存 miss 但其它语言有既有解读):先显示原文,
    /// L3/F1(修订 D10.5)打开即自动翻译,提示条只在失败时出现。
    /// 换对(openDetail)/重新生成时清空。
    struct TranslationOffer: Equatable {
        /// 原文语言(wire 值)
        let sourceLanguage: String
        /// 原文所在 module(compatibility_free / compatibility_paid,
        /// 翻译请求该用的 module——付费键翻译走后端 entitlement 同检)
        let module: String
        let promptVersion: Int
        let text: String
    }

    private(set) var translationOffer: TranslationOffer?
    /// 翻译在飞(提示条隐藏,译文落态后恢复)。
    private(set) var isTranslating = false
    /// 翻译 task(换对/重新生成时取消)。
    private var translateTask: Task<Void, Never>?

    /// Bug5(2026-10-06 review 核实):最近一次豁免生成(quotaExempt=true)所属
    /// 的 compatibilityHash;非豁免尝试置 nil。STALE_SOURCE 降级链失败后落
    /// .failed,**该对**的结果页重试透传豁免——语言切换成本不得转嫁用户配额
    /// (修复前重试恒走默认 false 扣次数,与深度解析「重试再降级仍豁免」不一致);
    /// 次数耗尽用户则直接卡 dailyLimitReached。按对记录(而非全局 Bool)防
    /// 跨对泄漏:A 对豁免失败后,别对的旧 .failed 重试不得蹭豁免白送配额。
    /// (private(set):回归测试直读,断言跨对不清除;2026-10-07 review #4。)
    private(set) var exemptAttemptCompatHash: String?

    /// 解读 Task 在飞标记(2026-10-07 review 修复):值 = 在飞对 hash + token
    /// (token 防旧 Task 的 defer 误清新 Task 的标记——同对手动重新生成时)。
    /// 用途:openDetail 重进时,该对的(豁免或常规)重生成仍在飞 → cacheReadTask
    /// 不得再起翻译(修复前:重进 → 跨语言命中 → 自动翻译 → 原文过期 →
    /// generateInterpretation 取消**在飞且后端已扣费**的重生成 → 再起新重生成
    /// = 同对双花 LLM),autoGenerate 也不得对同对重复起链。
    private var interpretInFlight: (compatHash: String, token: UUID)?

    /// L3/F1(2026-10-01 拍板,修订 D10.5):跨语言命中 → 打开即自动翻译。
    /// 翻译中提示条隐藏,只在失败时出现(重试入口);nil = 不显示。
    private(set) var translationFailed = false
    /// 自动翻译会话去重 + 结局分诊(2026-10-06 修订,镜像深度解析):同
    /// (compatibilityHash, target) 自动只起一次(防反复 openDetail 循环烧
    /// LLM);但记录上次尝试的**结局**——被换对/退出 detail 打断(translateTask
    /// 被 openDetail/clearDetailKeepRoster 取消)不算失败,重开续译剩余;真
    /// 失败才恢复提示条走手动(修复前一律 translationFailed=true:换对往返被
    /// 谎报成「翻译失败」)。
    private enum AutoTranslationOutcome: Equatable {
        /// 中断(translateTask 被取消)——重开可再自动续译
        case interrupted
        /// 落定失败——恢复失败提示条,只走手动重试
        case failed
    }
    private var autoTranslationOutcomes: [String: AutoTranslationOutcome] = [:]

    init(
        orchestrator: CompatibilityOrchestrator,
        chartStore: ChartSnapshotStore,
        compatibilityStore: CompatibilitySnapshotStore,
        entitlementStore: EntitlementStore,
        modelContext: ModelContext
    ) {
        self.orchestrator = orchestrator
        self.chartStore = chartStore
        self.compatibilityStore = compatibilityStore
        self.entitlementStore = entitlementStore
        self.modelContext = modelContext

        // UX:临时表单默认值改"上次填过的"(加第二个临时人时只改称呼/时间)。
        // alias 不持久化(每次默认空,避免连续加多个相同 alias)。
        applyTempDraft(CompatibilityRosterPersistence.loadTempDraft())
    }

    // MARK: - 常量

    /// 名单上限(决策 D2,全局池 10 次/天配套)。
    static let rosterMax = 8

    // MARK: - 已存档命盘加载

    /// 从 UserSnapshotLink 取所有已存档命盘(按 createdAt DESC),并默认选最新一条为 A。
    /// 0 条 → .empty;>0 条 → .configuring。
    func loadArchivedCharts() {
        do {
            let links = try modelContext.fetch(FetchDescriptor<UserSnapshotLink>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            ))
            var charts: [ArchivedChart] = []
            for link in links {
                let hash = link.snapshotHash
                let pred = #Predicate<ChartSnapshot> { $0.contentHash == hash }
                let snapshots = try modelContext.fetch(FetchDescriptor<ChartSnapshot>(predicate: pred))
                guard let snapshot = snapshots.first else {
                    AppLogger.persistence.error(
                        "op=compatibility.loadArchivedCharts missing_snapshot hash=\(hash, privacy: .public)"
                    )
                    throw CompatibilityViewModelError.archivedSnapshotMissing(hash: hash)
                }
                let bazi = try chartStore.decodeResponse(from: snapshot)
                // S05:日柱歧义盘日主留白「—」(不猜;S11 roster 不可合盘标记拦截上游)
                let dayMaster = bazi.pillars.day?.gan ?? "—"
                charts.append(ArchivedChart(
                    snapshotHash: hash,
                    alias: link.alias,
                    birthDate: snapshot.birthSolarTime,
                    gender: snapshot.gender,
                    dayMaster: dayMaster,
                    yearBranchZodiac: bazi.yearBranchZodiac,
                    snapshot: snapshot
                ))
            }
            archivedCharts = charts
            if charts.isEmpty {
                state = .empty
            } else {
                selectedChartAIndex = 0
                if case .loading = state {
                    state = .configuring
                } else if case .failed = state {
                    state = .configuring
                }
            }
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.loadArchivedCharts failed error=\(String(describing: error), privacy: .public)"
            )
            // 不静默吞:错误显式传到 UI(人话文案,原始 error 已记上方日志)
            state = .failed(.generic(message: String(localized: "读取命盘存档失败,请重试")))
        }
    }

    // MARK: - 名单管理(决策 D2 / D11)

    /// 当前 A 盘 hash(候选池排除自己用)。
    var currentPersonAHash: String? {
        archivedCharts[safe: selectedChartAIndex]?.snapshotHash
    }

    /// 名单内已勾选的 entry(顺序同 roster;compute / CTA / 摘要的唯一消费源)。
    var selectedRosterEntries: [RosterEntry] {
        roster.filter { selectedEntryIds.contains($0.id) }
    }

    /// 名单内已勾选存档 hash 集合(供名单 UI 回显;2026-09-07「更换」menu 拔除后
    /// 不再作置灰判据)。
    /// 2026-09-03 起按勾选过滤:未勾选的跨启动恢复行(.archived 无池行)不再计入。
    var selectedArchivedHashes: Set<String> {
        Set(selectedRosterEntries.compactMap { entry -> String? in
            if case .archived(let hash) = entry { return hash }
            return nil
        })
    }

    /// 存档 hash 在候选池(`archivedCharts`)内是否有对应行(true = 池行,
    /// false = 跨启动恢复行)。单一事实源:`toggleEntrySelection` 的路由判据与
    /// ConfigView `orphanRowModel` 的补行判据共用同一判定,防两处实现漂移导致
    /// 行渲染与点击路由分叉。
    func isPoolBacked(hash: String) -> Bool {
        archivedCharts.contains(where: { $0.snapshotHash == hash })
    }

    // MARK: - 结果壳头部派生(P1/P2,2026-09-29;头部与换人 sheet 勾选态共用)

    /// 头部「你」侧展示(命主 A 盘派生;称呼 2026-10-07 并入统一的「你/You」,
    /// 不再用「我/Me」——原与表格/分布区的 you 两种叫法割裂)。
    /// 用显示专用 selfDisplay(EN "You");prompt 侧继续 selfReferenceYou
    /// (EN "you")——后者进 prompt_hash,改大小写 = EN 缓存全失效。
    var currentSelfDisplay: PartnerDisplay {
        let chart = archivedCharts[safe: selectedChartAIndex]
        let dayMaster = chart?.dayMaster
        return PartnerDisplay(
            entryID: nil,
            name: L10n.Compatibility.selfDisplay,
            dayMaster: dayMaster,
            dayMasterElementKey: dayMaster.flatMap(ElementColors.ofGan),
            birthDateString: chart.map { Self.displayDateFormatter.string(from: $0.birthDate) }
        )
    }

    /// 头部当前对方(单一事实源;`selectedEntryIds` + roster 派生)。
    /// 已有该对 summary(算成/失败/拦截卡)→ 用其展示值;否则按 roster entry
    /// 派生——推演一开始头部立即切到新对方名(P3),不等结果落地。
    var currentPartner: PartnerDisplay? {
        guard let entry = selectedRosterEntries.first else { return nil }
        if let summary = summaries.first(where: { $0.entry == entry }) {
            return PartnerDisplay(
                entryID: entry.id,
                name: summary.displayName,
                dayMaster: summary.dayMaster.isEmpty ? nil : summary.dayMaster,
                dayMasterElementKey: summary.dayMaster.isEmpty ? nil : ElementColors.ofGan(summary.dayMaster),
                birthDateString: summary.birthDate.map { Self.displayDateFormatter.string(from: $0) }
            )
        }
        return partnerDisplay(for: entry)
    }

    /// 头部生日展示格式(设备时区,与名单行历史口径一致)。
    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    /// 按 roster entry 派生对方展示值(无 summary 时)。
    /// 存档行:优先 `archivedCharts`(池行);跨启动恢复行查 `chartStore`。
    /// 临时人:alias / 兜底名 + **出生地钟面**日期前缀(设备时区换算会错一天);
    /// resolvedHash 有值(算过)→ 读 B 快照补日主与生日。
    /// store 查询/解码失败 → 显式记日志 + 最小展示(名字兜底、生日/日主留空)——
    /// 展示层降级不掩盖错误,computePair 发起路径会再抛真错误(S03 对级隔离)。
    /// (2026-09-29 S2 起 internal:换人 sheet 的 PartnerRow 复用同一派生,
    /// 头部与行展示单一事实源。)
    func partnerDisplay(for entry: RosterEntry) -> PartnerDisplay {
        switch entry {
        case .archived(let hash):
            if let chart = archivedCharts.first(where: { $0.snapshotHash == hash }) {
                return PartnerDisplay(
                    entryID: entry.id,
                    name: chart.alias,
                    dayMaster: chart.dayMaster,
                    dayMasterElementKey: ElementColors.ofGan(chart.dayMaster),
                    birthDateString: Self.displayDateFormatter.string(from: chart.birthDate)
                )
            }
            do {
                guard let snapshot = try chartStore.get(contentHash: hash) else {
                    throw CompatibilityViewModelError.archivedSnapshotMissing(hash: hash)
                }
                let bazi = try chartStore.decodeResponse(from: snapshot)
                let dayMaster = bazi.pillars.day?.gan ?? "—"
                let dateStr = Self.fallbackDateString(snapshot.birthSolarTime,
                                                       timezoneName: snapshot.cityTimezone)
                return PartnerDisplay(
                    entryID: entry.id,
                    name: L10n.CompatibilityPartner.fallbackName(dateStr),
                    dayMaster: dayMaster,
                    dayMasterElementKey: ElementColors.ofGan(dayMaster),
                    birthDateString: dateStr
                )
            } catch {
                AppLogger.persistence.error(
                    "op=compatibility.partnerDisplay failed hash=\(hash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                return PartnerDisplay(
                    entryID: entry.id,
                    name: String(localized: "对方"),
                    dayMaster: nil,
                    dayMasterElementKey: nil,
                    birthDateString: nil
                )
            }
        case .temp(let input, let alias, let resolvedHash, _):
            let name: String
            if let alias, !alias.isEmpty {
                name = alias
            } else {
                name = L10n.CompatibilityPartner.fallbackName(input.wallClockDisplay)
            }
            var dayMaster: String?
            var birthDateString = String(input.birthDatetime.prefix(10))
            if let resolvedHash {
                do {
                    guard let snapshot = try chartStore.get(contentHash: resolvedHash) else {
                        throw CompatibilityViewModelError.archivedSnapshotMissing(hash: resolvedHash)
                    }
                    let bazi = try chartStore.decodeResponse(from: snapshot)
                    dayMaster = bazi.pillars.day?.gan
                    birthDateString = Self.fallbackDateString(
                        snapshot.birthSolarTime, timezoneName: snapshot.cityTimezone
                    )
                } catch {
                    // 展示层降级(保留钟面前缀)+ 显式日志;快照真错误由 computePair 抛
                    AppLogger.persistence.error(
                        "op=compatibility.partnerDisplay temp_snapshot_read failed hash=\(resolvedHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                }
            }
            return PartnerDisplay(
                entryID: entry.id,
                name: name,
                dayMaster: dayMaster,
                dayMasterElementKey: dayMaster.flatMap(ElementColors.ofGan),
                birthDateString: birthDateString
            )
        }
    }

    /// 点选名单行(临时人 / 跨启动恢复行的点击路径;**单选**,2026-09-07)。
    /// - 存档池行(有对应存档)不走此路径:成员资格即勾选,路由回 `toggleArchived`
    ///   (取消勾选 = 移出名单,池行本身仍在列表)——维持「roster 存档成员 ⇔ 已勾选」不变量
    /// - 临时人 / 恢复行:点已勾行 = 取消勾选(保留名单成员资格,2026-09-03 拆分;
    ///   移出名单走 `removeRosterEntry` + View 层确认);点未勾行 = **换选**
    ///   (原勾选让位——池行随取消移出名单,临时/恢复行只清勾选)
    func toggleEntrySelection(_ entry: RosterEntry) {
        if case .archived(let hash) = entry, isPoolBacked(hash: hash) {
            toggleArchived(hash: hash)
            return
        }
        if selectedEntryIds.contains(entry.id) {
            selectedEntryIds.remove(entry.id)
            persistRoster()
        } else {
            selectEntryExclusively(entry)
        }
    }

    /// 单选勾选原语(2026-09-29 P3 抽出,`toggleEntrySelection`「选中」分支与
    /// `selectPartner` 共用,防两处实现漂移):让位原勾选后把 entry 设为唯一勾选。
    /// 存档池行经 `toggleArchived` 入册(满员/无时辰/A 自己守卫 + 名单维护);
    /// 临时人/恢复行直接让位勾选。
    /// 池行**已在名单但未勾选**(跨启动恢复、上次对快照缺失/被清时驻留)→ 原地
    /// 勾选,不走 `toggleArchived` 的「再点 = 移除」分支——P3 点行 = 选中语义下,
    /// 移除只应经 `removeRosterEntry`(管理操作 + 确认弹窗),误走会静默丢人。
    private func selectEntryExclusively(_ entry: RosterEntry) {
        if case .archived(let hash) = entry, isPoolBacked(hash: hash) {
            if roster.contains(where: { $0.id == entry.id }) {
                deselectCurrentSelection()
                selectedEntryIds = [entry.id]
                persistRoster()
                return
            }
            toggleArchived(hash: hash)
            return
        }
        deselectCurrentSelection()
        selectedEntryIds = [entry.id]
        persistRoster()
    }

    /// 单选让位(2026-09-07):清空当前勾选;原勾选若是存档池行,随取消勾选移出名单
    /// (维持「池行成员资格 ⇔ 勾选」不变量);临时人/恢复行只清勾选不移出。
    private func deselectCurrentSelection() {
        for previous in selectedRosterEntries {
            selectedEntryIds.remove(previous.id)
            if case .archived = previous {
                roster.removeAll { $0.id == previous.id }
            }
        }
    }

    /// 名单内是否已有临时人(S04 后多条,此处仅用于 UI 展示提示)。
    var hasTempInRoster: Bool {
        roster.contains { $0.isTemp }
    }

    /// 名单内临时人数量(S04 后多条)。
    var tempCountInRoster: Int {
        roster.filter(\.isTemp).count
    }

    /// 勾选 / 取消勾选存档对方(**单选**,2026-09-07:换选时原勾选让位)。
    /// - 排除 A 盘自己(决策 D1:A 盘保持单选,自己不可入名单)
    /// - S11 发起拦截(更早一层):他人命盘无时辰(payload 判据,与 S07 computePair
    ///   整对拦截同源)→ 不可入名单,点击轻提示在 View 层,此处 VM 守卫兜住所有调用路径;
    ///   已在名单的(跨启动恢复的拦截对)不受影响——本函数前半段是移除语义,照常走
    /// - 上限校验:加入时若已达 `rosterMax` 静默拒绝(UI 应提前 disable;
    ///   让位先于上限校验——原池行让位释放的名额立即可用)
    func toggleArchived(hash: String) {
        if let idx = roster.firstIndex(where: { $0.archivedSnapshotHash == hash }) {
            let removed = roster.remove(at: idx)
            selectedEntryIds.remove(removed.id)
            persistRoster()
            return
        }
        guard hash != currentPersonAHash else {
            AppLogger.app.warning("op=compatibility.toggleArchived skip reason=is_person_a hash=\(hash, privacy: .public)")
            return
        }
        if archivedCharts.contains(where: { $0.snapshotHash == hash }),
           archivedHourGate(hash: hash) != .hourKnown {
            AppLogger.app.warning("op=compatibility.toggleArchived skip reason=hour_unknown hash=\(hash, privacy: .public)")
            return
        }
        guard roster.count < Self.rosterMax else {
            AppLogger.app.warning("op=compatibility.toggleArchived skip reason=roster_full hash=\(hash, privacy: .public)")
            return
        }
        // 单选让位:原勾选的池行移出名单,临时/恢复行只清勾选
        deselectCurrentSelection()
        let entry = RosterEntry.archived(snapshotHash: hash)
        roster.append(entry)
        selectedEntryIds = [entry.id]
        persistRoster()
    }

    // MARK: - 换人(P3:选中 + 立即合盘,2026-09-29 结果页主页化)

    /// 结果壳换人入口:把 entry 设为唯一对方并立即推演(P3)。
    /// - 已是当前对方且结果在展(.detail)→ no-op(换人 sheet 点当前人 = 仅关
    ///   sheet 不重算);`force: true` 绕过(S2 修改当前对方 / S10 补时辰后
    ///   对当前对强制重算)
    /// - 让位/勾选复用 `selectEntryExclusively` 原语(不复制单选逻辑);勾选被
    ///   守卫拒收(满员 / 他人无时辰 / A 自己)→ **不发起 compute**(compute 按
    ///   `selectedRosterEntries` 消费,带着旧勾选跑 = 算错人),显式记日志
    /// - 推演中换人 → `compute()` 内既有 `computeTask?.cancel()`(D13 竞态缓解)
    func selectPartner(_ entry: RosterEntry, force: Bool = false) {
        let alreadySelected = selectedEntryIds == [entry.id]
        if alreadySelected, !force, case .detail = state {
            AppLogger.app.info(
                "compatVM.selectPartner no_op reason=already_current entry_id=\(entry.id, privacy: .public)"
            )
            return
        }
        if !alreadySelected {
            selectEntryExclusively(entry)
            guard selectedEntryIds == [entry.id] else {
                // 守卫拒收(不上名单/不勾选):不让 compute 按旧勾选跑错对;
                // UI 层本应 disable 这些行,走到这里说明状态错乱,显式记录
                AppLogger.app.error(
                    "compatVM.selectPartner rejected entry_id=\(entry.id, privacy: .public) state=\(String(describing: self.state), privacy: .public)"
                )
                return
            }
        }
        compute()
    }

    // MARK: - S11 roster 不可合盘标记(判据 = 本地存档 payload,零网络)

    /// 当前 A 盘(自己)的时辰判据。
    /// 自己无时辰 → 名单整体标记 + 解释行 + 全部对不可用(表单/行置灰,
    /// 头部「补时辰」是唯一解锁路径)。
    /// 判据与 S07 computePair 拦截同源(存档 payload `hourUnknownGate`),
    /// 标记层只是把同一判据提前到配置态;decode 失败显式记日志后按
    /// `.hourKnown` 放行(发起路径会再次 decode 并显式传播错误,标记层
    /// 不用拦截态掩盖解码故障,对齐 `currentDetailHourUnknownGate` 先例)。
    var currentPersonAHourGate: HourUnknownGate {
        guard let chart = archivedCharts[safe: selectedChartAIndex] else { return .hourKnown }
        return archivedHourGate(hash: chart.snapshotHash)
    }

    /// 自己无时辰 → 名单整体标记(全部对不可用)。
    var isSelfHourUnknown: Bool {
        currentPersonAHourGate != .hourKnown
    }

    /// 他人存档命盘自身是否无时辰(与 A 盘选择无关的固有判据)。
    /// 供存档多选行标记用(对级标记用 `isPairHourUnknownBlocked`,含 A 盘侧)。
    func isArchivedHourUnknown(hash: String) -> Bool {
        archivedHourGate(hash: hash) != .hourKnown
    }

    /// 指定 roster entry 对应的「对」是否标「不可合盘」(任一方无时辰即拦)。
    /// - 他人无时辰 → 该对标记 + 不可发起
    /// - 自己无时辰 → 全部对标记(整体解释行由 UI 层渲染)
    /// - 临时人恒带完整钟面(PersonBInput 契约),无时辰语义不存在 → 仅由 A 盘决定
    ///
    /// 每次调用现读 payload(内容寻址 hash → payload 不可变;S10 补时辰换新盘
    /// 后按新 payload 翻转);名单上限 8,配置态每次渲染 ≤9 次 decode,可接受。
    func isPairHourUnknownBlocked(entry: RosterEntry) -> Bool {
        if isSelfHourUnknown { return true }
        if case .archived(let hash) = entry {
            return archivedHourGate(hash: hash) != .hourKnown
        }
        return false
    }

    /// 存档 hash → 时辰判据(单一事实源 = ChartSnapshot payload decode,零网络)。
    /// hash 在 `archivedCharts` 内 → 直接解其 snapshot(加载路径已 fetch);
    /// 不在(跨启动恢复的临时人持久化为 `.archived` hash,无 link)→ 查 `chartStore`;
    /// 快照缺失 / decode 失败 → 显式记日志后按 `.hourKnown` 放行
    /// (缺失快照的真正错误在 computePair 抛「B 盘存档已不存在」,对级隔离呈现)。
    private func archivedHourGate(hash: String) -> HourUnknownGate {
        do {
            if let chart = archivedCharts.first(where: { $0.snapshotHash == hash }) {
                return try chartStore.decodeResponse(from: chart.snapshot).hourUnknownGate
            }
            if let snapshot = try chartStore.get(contentHash: hash) {
                return try chartStore.decodeResponse(from: snapshot).hourUnknownGate
            }
            AppLogger.persistence.warning(
                "op=compatibility.archivedHourGate snapshot_missing hash=\(hash, privacy: .public)"
            )
            return .hourKnown
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.archivedHourGate decode_failed hash=\(hash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return .hourKnown
        }
    }

    /// S10 触点路由:`.hourUnknownBlocked` 卡片 CTA 应给哪张盘开补时辰 sheet。
    ///
    /// - 自己(A 盘)无时辰 → 自己的盘(补上后全部对恢复,根因在 A);
    /// - 他人存档无时辰 → 该对 `personBHash`(S07 拦截卡对存档对方保留 hash);
    /// - 临时对方(personBHash 空串)→ nil:临时人盘无 link、无触点上下文,
    ///   CTA 不渲染(换人重填比补时辰更贴场景——临时输入本是完整钟面契约)。
    func addHourTargetHash(forBlockedPair summary: PairSummary) -> String? {
        if isSelfHourUnknown { return currentPersonAHash }
        if case .archived = summary.entry, !summary.personBHash.isEmpty {
            return summary.personBHash
        }
        return nil
    }

    /// 表单当前值 → .temp entry 的三要素(校验 / 地点解析 / PersonBInput 构造 / alias trim)。
    /// 添加与修改共用单一事实源:PersonBInput 字段或 trim 规则变化只改此处,
    /// 防两条路径产出漂移(添加与修改算出不同 input = 对级数据 bug)。
    private func makeTempInputFromForm() throws -> (input: PersonBInput, alias: String?, place: PlaceSelection) {
        try validateTempForm()
        // 出生地字段解析走单一事实源(S05:城市/自定义地点;validateTempForm 已保证非空)
        guard let place = tempPlace else {
            throw UserFacingError.generic(message: String(localized: "请选择出生城市"))
        }
        // 性别未选:validateTempForm 先行拦截,理论不可达;契约字段非 Optional,
        // 显式解包抛错,不静默兜 "male"(2026-09-19 去默认值)
        guard let tempGender else {
            throw UserFacingError.generic(message: L10n.BirthForm.errorGenderRequired)
        }
        let resolved = BirthPlaceResolver.resolve(place)
        let input = PersonBInput(
            birthDatetime: try tempWallTimeString(),
            timezone: resolved.timezone,
            gender: tempGender,
            longitude: resolved.longitude,
            latitude: resolved.latitude,
            placeName: resolved.placeName,
            geonameId: resolved.geonameId
        )
        // alias 空字符串视为 nil(统一兜底名判定)
        let alias = tempAlias.trimmingCharacters(in: .whitespaces)
        return (input, alias.isEmpty ? nil : alias, place)
    }

    /// 添加临时对方到名单(S04:多条,每次 append 一条独立 .temp)。
    /// 校验失败抛 `UserFacingError`(不静默吞,CLAUDE.md 错误显式传播)。
    /// 成功后:写入 tempDraft 持久化 + 重置表单为"上次填过的"(alias 清空)。
    ///
    /// 2026-09-03:加入名单**不等于**勾选——新 entry 落位时未勾选
    /// (不进 `selectedEntryIds`),是否参与本次合盘由用户在名单上显式勾选。
    /// - Returns:新入册的 entry(调用方据此标「新」朱印,不依赖 append 位置的实现细节)。
    @discardableResult
    func addTempToRoster() throws -> RosterEntry {
        // 错误优先级与抽取前一致:表单校验(makeTempInputFromForm 内)> 满员 > 重复
        let (input, alias, place) = try makeTempInputFromForm()
        guard roster.count < Self.rosterMax else {
            throw UserFacingError.generic(message: String(format: String(localized: "名单已达上限 %lld 人"), Self.rosterMax))
        }
        let newEntry: RosterEntry = .temp(input: input, alias: alias, resolvedHash: nil, place: place)
        // 去重:同 id entry 已在 roster → 抛错
        // 避免 ForEach 重复 id 警告 + 列表少卡 + 冗余 API 调用(内容寻址 → 同 hash)
        if roster.contains(where: { $0.id == newEntry.id }) {
            AppLogger.app.warning("op=compatibility.addTempToRoster skip reason=duplicate entry_id=\(newEntry.id, privacy: .public)")
            throw UserFacingError.generic(message: String(localized: "名单已存在相同的对方"))
        }
        // UX:保存当前字段为草稿(下次添加时默认值用这次的,加多个临时人时只改称呼/时间)
        CompatibilityRosterPersistence.saveTempDraft(
            .init(
                birthDate: tempBirthDate,
                birthTime: tempBirthTime,
                gender: tempGender,
                place: tempPlace
            )
        )
        roster.append(newEntry)
        persistRoster()
        return newEntry
    }

    /// 添加成功后由 View 调:重置表单为"上次填过的"(本次刚保存的草稿)。
    /// alias 不持久化,每次清空(避免连续加多个相同 alias 触发去重)。
    func resetTempDraftForm() {
        applyTempDraft(CompatibilityRosterPersistence.loadTempDraft())
        tempAlias = ""
    }

    /// 把草稿字段回填临时表单(init 与 resetTempDraftForm 共用;alias 不在内,永远单独处理)。
    /// 2026-09-19 birthTime 回落链(不静默编 0 点,也不丢用户上次选的时分):
    /// 1. 新草稿自带 birthTime → 直用;
    /// 2. 旧单字段草稿(无 birthTime key)→ 承接 birthDate 完整 instant——旧草稿的
    ///    时分编码在 birthDate 里,直接双写即保住「上次填过的」语义(草稿=上次值,
    ///    升级不降级);旧默认草稿 birthDate == 锚点同一 instant,未触碰场景零变化;
    /// 3. 全空草稿 → 深度表单同款锚点。
    private func applyTempDraft(_ draft: CompatibilityRosterPersistence.TempDraftState) {
        tempBirthDate = draft.birthDate
        tempBirthTime = draft.birthTime
            ?? draft.birthDate
            ?? DeepAnalysisViewModel.defaultBirthTimeAnchor
        tempGender = draft.gender
        tempPlace = draft.place
    }

    // MARK: - 修改临时人(2026-09-05)

    /// 进入修改态:把 entry 现有数据回填表单(「修改」打开 sheet 前调)。
    ///
    /// 表单草稿字段被临时覆盖——关闭 sheet 后由 View 调 `resetTempDraftForm()`
    /// 还原「上次填过的」添加草稿(修改不落草稿持久化,添加习惯不被污染)。
    /// wall 钟面串按**出生地时区**反解析(与 `tempWallTimeString()` 互逆)。
    ///
    /// - Returns:回填成功 = true;失败(非 temp / 时区名无效 / 钟面串解析失败)=
    ///   false,表单字段**不动**。失败 = 自产格式被破坏属 bug,已显式记日志;
    ///   调用方必须据此**不开**修改 sheet——开着会把无关表单现值保存进该 entry
    ///   (错误显式传播:失败不止步于日志层,UI 层不得继续走成功路径)。
    @discardableResult
    func beginEditTempEntry(_ entry: RosterEntry) -> Bool {
        guard case .temp(let input, let alias, _, let place) = entry else {
            AppLogger.app.warning("op=compatibility.beginEditTempEntry skip reason=not_temp entry_id=\(entry.id, privacy: .public)")
            return false
        }
        guard let tz = TimeZone(identifier: input.timezone) else {
            AppLogger.app.error(
                "op=compatibility.beginEditTempEntry invalid_timezone tz=\(input.timezone, privacy: .public) entry_id=\(entry.id, privacy: .public)"
            )
            return false
        }
        guard let date = Self.wallClockDate(input.birthDatetime, timeZone: tz) else {
            AppLogger.app.error(
                "op=compatibility.beginEditTempEntry parse_failed birth=\(input.birthDatetime, privacy: .public) tz=\(input.timezone, privacy: .public)"
            )
            return false
        }
        tempAlias = alias ?? ""
        tempGender = input.gender
        // 拆双字段回填(2026-09-19):同一 instant 双写零拆解——日期表盘只读 Y/M/D、
        // 时刻表盘只读 H/M,提交合成时各取所需分量、秒归 0(镜像表单双行结构)。
        // 迁移代价(已知,接受):旧条目 wall 串若带非 0 秒(老默认 1990-03-15 的
        // 14:13:20 类),重存时秒归 0 → birthDatetime 变 → entry id 变 → resolvedHash
        // 作废重排一次;拆双字段模型无秒位承载,归 0 是两表单统一契约,不为旧值开口子
        tempBirthDate = date
        tempBirthTime = date
        tempPlace = place
        return true
    }

    /// wall 钟面串 → Date(出生地时区;格式与 `tempWallTimeString()` 成对,单一格式串)。
    /// 时区由调用方先解析传入,无效时区名不在本函数静默兜底(防设备时区顶替错位)。
    private static func wallClockDate(_ wallClock: String, timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = timeZone
        return formatter.date(from: wallClock)
    }

    /// 保存修改:校验 → 原位替换 roster 内该 entry。
    ///
    /// - 去重**排除自身**(只改 alias 时 id 变化,不得误撞自己;撞别人才算重复)
    /// - 勾选态随迁:改前已勾选 → 改后新 id 仍勾选(改错字不该把人请出本次合盘)
    /// - resolvedHash:输入未变(id 相同)→ 保留(S05 预查继续命中);
    ///   输入变了 → 作废置 nil(旧 hash 描述的是别人,下次 compute 走 API 重排)
    /// - 原位替换不占新名额(上限校验只拦「加」不拦「改」,与满员提示口径一致)
    /// - 不写草稿持久化(修改 ≠ 添加习惯,持久化只在 addTempToRoster)
    /// - Returns:替换后的新 entry(2026-09-29 S2:调用方据此判断「改的是当前对方
    ///   且输入变了」→ `selectPartner(new, force: true)` 强制重算)
    @discardableResult
    func updateTempEntry(_ entry: RosterEntry) throws -> RosterEntry {
        guard case .temp = entry else {
            AppLogger.app.error("op=compatibility.updateTempEntry skip reason=not_temp entry_id=\(entry.id, privacy: .public)")
            throw UserFacingError.generic(message: String(localized: "该对方不可修改"))
        }
        let (input, alias, place) = try makeTempInputFromForm()
        // id 不含 resolvedHash/place → 用同参构造算 id 即可比对「输入是否变了」
        let newId = RosterEntry.temp(input: input, alias: alias, resolvedHash: nil, place: place).id
        // keepHash 读 live roster 同 id 槽位而非入参快照:sheet 打开期间,已被 cancel 的
        // compute 在途对仍可能落地 backfillTempResolvedHash(该路径不受 isCancelled 门控),
        // 读快照会丢掉迟到的 hash(S05 预查 miss,多走一次重排);槽位不存在时为 nil,
        // 与下方 not_found 守卫的显式报错不冲突
        let liveHash = roster.first { $0.id == entry.id }?.resolvedContentHash
        let keepHash = newId == entry.id ? liveHash : nil
        let newEntry: RosterEntry = .temp(
            input: input, alias: alias, resolvedHash: keepHash, place: place
        )
        // 去重:撞 roster 内**其他** entry 才算重复(自身原位替换豁免)
        if roster.contains(where: { $0.id != entry.id && $0.id == newEntry.id }) {
            AppLogger.app.warning("op=compatibility.updateTempEntry skip reason=duplicate entry_id=\(newEntry.id, privacy: .public)")
            throw UserFacingError.generic(message: String(localized: "名单已存在相同的对方"))
        }
        guard let idx = roster.firstIndex(where: { $0.id == entry.id }) else {
            // 不静默吞:sheet 开着时 entry 被移走属并发异常,显式报给 UI
            AppLogger.app.error("op=compatibility.updateTempEntry skip reason=not_found entry_id=\(entry.id, privacy: .public)")
            throw UserFacingError.generic(message: String(localized: "该对方已不在名单中,请重新选择"))
        }
        roster[idx] = newEntry
        if selectedEntryIds.contains(entry.id) {
            selectedEntryIds.remove(entry.id)
            selectedEntryIds.insert(newEntry.id)
        }
        persistRoster()
        return newEntry
    }

    /// 移除名单一项(勾选 id 一并清理,不留悬空引用;R2 即时落盘)。
    func removeRosterEntry(_ entry: RosterEntry) {
        roster.removeAll { $0.id == entry.id }
        selectedEntryIds.remove(entry.id)
        persistRoster()
    }

    /// 临时表单校验(不静默吞)。
    /// - 出生日期未选 / 性别未选 / 出生时间未来 / 未选地点 / 自定义经度越界 → 抛 UserFacingError
    ///   (2026-09-19 去默认值:日期/性别不再预填,未选必选;错误优先级 日期>性别>未来>地点)
    private func validateTempForm() throws {
        guard tempBirthDate != nil else {
            AppLogger.app.warning("op=compatibility.validateTemp skip reason=b_birth_empty")
            throw UserFacingError.generic(message: L10n.BirthForm.errorDateRequired)
        }
        guard tempGender != nil else {
            AppLogger.app.warning("op=compatibility.validateTemp skip reason=b_gender_empty")
            throw UserFacingError.generic(message: L10n.BirthForm.errorGenderRequired)
        }
        if try combinedTempBirthDate() > Date() {
            AppLogger.app.warning("op=compatibility.validateTemp skip reason=b_birth_future")
            throw UserFacingError.generic(message: String(localized: "B 盘出生时间不能晚于当下"))
        }
        if tempPlace == nil {
            AppLogger.app.warning("op=compatibility.validateTemp skip reason=b_place_empty")
            throw UserFacingError.generic(message: String(localized: "请选择出生城市,或在搜索页底部自定义地点"))
        }
        if let tempPlace, !tempPlace.isCustomLongitudeValid {
            AppLogger.app.warning("op=compatibility.validateTemp skip reason=b_longitude_out_of_range")
            throw UserFacingError.generic(message: String(localized: "B 盘经度需在 -180 到 180 之间"))
        }
    }

    // MARK: - 合盘触发(决策 D3 串行 / S03 对级隔离 / D13 零勾选拦截)

    /// 触发合盘:校验勾选 → 串行调 orchestrator.runDeterministic → **唯一一对算成直达
    /// detail**(2026-09-07 单选改造);失败 / 时辰拦截 → 单卡 .list 兜底
    /// (S03 重试 / S10 补时辰 CTA 机制保留)。
    ///
    /// 2026-09-03:只消费 `selectedRosterEntries`(勾选子集)——名单成员未勾选不排盘
    /// (添加与勾选解耦后,零勾选 = D13 拦截,与空名单同文案)。
    /// 循环体保持 N 元泛化(直塞多勾只出测试),正常路径单选恒 N=1。
    /// 切 tab / clearDetailKeepRoster → computeTask cancel(决策 D13)。
    func compute() {
        let contextValue = self.context
        let rosterCount = self.roster.count
        let selectedEntries = self.selectedRosterEntries
        let archivedCount = self.archivedCharts.count
        AppLogger.app.info("compatVM.compute.start roster_count=\(rosterCount, privacy: .public) selected_count=\(selectedEntries.count, privacy: .public) context=\(contextValue, privacy: .public) archivedCount=\(archivedCount)")

        guard !archivedCharts.isEmpty else {
            AppLogger.app.warning("compatVM.compute.skip reason=empty_archive")
            state = .empty
            return
        }
        guard selectedChartAIndex < archivedCharts.count else {
            AppLogger.app.warning("compatVM.compute.skip reason=a_index_out_of_bounds selectedAIndex=\(self.selectedChartAIndex)")
            state = .failed(.generic(message: String(localized: "A 盘选择越界,请重新选择")))
            return
        }
        // 决策 D13:零勾选拦截(2026-09-03 起名单非空但未勾选同样拦截)
        guard !selectedEntries.isEmpty else {
            AppLogger.app.warning("compatVM.compute.skip reason=empty_selection roster_count=\(rosterCount, privacy: .public)")
            state = .failed(.generic(message: String(localized: "请先点选一位对方")))
            return
        }

        computeTask?.cancel()
        let total = selectedEntries.count
        state = .computing(completed: 0, total: total)

        // 捕获快照避免 Task 内被并发修改
        let chartA = archivedCharts[selectedChartAIndex]
        let rosterSnapshot = selectedEntries

        computeTask = Task { [weak self] in
            guard let self else { return }

            // 预解 A payload(每对复用,避免循环内重复 decode)
            let payloadA: ChartPayloadDTO
            let aHourGate: HourUnknownGate
            // 2026-10-07 P0 收口:A 盘 per-chart token(老快照 nil → 后端 403 显式暴露)
            let aToken: String?
            do {
                let baziA = try self.chartStore.decodeResponse(from: chartA.snapshot)
                // 合盘路径必须带 luckPillars(「无运」修复,见 compatibilityPayload 注释)
                payloadA = ChartPayloadDTO.compatibilityPayload(from: baziA)
                // S07 拦截判据(单一事实源 = A 盘存档 payload,不重复推断)
                aHourGate = baziA.hourUnknownGate
                aToken = baziA.payloadContextToken
            } catch {
                if !Task.isCancelled {
                    self.state = .failed(UserFacingError.from(error, stage: .compatibilityDeterministic))
                }
                return
            }

            var newSummaries: [PairSummary] = []
            newSummaries.reserveCapacity(rosterSnapshot.count)

            for (idx, entry) in rosterSnapshot.enumerated() {
                if Task.isCancelled { return }
                do {
                    let summary = try await self.computePair(
                        entry: entry,
                        chartA: chartA,
                        payloadA: payloadA,
                        aHourGate: aHourGate,
                        contextValue: contextValue,
                        tokenA: aToken
                    )
                    newSummaries.append(summary)
                } catch is CancellationError {
                    return
                } catch {
                    // S03(决策 D10):对级错误隔离——单对失败不拖垮列表,
                    // 该对 PairSummary 置 .failed + 单对重试,循环继续跑剩余对。
                    if !Task.isCancelled {
                        AppLogger.app.error(
                            "op=compatibility.compute_pair_failed idx=\(idx) entry_id=\(entry.id, privacy: .public) error=\(String(describing: error), privacy: .public)"
                        )
                        newSummaries.append(self.makeFailedSummary(entry: entry, error: error))
                    }
                }
                if !Task.isCancelled {
                    self.state = .computing(completed: idx + 1, total: total)
                }
            }

            if !Task.isCancelled {
                let successCount = newSummaries.filter(\.isComputed).count
                AppLogger.app.info("compatVM.compute.ok total=\(newSummaries.count, privacy: .public) success=\(successCount, privacy: .public)")
                self.summaries = newSummaries
                // R2(2026-09-30):持久化单一出口——resolvedHash 已在各对
                // backfillTempResolvedHash 落盘,这里再同步一次 A hash 与最终选中
                self.persistRoster()
                // 2026-09-07 单选直达:唯一一对且算成 → 直接进 detail;
                // 失败 / 时辰拦截 → 单卡 .list 兜底(重试 / 补时辰 CTA 保留)
                if newSummaries.count == 1, let only = newSummaries.first, only.isComputed {
                    self.openDetail(only)
                } else {
                    self.state = .list
                }
            }
        }
    }

    // MARK: - S06 跨启动持久化与恢复(R1-R5 修订,2026-09-30)

    /// 名单持久化单一出口(R2):读当前 `roster` + 选中 + A 盘,写 `compat.rosterV2`。
    /// 所有改名单或选中的地方调它,不在各处直接拼 UserDefaults。
    /// 名单完整持久化(R1):临时对方的 PersonBInput / 称呼 / 出生地 / resolvedHash
    /// 全在 entries 里;`selectedEntryIds.first` 落 `selectedEntryID`(R3)。
    /// 合盘失败不影响名单——本函数不依赖 compute() 成功。
    ///
    /// 防覆盖守卫(2026-09-30 review 修复):本 VM 既没跑过恢复、本地又已有非空名单
    /// (或未迁移的老 key)→ 拒写 + error 日志。典型路径:启动读存档失败 → 错误页
    /// 重试只 reload 存档没恢复名单 → 内存名单为空 → 用户加一个人就会把本地整份
    /// 名单覆盖成一人。恢复过(`restoreRosterStateIfAvailable`)或本地本来就空时
    /// 首写成功后,本 VM 即接管名单所有权,此后照常写。
    private func persistRoster() {
        if !ownsPersistedRoster {
            guard !CompatibilityRosterPersistence.hasPersistedRoster() else {
                AppLogger.persistence.error(
                    "op=compatibility.persistRoster refused reason=not_restored_but_persisted_roster_exists memory_roster_count=\(self.roster.count, privacy: .public)"
                )
                return
            }
            ownsPersistedRoster = true
        }
        CompatibilityRosterPersistence.saveV2(
            personAHash: currentPersonAHash ?? "",
            context: context,
            roster: .init(
                entries: roster.map(\.persisted),
                selectedEntryID: selectedEntryIds.first
            )
        )
    }

    /// S06:跨启动恢复名单 + A(决策 D5/D8/D11/D13;R1-R5 修订 2026-09-30)。
    /// 调用时机:`loadArchivedCharts()` 完成后,0 存档外(进 .configuring 态时)。
    ///
    /// 流程:
    /// 1. 读 `compat.rosterV2`;不存在 → R5 从老 key `compat.roster` 迁移(读后删,
    ///    一次性;迁移态无选中记录)
    /// 2. A hash 失效 fallback 最新 link(D13)
    /// 3. 逐条校验:`.archived` 快照查不到 → 剔除;`.temp` 恒保留(有完整输入),
    ///    resolvedHash 指向的快照查不到 → 置 nil(下次合盘重新请求);
    ///    超 rosterMax → 截断(理论不可达,记 error)
    /// 4. 选中恢复(R3):`selectedEntryID` 在名单内 → 恢复勾选;它有缓存
    ///    (canonicalKey 直查)→ 零请求直达 detail;无缓存 → 留 .configuring
    ///    (结果壳 P6 有选中态:头部显示该人 + 内容区「重新合盘」入口,不自动发请求)。
    ///    不再用 createdAt 猜「上次那位」——只在 R5 迁移时兜底用一次
    /// 5. 恢复全程**不写持久化**(persistRoster 是显式调用制,本函数对 roster /
    ///    selectedEntryIds 的赋值不触发写入,半成品不会被写回);最后统一写一次,
    ///    把清理掉的无效项 / 迁移结果 / 选中落盘
    func restoreRosterStateIfAvailable() {
        guard !archivedCharts.isEmpty else { return }  // 0 存档走 .empty,不恢复

        // 1. A hash 失效则 fallback 最新 link(D13)
        let persistedAHash = CompatibilityRosterPersistence.loadPersonAHash()
        if let aHash = persistedAHash,
           let idx = archivedCharts.firstIndex(where: { $0.snapshotHash == aHash }) {
            selectedChartAIndex = idx
        } else {
            // 持久化 A 失效或未存 → fallback 最新 link(archivedCharts 已 createdAt DESC)
            if persistedAHash != nil {
                AppLogger.app.warning(
                    "op=compatibility.restore.a_hash_invalid fallback to latest link a_hash=\(persistedAHash ?? "nil", privacy: .public)"
                )
            }
            selectedChartAIndex = 0
        }

        // 2. V2 读 / R5 老数据迁移
        var persisted = CompatibilityRosterPersistence.loadV2()
        var migratedFromLegacy = false
        if persisted == nil,
           let legacyHashes = CompatibilityRosterPersistence.loadLegacyRosterHashesForMigration() {
            persisted = PersistedRoster(
                entries: legacyHashes.map { .archived(snapshotHash: $0) },
                selectedEntryID: nil
            )
            migratedFromLegacy = true
        }

        // 3. 逐条校验(错误显式传播:快照真缺失才剔除 / resolvedHash 失效置 nil;
        //    store 查询 throw = 瞬态错误,记日志后保留成员,不借剔除掩盖失败)
        var entries: [RosterEntry] = []
        if let persisted {
            for persistedEntry in persisted.entries {
                switch persistedEntry {
                case .archived(let hash):
                    do {
                        guard try chartStore.get(contentHash: hash) != nil else {
                            AppLogger.app.warning(
                                "op=compatibility.restore.entry_snapshot_missing hash=\(hash, privacy: .public)"
                            )
                            continue
                        }
                        entries.append(.archived(snapshotHash: hash))
                    } catch {
                        // 查询失败 ≠ 缺失:保留成员 + 显式记日志(与 .temp 的
                        // resolvedHash 校验同语义)——瞬态 store 错误不得借剔除
                        // 掩盖,更不能经末次 persistRoster 落盘成永久驱逐;
                        // 真缺失(上面 nil 分支)才剔除
                        AppLogger.persistence.error(
                            "op=compatibility.restore.entry_check_failed hash=\(hash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                        )
                        entries.append(.archived(snapshotHash: hash))
                    }
                case .temp(let input, let alias, let resolvedHash, let place):
                    // 恒保留(有完整输入随时能重排);resolvedHash 快照查不到 → 置 nil
                    var effectiveResolved = resolvedHash
                    if let resolvedHash {
                        do {
                            if try chartStore.get(contentHash: resolvedHash) == nil {
                                AppLogger.app.warning(
                                    "op=compatibility.restore.temp_resolved_missing alias=\(alias ?? "nil", privacy: .public) hash=\(resolvedHash, privacy: .public)"
                                )
                                effectiveResolved = nil
                            }
                        } catch {
                            // 查询失败 ≠ 缺失:显式记日志,hash 保留(展示层有降级,
                            // compute 路径会再抛真错误)
                            AppLogger.persistence.error(
                                "op=compatibility.restore.temp_resolved_check_failed hash=\(resolvedHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                            )
                        }
                    }
                    entries.append(.temp(input: input, alias: alias, resolvedHash: effectiveResolved, place: place))
                }
            }
            if entries.count > Self.rosterMax {
                AppLogger.app.error(
                    "op=compatibility.restore.roster_overflow count=\(entries.count, privacy: .public) truncating to \(Self.rosterMax, privacy: .public)"
                )
                entries = Array(entries.prefix(Self.rosterMax))
            }
        }

        roster = entries

        // 4. 选中恢复(R3):selectedEntryID 不在名单 → 清空(截断/剔除可能带走)
        var selectedID = persisted?.selectedEntryID
        if let sid = selectedID, !roster.contains(where: { $0.id == sid }) {
            AppLogger.app.warning(
                "op=compatibility.restore.selected_missing id=\(sid, privacy: .public)"
            )
            selectedID = nil
        }

        // R5 迁移兜底:老数据无选中 → 按 createdAt 最新定一次(此后不再猜)
        if migratedFromLegacy, selectedID == nil, !roster.isEmpty {
            selectedID = legacyMigrationSelectedEntryID()
        }
        selectedEntryIds = selectedID.map { [$0] } ?? []

        AppLogger.app.info(
            "op=compatibility.restore.ok a_hash=\(self.currentPersonAHash ?? "nil", privacy: .public) context=\(self.context, privacy: .public) roster_count=\(self.roster.count, privacy: .public) selected=\(selectedID ?? "nil", privacy: .public) migrated=\(migratedFromLegacy, privacy: .public)"
        )

        // 5. 选中者有缓存 → 零请求直达 detail(R3;传名单里的真实 entry,
        //    临时对方的称呼由 rebuildSummaryFromCache 的 alias 分支保住)
        restoreDetailForSelectionIfCached()

        // 恢复完成,统一落盘一次(清理掉的无效项 / 迁移结果 / 选中);
        // 恢复即接管名单所有权(persistRoster 防覆盖守卫放行)
        ownsPersistedRoster = true
        persistRoster()
    }

    /// R3:选中者的 canonicalKey 命中缓存 → 重建 summary 直达 detail;
    /// 未命中 / decode 失败 / 查询失败 → 显式记日志,留在 .configuring
    /// (结果壳 P6 有选中态,内容区给「重新合盘」入口,不自动发请求)。
    private func restoreDetailForSelectionIfCached() {
        guard let entry = selectedRosterEntries.first,
              let bHash = entry.resolvedContentHash,
              let aHash = currentPersonAHash else { return }
        let canonicalKey = CompatibilitySnapshotStore.canonicalKey(
            aHash: aHash, bHash: bHash, context: context
        )
        do {
            guard let snapshot = try compatibilityStore.get(compatibilityHash: canonicalKey) else {
                AppLogger.app.info(
                    "op=compatibility.restore.no_cache id=\(entry.id, privacy: .public) canonicalKey=\(canonicalKey, privacy: .public)"
                )
                return
            }
            let summary = try rebuildSummaryFromCache(entry: entry, bHash: bHash, snapshot: snapshot)
            summaries = [summary]
            openDetail(summary)
            AppLogger.app.info(
                "op=compatibility.restore.detail_ok hash=\(snapshot.compatibilityHash, privacy: .public) zero_api=true"
            )
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.restore.detail_failed id=\(entry.id, privacy: .public) canonicalKey=\(canonicalKey, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            // 不静默吞:留在配置态(名单与选中已恢复),内容区提供「重新合盘」
        }
    }

    /// R5 迁移兜底:老 key 数据无选中记录 → 名单内 createdAt 最新的快照定「上次那位」。
    /// 仅迁移时调一次;之后「当前选中」由 selectedEntryID 显式承载,不再猜。
    /// list 查询失败 / 无快照 → nil(不预勾,留在配置态由用户自点)。
    private func legacyMigrationSelectedEntryID() -> String? {
        guard let aHash = currentPersonAHash else { return nil }
        do {
            let snapshots = try compatibilityStore.list(personAHash: aHash, context: context)
            // 名单过滤(D5 核心:删掉的对方不从快照库「复活」)
            let rosterHashes = Set(roster.compactMap { $0.resolvedContentHash })
            let filtered = snapshots.filter { rosterHashes.contains($0.personBHash) }
            guard let latest = filtered.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
            return roster.first { $0.resolvedContentHash == latest.personBHash }?.id
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.restore.legacy_list_failed a_hash=\(aHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - AddHour 后内存 hash remap(S10;结果壳 P1 配套)

    /// 补时辰重算换新盘(old → new content_hash)后,内存侧 roster / 勾选 id 原地
    /// remap(持久化侧已由 `CompatibilityRosterPersistence.remapHash` 处理)。
    /// `.configuring` 态走 `restoreRosterStateIfAvailable` 从持久化重建,不经此路;
    /// 结果壳(P1)下当前对强制重算(`selectPartner(force:)`)依赖内存换血——
    /// 勾选 id 内嵌 hash("archived:<hash>"),不换会算旧盘/丢勾选。
    func applyHashRemap(from oldHash: String, to newHash: String) {
        let oldID = RosterEntry.archived(snapshotHash: oldHash).id
        let newID = RosterEntry.archived(snapshotHash: newHash).id
        roster = roster.map { entry in
            guard case .archived(let h) = entry, h == oldHash else { return entry }
            return .archived(snapshotHash: newHash)
        }
        selectedEntryIds = Set(selectedEntryIds.map { $0 == oldID ? newID : $0 })
        persistRoster()
        AppLogger.app.info(
            "op=compatibility.applyHashRemap old=\(oldHash, privacy: .public) new=\(newHash, privacy: .public) roster_count=\(self.roster.count, privacy: .public)"
        )
    }

    /// 补时辰 dismiss 后的续接选人(P1-1 修复,2026-09-30):重算**补时辰的那
    /// 个人**,而非无条件当前对方。此前换人 sheet 点无时辰行 → 补完时辰,重算
    /// 的是旧当前对方(force 绕缓存多耗一次配额),补时辰的人从头到尾没被选中。
    ///
    /// - 目标 = 他人盘且与 remap 吻合 → `selectPartner(.archived(new), force:)`
    ///   续接「点行 = 换人」语义:用户点无时辰行时未竟的换人,在此补完(该人
    ///   若已在新盘池中,守卫[满员等]由 selectPartner 显式记日志,不在此兜底)
    /// - 目标 = 自己盘 → 名单/勾选未变,对当前对方强制重算(旧行为;无当前
    ///   对方不自动选人)
    /// - 目标缺失 / 与 remap 不符(状态错乱)→ 显式记日志 + 回落旧行为
    ///
    /// 调用前须已完成 `applyHashRemap`(结果壳态)或 `restoreRosterStateIfAvailable`
    /// (配置态,持久化侧已被 AddHour submit 的 remapHash 换新)。
    func continueAfterAddHourRemap(target: AddHourTarget?, remap oldToNew: (old: String, new: String)) {
        switch target {
        case .partnerChart(let hash) where hash == oldToNew.old:
            selectPartner(.archived(snapshotHash: oldToNew.new), force: true)
        case .selfChart, nil:
            if let current = selectedRosterEntries.first {
                selectPartner(current, force: true)
            } else {
                AppLogger.app.info(
                    "op=compatibility.continueAfterAddHour skip_recompute reason=no_current_partner"
                )
            }
        case .partnerChart:
            AppLogger.app.error(
                "op=compatibility.continueAfterAddHour target_mismatch remap_old=\(oldToNew.old, privacy: .public)"
            )
            if let current = selectedRosterEntries.first {
                selectPartner(current, force: true)
            }
        }
    }

    // MARK: - 单对重试(S03 决策 D10)

    /// 单对重试:针对 `.failed` 状态的 PairSummary 单发一次确定性合盘。
    ///
    /// 红线(S03):
    /// - **不触碰付费 / 次数 / 后端**——只调 deterministic 接口(免费部分)。
    /// - **不静默吞**——重试失败再次置 `.failed`(用新错误摘要)。
    /// - **并发互斥**——重试期间该对 id 进 `retryingIds`,UI disable 按钮避免双请求。
    func retryPair(summary: PairSummary) {
        guard case .list = state else {
            AppLogger.app.warning("op=compatibility.retryPair skip reason=not_list state=\(String(describing: self.state), privacy: .public)")
            return
        }
        guard case .failed = summary.status else {
            AppLogger.app.warning("op=compatibility.retryPair skip reason=not_failed summary_id=\(summary.id, privacy: .public)")
            return
        }
        guard !retryingIds.contains(summary.id) else {
            AppLogger.app.warning("op=compatibility.retryPair skip reason=already_retrying summary_id=\(summary.id, privacy: .public)")
            return
        }
        guard let chartA = archivedCharts[safe: selectedChartAIndex] else {
            AppLogger.app.warning("op=compatibility.retryPair skip reason=a_index_out_of_bounds")
            return
        }

        retryingIds.insert(summary.id)
        let entry = summary.entry
        let contextValue = context
        let summaryId = summary.id

        Task { [weak self] in
            guard let self else { return }
            // VM @MainActor + Task 继承 actor → defer 同步执行已在 MainActor,无需嵌套 Task 派发
            defer {
                self.retryingIds.remove(summaryId)
            }
            do {
                let baziA = try self.chartStore.decodeResponse(from: chartA.snapshot)
                let payloadA = ChartPayloadDTO.compatibilityPayload(from: baziA)
                let newSummary = try await self.computePair(
                    entry: entry,
                    chartA: chartA,
                    payloadA: payloadA,
                    aHourGate: baziA.hourUnknownGate,
                    contextValue: contextValue,
                    tokenA: baziA.payloadContextToken
                )
                if !Task.isCancelled {
                    AppLogger.app.info("op=compatibility.retryPair.ok summary_id=\(summaryId, privacy: .public)")
                    self.replaceSummary(id: summaryId, with: newSummary)
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    AppLogger.app.error(
                        "op=compatibility.retryPair.failed summary_id=\(summaryId, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    // 不静默吞:重试仍失败 → 替换为新 failed summary(用新错误摘要,用户可继续重试)
                    let newFailed = self.makeFailedSummary(entry: entry, error: error)
                    self.replaceSummary(id: summaryId, with: newFailed)
                }
            }
        }
    }

    /// 列表内替换某对 summary(重试成功 / 失败后用)。
    private func replaceSummary(id: String, with newSummary: PairSummary) {
        guard let idx = summaries.firstIndex(where: { $0.id == id }) else {
            AppLogger.app.warning("op=compatibility.replaceSummary skip reason=not_found id=\(id, privacy: .public)")
            return
        }
        summaries[idx] = newSummary
    }

    /// 失败 PairSummary 构造(占位字段 + .failed(UserFacingError))。
    /// 失败卡片不展示 birthDate / fiveElements / dayMasterRelation(status 决定 UI)。
    private func makeFailedSummary(entry: RosterEntry, error: Error) -> PairSummary {
        let displayName: String
        switch entry {
        case .archived(let bHash):
            displayName = archivedCharts.first { $0.snapshotHash == bHash }?.alias ?? String(localized: "对方")
        case .temp(let input, let alias, _, _):
            if let alias, !alias.isEmpty {
                displayName = alias
            } else {
                // S04 兜底名:birthDatetime 已是裸钟面字符串,直接读(出生地钟面)
                displayName = L10n.CompatibilityPartner.fallbackName(input.wallClockDisplay)
            }
        }
        let userError = UserFacingError.from(error, stage: .compatibilityDeterministic)
        return PairSummary(
            id: "failed:\(entry.id)",
            entry: entry,
            personBHash: "",
            displayName: displayName,
            birthDate: nil,
            dayMaster: "—",
            fiveElements: "",
            dayMasterRelation: "",
            compatibilityHash: "",
            isInterpreted: false,
            status: .failed(userError)
        )
    }

    /// S07 时辰未知对级拦截 PairSummary 构造(占位字段 + .hourUnknownBlocked)。
    ///
    /// personBHash 语义:存档对方保留其 snapshot hash(roster 跨启动持久化需要,
    /// 该人仍在名单,补时辰后按新盘重算);临时对方无 hash(请求未发起,置空串)。
    private func makeHourUnknownBlockedSummary(entry: RosterEntry) -> PairSummary {
        let displayName: String
        let personBHash: String
        switch entry {
        case .archived(let bHash):
            displayName = archivedCharts.first { $0.snapshotHash == bHash }?.alias ?? String(localized: "对方")
            personBHash = bHash
        case .temp(let input, let alias, _, _):
            if let alias, !alias.isEmpty {
                displayName = alias
            } else {
                displayName = L10n.CompatibilityPartner.fallbackName(input.wallClockDisplay)
            }
            personBHash = ""
        }
        return PairSummary(
            id: "hour_unknown:\(entry.id)",
            entry: entry,
            personBHash: personBHash,
            displayName: displayName,
            birthDate: nil,
            dayMaster: "—",
            fiveElements: "",
            dayMasterRelation: "",
            compatibilityHash: "",
            isInterpreted: false,
            status: .hourUnknownBlocked
        )
    }

    /// S04:回填临时人 resolvedHash 到 roster 内对应 entry(为 S05 增量预查 / S06 持久化铺路)。
    /// 用 input + alias 定位(id 不变 → ForEach 不重建)。
    private func backfillTempResolvedHash(input: PersonBInput, alias: String?, resolvedHash: String) {
        guard let idx = roster.firstIndex(where: { entry in
            if case .temp(let existingInput, let existingAlias, _, _) = entry,
               existingInput.birthDatetime == input.birthDatetime,
               existingInput.timezone == input.timezone,
               existingInput.gender == input.gender,
               existingInput.longitude == input.longitude,
               (existingAlias ?? "") == (alias ?? "") {
                return true
            }
            return false
        }) else {
            AppLogger.app.warning("op=compatibility.backfillTempResolvedHash not_found alias=\(alias ?? "nil", privacy: .public)")
            return
        }
        // 2026-09-05:place 原样带过(反推无据,见 RosterEntry.place 注释)
        if case .temp(_, _, _, let existingPlace) = roster[idx] {
            roster[idx] = .temp(input: input, alias: alias, resolvedHash: resolvedHash, place: existingPlace)
        }
        persistRoster()
        AppLogger.app.info(
            "op=compatibility.backfillTempResolvedHash ok idx=\(idx) resolved_hash=\(resolvedHash, privacy: .public)"
        )
    }

    /// S04 兜底名「对方+出生日期」:真太阳时按**出生城市时区**格式化
    /// (birthSolarTime 现存真太阳时,设备时区渲染会在西部城市错一天)。
    private static func fallbackDateString(_ date: Date, timezoneName: String?) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timezoneName.flatMap(TimeZone.init(identifier:)) ?? .current
        return f.string(from: date)
    }

    /// S05:命中本地快照时用其重建 PairSummary(无 API 调用,内容寻址的自然收益)。
    /// 不静默吞:decode 失败 / B ChartSnapshot 缺失 → throw 走该对失败路径(S03 隔离)。
    private func rebuildSummaryFromCache(
        entry: RosterEntry,
        bHash: String,
        snapshot: CompatibilitySnapshot
    ) throws -> PairSummary {
        let qualitative = try compatibilityStore.decodeQualitative(from: snapshot)

        // 从 chartStore 取 B ChartSnapshot(算 birthSolarTime / dayMaster / displayName)
        guard let bChartSnapshot = try chartStore.get(contentHash: bHash) else {
            AppLogger.persistence.error(
                "op=compatibility.rebuildSummaryFromCache missing_b_chart b_hash=\(bHash, privacy: .public)"
            )
            throw UserFacingError.generic(message: String(localized: "对方命盘快照缺失,请重新选择"))
        }
        let baziB = try chartStore.decodeResponse(from: bChartSnapshot)
        // S05:日柱歧义盘日主留白「—」(不猜;S11 roster 不可合盘标记拦截上游)
        let dayMaster = baziB.pillars.day?.gan ?? "—"

        // displayName(与 computePair API 路径一致)
        // S06:archived 在 archivedCharts 找不到时(跨启动恢复的临时人持久化为 .archived
        // 风格 hash)→ fallback 到兜底名「对方+出生日期」
        let displayName: String
        switch entry {
        case .archived:
            if let chart = archivedCharts.first(where: { $0.snapshotHash == bHash }) {
                displayName = chart.alias
            } else {
                let dateStr = Self.fallbackDateString(bChartSnapshot.birthSolarTime,
                                                      timezoneName: bChartSnapshot.cityTimezone)
                displayName = L10n.CompatibilityPartner.fallbackName(dateStr)
            }
        case .temp(_, let alias, _, _):
            if let alias, !alias.isEmpty {
                displayName = alias
            } else {
                let dateStr = Self.fallbackDateString(bChartSnapshot.birthSolarTime,
                                                      timezoneName: bChartSnapshot.cityTimezone)
                displayName = L10n.CompatibilityPartner.fallbackName(dateStr)
            }
        }

        return PairSummary(
            id: snapshot.compatibilityHash,
            entry: entry,
            personBHash: bHash,
            displayName: displayName,
            birthDate: bChartSnapshot.birthSolarTime,
            dayMaster: dayMaster,
            fiveElements: qualitative.fiveElements,
            dayMasterRelation: qualitative.dayMasterRelation,
            compatibilityHash: snapshot.compatibilityHash,
            isInterpreted: snapshot.interpretation != nil,
            status: .computed
        )
    }

    /// 计算单对并构造 PairSummary。
    /// - S05 预查:本地 canonicalKey 命中 → 直接重建 PairSummary,不调 API
    /// - 未命中 / 临时人首次无 resolvedHash:走现状 API 流程
    /// - 模式 A:存档对方 → 直接解 B snapshot
    /// - 模式 B:临时对方 → 后端隐式落地后取回 B snapshot
    /// - S07 拦截:A 盘或存档 B 盘任一方无时辰(payload 判据,含日柱歧义)→
    ///   整对拦(免费亦拦),不发注定 422 的请求,直接产 `.hourUnknownBlocked` 卡片。
    ///   模式 B 临时人不查(PersonBInput 恒带完整钟面,无时辰语义不存在)。
    private func computePair(
        entry: RosterEntry,
        chartA: ArchivedChart,
        payloadA: ChartPayloadDTO,
        aHourGate: HourUnknownGate,
        contextValue: String,
        tokenA: String? = nil
    ) async throws -> PairSummary {
        let aHash = chartA.snapshotHash

        // S07:A 盘无时辰 → 全部对拦(自己无时辰,该盘根本无法参与合盘契约)
        if aHourGate != .hourKnown {
            AppLogger.app.warning(
                "op=compatibility.computePair hour_unknown_blocked side=a a_hash=\(aHash, privacy: .public) entry_id=\(entry.id, privacy: .public)"
            )
            return makeHourUnknownBlockedSummary(entry: entry)
        }

        // S05 增量预查(决策 D7):有 resolvedHash 时本地查 canonicalKey 命中跳过 API。
        // 规则版本门(2026-10-07):快照按旧引擎规则算出(含老快照 nil)→ 不得
        // 复用,落穿 API 重算(upsert 覆盖自愈)——合冲判定序变更后老标签
        // 不得与新刑害点名同屏自相矛盾
        var staleSnapshot: CompatibilitySnapshot?
        if let bHash = entry.resolvedContentHash {
            let canonicalKey = CompatibilitySnapshotStore.canonicalKey(
                aHash: aHash, bHash: bHash, context: contextValue
            )
            do {
                if let existing = try compatibilityStore.get(compatibilityHash: canonicalKey) {
                    if CompatibilitySnapshotStore.isFreshEngineRule(existing) {
                        AppLogger.app.info(
                            "op=compatibility.computePair.cache_hit canonicalKey=\(canonicalKey, privacy: .public) entry_id=\(entry.id, privacy: .public)"
                        )
                        return try rebuildSummaryFromCache(
                            entry: entry,
                            bHash: bHash,
                            snapshot: existing
                        )
                    }
                    // 快照按旧引擎规则算出(含老快照 nil)→ 落穿 API 重算
                    staleSnapshot = existing
                    AppLogger.app.info(
                        "op=compatibility.computePair.rule_version_stale canonicalKey=\(canonicalKey, privacy: .public) snapshot=\(existing.engineRuleVersion.map(String.init) ?? "nil", privacy: .public) expected=\(CompatibilitySnapshotStore.expectedEngineRuleVersion, privacy: .public) — 落穿 API 重算"
                    )
                }
            } catch {
                // 不静默吞(S05 红线):本地查询失败 → 显式 throw 走该对失败路径(S03 隔离)
                AppLogger.persistence.error(
                    "op=compatibility.computePair.prefetch_failed canonicalKey=\(canonicalKey, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                throw error
            }
        }

        let request: CompatibilityRequest
        var bSnapshotForUI: ChartSnapshot?

        switch entry {
        case .archived(let bHash):
            guard let bChart = archivedCharts.first(where: { $0.snapshotHash == bHash }) else {
                throw UserFacingError.generic(message: String(localized: "B 盘存档已不存在,请重新选择"))
            }
            let baziB = try chartStore.decodeResponse(from: bChart.snapshot)
            // S07:存档 B 盘无时辰(payload 判据,含日柱歧义)→ 该对拦
            // (后端 four_pillars 必含 hour,发了必 422;免费亦拦,见 computePair 文档)
            if baziB.hourUnknownGate != .hourKnown {
                AppLogger.app.warning(
                    "op=compatibility.computePair hour_unknown_blocked side=b b_hash=\(bHash, privacy: .public) entry_id=\(entry.id, privacy: .public)"
                )
                return makeHourUnknownBlockedSummary(entry: entry)
            }
            let payloadB = ChartPayloadDTO.compatibilityPayload(from: baziB)
            request = CompatibilityRequest(
                personAHash: aHash,
                personBHash: bChart.snapshotHash,
                chartPayloadA: payloadA,
                chartPayloadB: payloadB,
                context: contextValue,
                // 2026-10-07 P0 收口:per-chart token,后端 token↔hash↔payload 对账
                contextTokenA: tokenA ?? "",
                contextTokenB: baziB.payloadContextToken ?? ""
            )
            bSnapshotForUI = bChart.snapshot

        case .temp(let input, _, _, _):
            request = CompatibilityRequest(
                personAHash: aHash,
                personB: input,
                chartPayloadA: payloadA,
                context: contextValue,
                contextTokenA: tokenA ?? ""
            )
            bSnapshotForUI = nil
        }

        let result: CompatibilityOrchestrator.DeterministicResult
        do {
            result = try await orchestrator.runDeterministic(
                request: request,
                personAHash: chartA.snapshotHash
            )
        } catch {
            // 规则重算失败回落旧快照(2026-10-07 review;同轮再修收窄):stale
            // 快照本地仍有完整旧标签——**离线/超时类**(isOfflineOrTimeout,
            // 单一事实源 UserFacingError.isOfflineOrTimeout)回落显示旧结果
            // (openDetail 后台重算 + 下轮 compute 预查联网自愈),优于整对
            // 失败卡。4xx/5xx/解码失败是后端真错误,回落旧标签 = 拿旧值掩盖
            // 失败(CLAUDE.md 错误显式传播禁止),必须显式失败卡。
            // 取消不回落(旧对取消须作废)。
            if Task.isCancelled { throw error }
            guard let existing = staleSnapshot,
                  let staleBHash = entry.resolvedContentHash,
                  UserFacingError.isOfflineOrTimeout(error) else {
                throw error
            }
            AppLogger.app.error(
                "op=compatibility.computePair.rule_refresh_failed_fallback b_hash=\(staleBHash, privacy: .public) error=\(String(describing: error), privacy: .public) — 离线/超时,回落旧规则快照(联网后自愈重算)"
            )
            return try rebuildSummaryFromCache(
                entry: entry, bHash: staleBHash, snapshot: existing
            )
        }

        // 模式 B:B snapshot 是新隐式落地的,从 chartStore 取回
        if bSnapshotForUI == nil {
            bSnapshotForUI = try chartStore.get(contentHash: result.personBHash)
            // 不静默吞:刚隐式落地的 B snapshot 取不回说明持久化失败,
            // 该对无法构造卡片,显式抛错让上层进入对级失败(S01 走整体 failed;S03 隔离)。
            if bSnapshotForUI == nil {
                throw UserFacingError.generic(message: String(localized: "B 盘隐式落地后取回失败,请重试"))
            }
        }
        guard let bSnapshot = bSnapshotForUI else {
            throw UserFacingError.generic(message: String(localized: "B 盘快照缺失"))
        }

        let baziB = try chartStore.decodeResponse(from: bSnapshot)
        // S05:日柱歧义盘日主留白「—」(不猜;S11 roster 不可合盘标记拦截上游)
        let dayMaster = baziB.pillars.day?.gan ?? "—"

        // 显示名(存档 = alias;临时 = alias 或「对方+出生日期」—— S04 兜底名策略)
        let displayName: String
        switch entry {
        case .archived(let bHash):
            displayName = archivedCharts.first { $0.snapshotHash == bHash }?.alias ?? String(localized: "对方")
        case .temp(_, let alias, _, _):
            if let alias, !alias.isEmpty {
                displayName = alias
            } else {
                // S04 兜底名:「对方+出生日期」(按出生城市时区格式化真太阳时)
                let dateStr = Self.fallbackDateString(bSnapshot.birthSolarTime,
                                                      timezoneName: bSnapshot.cityTimezone)
                displayName = L10n.CompatibilityPartner.fallbackName(dateStr)
            }
        }

        // S04:临时人首次计算后回填 resolvedHash 到 roster(为 S05 增量预查 / S06 持久化铺路)
        if case .temp(let input, let alias, _, _) = entry {
            backfillTempResolvedHash(
                input: input,
                alias: alias,
                resolvedHash: result.personBHash
            )
        }

        // 已解读标记:查 CompatibilitySnapshot.interpretation
        // store.get 是本地查询,失败抛错(不静默)
        let isInterpreted: Bool
        if let compatSnapshot = try compatibilityStore.get(compatibilityHash: result.response.compatibilityHash) {
            isInterpreted = compatSnapshot.interpretation != nil
        } else {
            isInterpreted = false
        }

        return PairSummary(
            id: result.response.compatibilityHash,
            entry: entry,
            personBHash: result.personBHash,
            displayName: displayName,
            birthDate: bSnapshot.birthSolarTime,
            dayMaster: dayMaster,
            fiveElements: result.response.qualitativeAssessment.fiveElements,
            dayMasterRelation: result.response.qualitativeAssessment.dayMasterRelation,
            compatibilityHash: result.response.compatibilityHash,
            isInterpreted: isInterpreted,
            status: .computed
        )
    }

    // MARK: - 详情态(S02)

    /// 进入指定对的详情(决策 D1:点卡片进详情;D3:AI 逐对按需)。
    ///
    /// 流程:
    /// 1. 取 CompatibilitySnapshot + chartA/chartB snapshots
    /// 2. decode qualitative + syncedFortune 构造 CompatibilityResponse
    /// 3. 同步进入 detail(.idle);后台查 24h AI 缓存,命中更新 .okFree/.okPaid(cached:true)
    ///
    /// 失败显式抛出:compatibility snapshot 缺失 / decode 失败 → detail 态降级为
    /// `(.failed interpretState)` 让 UI 显错(决策 S02 红线:不静默降级)。
    func openDetail(_ summary: PairSummary) {
        AppLogger.app.info("compatVM.openDetail.start hash=\(summary.compatibilityHash, privacy: .public) entry_id=\(summary.entry.id, privacy: .public)")

        let compatSnapshot: CompatibilitySnapshot?
        do {
            compatSnapshot = try compatibilityStore.get(compatibilityHash: summary.compatibilityHash)
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.openDetail get_failed hash=\(summary.compatibilityHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            // 进入 detail 但 interpretState 显式错误(不静默吞;人话文案,原始 error 已记上方日志)
            let response = Self.fallbackResponse(for: summary)
            state = .detail(summary, response, .failed(message: String(localized: "读取合盘数据失败,请重试")))
            return
        }
        guard let snapshot = compatSnapshot else {
            // 不静默吞:快照缺失(理论上不会发生,compute() 刚 upsert 过)
            AppLogger.app.error("op=compatibility.openDetail missing_snapshot hash=\(summary.compatibilityHash, privacy: .public)")
            let response = Self.fallbackResponse(for: summary)
            state = .detail(summary, response, .failed(message: String(localized: "合盘快照缺失,请重新合盘")))
            return
        }

        // decode qualitative + syncedFortune 构造 CompatibilityResponse
        // (CompatibilityMainView 只用 qualitativeAssessment + syncedFortune,其他字段可 nil)
        do {
            let qualitative = try compatibilityStore.decodeQualitative(from: snapshot)
            let synced = try compatibilityStore.decodeSyncedFortune(from: snapshot)
            let response = CompatibilityResponse(
                compatibilityHash: summary.compatibilityHash,
                personAChart: nil,
                personBChart: nil,
                qualitativeAssessment: qualitative,
                syncedFortune: synced,
                calcRuleSnapshot: nil,
                ruleVersion: snapshot.engineRuleVersion,
                // 2026-10-07 P0 收口:interpret/translate 验签 token(老快照 nil)
                contextToken: snapshot.contextToken
            )
            // 在飞重进显示生成中(2026-10-07 review):本对解读仍在飞(豁免
            // 重生成被换出后再进)→ 初始 .fetching 而非 .idle——否则生成期间
            // 页面渲染空闲/达限卡,既误导也让在飞守卫的静默变成"卡死"观感
            let initialInterpretState: InterpretState =
                interpretInFlight?.compatHash == summary.compatibilityHash
                ? .fetching : .idle
            state = .detail(summary, response, initialInterpretState)
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.openDetail decode_failed hash=\(summary.compatibilityHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            let response = Self.fallbackResponse(for: summary)
            state = .detail(summary, response, .failed(message: String(localized: "合盘数据异常,请重新计算")))
            return
        }

        // 后台查 24h AI 缓存(命中 → interpretState 刷新为 .okFree/.okPaid cached:true;
        // 未命中/读失败 → 自动起链,#13,2026-10-01 用户拍板「免费章节直接展开」)
        // cancel 块必须先于 refreshStaleEngineAssessment 的调用(2026-10-07 review
        // 修复):若先建任务再走到这里的 engineRefreshTask?.cancel(),新任务会
        // 在起跳前被取消——请求静默死掉(连取消都不留痕),后台重算变死代码。
        cacheReadTask?.cancel()
        translateTask?.cancel()
        engineRefreshTask?.cancel()
        interpretGateTask?.cancel()
        isTranslating = false
        translationOffer = nil
        translationFailed = false
        // 规则版本失配(2026-10-07):快照按旧引擎规则算出 → 上面已照常渲染
        // (离线也有内容),此处后台重算;落定且仍在本对时原位刷新。
        // 常规入口是 computePair 预查(每轮 compute 全量过),此处只兜
        // openDetail 直达而预查未及的边缘。cacheReadTask 尾部的引擎规则门
        // (engineRuleBecameFresh)会等这个任务落定再决定是否自动生成。
        if !CompatibilitySnapshotStore.isFreshEngineRule(snapshot) {
            AppLogger.app.info(
                "op=compatibility.openDetail.rule_version_stale hash=\(summary.compatibilityHash, privacy: .public) snapshot=\(snapshot.engineRuleVersion.map(String.init) ?? "nil", privacy: .public) expected=\(CompatibilitySnapshotStore.expectedEngineRuleVersion, privacy: .public) — 渲染旧值并后台重算"
            )
            _ = refreshStaleEngineAssessment(for: summary)
        }
        let summaryHash = summary.compatibilityHash
        cacheReadTask = Task { [weak self] in
            guard let self else { return }
            var cacheHit = false
            do {
                if let cached = try await self.orchestrator.cachedInterpretationIfFresh(
                    compatibilityHash: summaryHash
                ) {
                    cacheHit = true
                    guard case .detail(let currentSummary, let response, _) = self.state,
                          currentSummary.id == summary.id else { return }
                    let hasEntitlement = self.entitlementStore.getActive(
                        contentHash: summaryHash,
                        module: EntitlementModule.compatibility,
                        userLocalId: UserIdentity.userLocalId
                    ) != nil
                    let newState: InterpretState = hasEntitlement
                        ? .okPaid(text: cached.text, cached: true)
                        : .okFree(text: cached.text, cached: true)
                    if !Task.isCancelled {
                        self.state = .detail(currentSummary, response, newState)
                    }
                } else if let cross = try await self.orchestrator
                    .cachedCrossLanguageInterpretationIfFresh(
                        compatibilityHash: summaryHash
                    ) {
                    // D10.5(S7):当前语言 miss 但其它语言有既有解读 →
                    // 先显示原文 + 自动翻译(L3/F1 修订 D10.5,失败走提示条)。
                    // 在飞守卫(2026-10-07 review 修复 #2):本对(豁免)重生成
                    // 仍在飞 → 不起翻译——修复前重进会"翻译→原文过期→取消在飞
                    // 重生成(后端已扣费)→再起新重生成",同对双花 LLM。在飞链
                    // 落定会写当前语言内容,翻译提议没有意义;autoGenerate 同理
                    // 不再触发(直接 return 短路尾部)。
                    guard self.interpretInFlight?.compatHash != summaryHash else {
                        AppLogger.app.info(
                            "op=compatibility.openDetail.cross_language_skip_in_flight hash=\(summaryHash, privacy: .public) — 本对重生成在飞,等其落定(不翻译/不重复起链)"
                        )
                        return
                    }
                    guard case .detail(let currentSummary, let response, _) = self.state,
                          currentSummary.id == summary.id else { return }
                    let hasEntitlement = self.entitlementStore.getActive(
                        contentHash: summaryHash,
                        module: EntitlementModule.compatibility,
                        userLocalId: UserIdentity.userLocalId
                    ) != nil
                    // 付费键原文但无 entitlement:不显示付费级原文(越权),
                    // 也不提示翻译(翻译也会被后端拦);不早退——#13(2026-10-01)
                    // 手动生成入口已拔除,早退会让 UI 停在无人触发的推演态死路,
                    // 落到下方自动起链按免费层生成
                    if cross.module == "compatibility_paid" && !hasEntitlement {
                        AppLogger.app.info(
                            "op=compatibility.openDetail cross_language_paid_locked hash=\(summaryHash, privacy: .public)"
                        )
                    } else if cross.module == "compatibility_free" && hasEntitlement {
                        // 镜像对称分支(2026-10-02 修复):免费层原文 × 已付费
                        // ——原文层级低于已购层级,展示/翻译只会把免费 2 章
                        // 固化成 .okPaid 态;#13 手动生成入口已拔除,状态机
                        // 非 .idle 后付费 4 章永远无人触发。同样不早退,落到
                        // 下方自动起链按付费层在当前语言生成。
                        AppLogger.app.info(
                            "op=compatibility.openDetail cross_language_free_under_entitled hash=\(summaryHash, privacy: .public)"
                        )
                    } else {
                        self.translationOffer = TranslationOffer(
                            sourceLanguage: cross.language,
                            module: cross.module,
                            promptVersion: cross.promptVersion,
                            text: cross.text
                        )
                        let newState: InterpretState = hasEntitlement
                            ? .okPaid(text: cross.text, cached: true)
                            : .okFree(text: cross.text, cached: true)
                        if !Task.isCancelled {
                            self.state = .detail(currentSummary, response, newState)
                            AppLogger.app.info(
                                "op=compatibility.openDetail cross_language hash=\(summaryHash, privacy: .public) source=\(cross.language, privacy: .public) module=\(cross.module, privacy: .public)"
                            )
                            // L3/F1(修订 D10.5):打开即自动翻译(会话去重,失败后
                            // 走提示条手动重试);翻译中提示条隐藏
                            self.autoTranslateCrossLanguageIfIdle(compatibilityHash: summaryHash)
                        }
                    }
                }
            } catch CompatibilityError.forbiddenWordsHit {
                guard case .detail(let currentSummary, let response, _) = self.state,
                      currentSummary.id == summary.id else { return }
                if !Task.isCancelled {
                    self.state = .detail(currentSummary, response, .failed(message: String(localized: "解读包含不合规绝对结论,请重试")))
                }
            } catch is CancellationError {
                return
            } catch {
                AppLogger.persistence.error(
                    "op=compatibility.openDetail cache_read_failed hash=\(summaryHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                // 缓存读失败不阻塞 detail 态:照走自动起链(客户端缓存只是优化,
                // 后端 SQLite 还有一层缓存,命中不耗次数)
            }
            // 自动解读(#13):缓存未命中且次数未耗尽 → 起链(每对至多一次,
            // openDetail 是 .idle 的唯一入口;换到已解读过的对会先命中上面的缓存)
            guard !Task.isCancelled, !cacheHit else { return }
            // 自动生成形态预检(镜像 autoGenerateInterpretationIfIdle 的 .idle
            // 判据):非 .idle(跨语言原文 .okFree/.okPaid)本就不起链——不过
            // 门、也不写失败;门失败分支若在此形态盖 .failed 会丢原文展示。
            guard case .detail(let gateSummary, _, .idle) = self.state,
                  gateSummary.id == summary.id else { return }
            // 次数耗尽前置于引擎规则门(第九轮 review #3):门不看剩余次数就
            // 写 .failed 会把「达限 + 购买」卡换掉——耗尽时维持 .idle(UI 按
            // remainingReads 渲染达限卡),不过门、不发注定 dailyLimitReached 的
            // 生成(镜像 autoGenerateInterpretationIfIdle 的同款守卫)。
            guard self.remainingReads > 0 else { return }
            // 引擎重算成门(2026-10-07 review 再修,原「只等待不看结果」):
            // 重算失败且快照仍未新鲜时**不起自动生成**——旧标签会随 prompt
            // 写进新生成的正文并落双层缓存,重算成功后评估卡换新标签、正文却
            // 按旧标签滞后 24h,同屏自相矛盾。重算成功但版本号仍落后时放行
            // (第九轮 #2:倒挂/旧后端不得拦死,见 engineRuleBecameFresh 尾注,
            // state 已随重算原位刷新为服务端当前标签)。门未过 → 显式失败给
            // 重试入口(重试入口 retryInterpretation 同样过门并补发重算,
            // runGatedGeneration);.idle + 次数有余在 UI 渲染成「推演中」,
            // 不写失败 = 死转圈。缓存命中展示不受此门(取舍④口径)。
            // retryAfterDeadTask=false:补发重算推迟到用户显式重试(重试链
            // 传 true,门内补发),自动链每次进对不空打注定失败的请求(离线
            // 零收益)。
            let ruleFresh = await self.engineRuleBecameFresh(summary, retryAfterDeadTask: false)
            guard !Task.isCancelled else { return }
            guard ruleFresh else {
                // 仍在本对且仍 .idle 才写:门等待期间在飞豁免链可能已落
                // .okFree,不得覆盖新内容
                if case .detail(let current, let currentResponse, .idle) = self.state,
                   current.id == summary.id {
                    AppLogger.app.warning(
                        "op=compatibility.autoGenerate.deferred reason=engine_rule_stale hash=\(summaryHash, privacy: .public) — 重算未成,不把旧标签写进生成 prompt"
                    )
                    self.state = .detail(
                        current, currentResponse,
                        .failed(message: self.engineGateFailureMessage(for: summaryHash))
                    )
                }
                return
            }
            self.autoGenerateInterpretationIfIdle(summaryID: summary.id)
        }
    }

    /// 引擎规则版本失配快照的后台重算(2026-10-07):旧值先渲染兜底,重算
    /// (runDeterministic 内含 upsert 覆盖)落定且仍在本对 detail 时原位刷新
    /// 评估卡;换对/退出则只留库(下轮 compute 预查自然取新)。失败留痕不吞
    /// (并按对记入 engineRefreshOutcomes 供引擎规则门透出根因),不打断已渲染
    /// 的旧内容。
    /// 返回本次创建的重算任务;早退(A 盘缺失,注定无法重算)返回 nil。
    /// 调用方(openDetail / engineRuleBecameFresh)不得拿返回值当「重算成功」
    /// ——门以重读 store 的新鲜度为准,任务完成 ≠ 快照已新(失败/服务端仍回
    /// 旧版都会落空)。
    private func refreshStaleEngineAssessment(for summary: PairSummary) -> Task<Void, Never>? {
        guard let chartA = archivedCharts[safe: selectedChartAIndex] else {
            AppLogger.persistence.error(
                "op=compatibility.refreshStaleEngineAssessment skip reason=a_snapshot_missing hash=\(summary.compatibilityHash, privacy: .public)"
            )
            return nil
        }
        engineRefreshTask?.cancel()
        let contextValue = self.context
        let summaryID = summary.id
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            do {
                let baziA = try self.chartStore.decodeResponse(from: chartA.snapshot)
                let payloadA = ChartPayloadDTO.compatibilityPayload(from: baziA)
                // 请求构造镜像 computePair(archived 带存档 B payload;temp 现排)
                let request: CompatibilityRequest
                switch summary.entry {
                case .archived(let bHash):
                    guard let bChart = try self.chartStore.get(contentHash: bHash) else {
                        throw UserFacingError.generic(message: String(localized: "对方命盘快照缺失,请重新选择"))
                    }
                    let baziB = try self.chartStore.decodeResponse(from: bChart)
                    request = CompatibilityRequest(
                        personAHash: chartA.snapshotHash,
                        personBHash: bHash,
                        chartPayloadA: payloadA,
                        chartPayloadB: ChartPayloadDTO.compatibilityPayload(from: baziB),
                        context: contextValue,
                        contextTokenA: baziA.payloadContextToken ?? "",
                        contextTokenB: baziB.payloadContextToken ?? ""
                    )
                case .temp(let input, _, _, _):
                    request = CompatibilityRequest(
                        personAHash: chartA.snapshotHash,
                        personB: input,
                        chartPayloadA: payloadA,
                        context: contextValue,
                        contextTokenA: baziA.payloadContextToken ?? ""
                    )
                }
                _ = try await self.orchestrator.runDeterministic(
                    request: request, personAHash: chartA.snapshotHash
                )
                // 重算请求成功(取消不适用——被取消的重算不落定任何语义):
                // 按对记 .success,引擎规则门据此放行(版本仍落后时的处置见
                // engineRuleBecameFresh 尾注);后续 verify 仍以 store 新鲜度为
                // 准,这里只记录「网络层面没有失败」
                self.engineRefreshOutcomes[summary.compatibilityHash] = .success(())
                // 仍在本对 detail 才原位刷新;保留当前 interpretState(可能在飞)。
                // 第九轮三查修正:刷新**不设 isFreshEngineRule 前置**——200 + upsert
                // 落库后 store 内容就是服务端当前口径,版本号落后(expected 领先 =
                // 部署倒挂/旧后端缺字段)不改变「内容是新的」;若跳过刷新,
                // engineRuleBecameFresh 的 .success 放行会让生成 prompt 读 state
                // 里的旧本地标签,放行论据「标签已是服务端当前口径」落空,倒挂
                // 窗口内旧标签照样进双层缓存(与评估卡错配 24h)。
                guard !Task.isCancelled,
                      case .detail(let current, _, let interpretState) = self.state,
                      current.id == summaryID,
                      let refreshed = try self.compatibilityStore.get(
                          compatibilityHash: summary.compatibilityHash
                      )
                else { return }
                let qualitative = try self.compatibilityStore.decodeQualitative(from: refreshed)
                let synced = try self.compatibilityStore.decodeSyncedFortune(from: refreshed)
                self.state = .detail(current, CompatibilityResponse(
                    compatibilityHash: summary.compatibilityHash,
                    personAChart: nil,
                    personBChart: nil,
                    qualitativeAssessment: qualitative,
                    syncedFortune: synced,
                    calcRuleSnapshot: nil,
                    ruleVersion: refreshed.engineRuleVersion
                ), interpretState)
                AppLogger.app.info(
                    "op=compatibility.refreshStaleEngineAssessment.ok hash=\(summary.compatibilityHash, privacy: .public)"
                )
            } catch {
                if !Task.isCancelled {
                    self.engineRefreshOutcomes[summary.compatibilityHash] = .failure(error)
                    AppLogger.persistence.error(
                        "op=compatibility.refreshStaleEngineAssessment.failed hash=\(summary.compatibilityHash, privacy: .public) error=\(String(describing: error), privacy: .public) — 保留旧渲染,下轮 compute 预查重算"
                    )
                }
            }
        }
        engineRefreshTask = task
        return task
    }

    /// 引擎规则门(2026-10-07 review #2/#3;第九轮 review #1/#2 再修):自动
    /// 生成 / STALE_SOURCE 豁免重生成 / 手动重试 / 购买回调(runGatedGeneration)
    /// 共用的成门判定——本对快照规则版本过期时,等待(没有则发起)后台重算,
    /// 返回**重算后的快照可否作为生成依据**。
    ///
    /// 只等待不看结果是假门(第七轮修复的缺口):重算失败(离线/后端故障)时
    /// 照常生成,旧标签随 prompt 写进正文并落双层缓存,重算成功后正文滞后 24h
    /// 与评估卡自相矛盾。重算失败 → 拦,显式失败给重试入口(重试过门,门内
    /// 补发重算自愈)。自动链(openDetail)与手动链(retryInterpretation /
    /// 购买回调,runGatedGeneration)都过门(第九轮外评再修,原「手动重试
    /// 不拦」——门失败态的重试入口直连生成,离线过期对恰好在网络恢复后被
    /// 旧标签污染)。
    ///
    /// 第九轮 #2(版本号不收敛不得拦死):store 复验仍不新鲜、但本对最近一次
    /// 重算**成功**时放行——runDeterministic 200 且 upsert 落库,标签就是服务端
    /// 当前口径(refreshStaleEngineAssessment 已随重算把 state 原位刷新,prompt
    /// 读到的即新标签);版本号落后只说明客户端 expected 领先(部署倒挂)或
    /// 旧后端不回 rule_version,拦下等于所有对(含已付款购买回调)永久
    /// 「未知错误」且无法自愈,是更坏的失败。核心保护不受损:「旧标签进
    /// prompt」的前提(重算失败/未跑)在重算成功时不成立。
    ///
    /// 读 `engineRefreshTask` 是安全的:任务真伪不靠它判,门尾必须重读 store
    /// 验证新鲜度——旧任务被取消 / refreshStaleEngineAssessment 早退 nil 时,
    /// 验证步给出正确答案(仍过期 → 拦)。**但复用的必须是活任务**:
    /// `engineRefreshTask` 从不置 nil,openDetail 起的重算失败落定后就是死任务
    /// ——翻译提示条手动重试再入 409 又进本门时只等死任务,门被死任务钉死,
    /// 「网络恢复后手动重试自愈」的承诺落空(三查 R1)。此场景按
    /// `retryAfterDeadTask` 补发一次重算再验。换对会先 cancel 本门所在的
    /// translateTask / cacheReadTask(openDetail),await 后的 isCancelled 守卫
    /// 保证补发不会取消别对在飞重算后再起新任务;重试/购买回调的门 Task
    /// (interpretGateTask)虽已持有并在换对时取消,补发前的
    /// currentDetailIfMatches 换对守卫仍兜同一件事(三查 R1,纵深防御)。
    /// - Parameter retryAfterDeadTask: 复用的重算任务已落定且复验仍过期时
    ///   是否补发。手动链(翻译 STALE_SOURCE 重试 / 购买回调 /
    ///   retryInterpretation,runGatedGeneration)传 **true**——用户显式动作是
    ///   网络恢复后的自愈入口,死任务不补发 = 门被钉死;openDetail 自动链传
    ///   **false**——补发推迟到用户显式重试,自动链每次进对不空打注定失败的
    ///   请求(离线零收益)。已知残留(2026-10-07 外评 #9,未修):
    ///   engineRefreshTask 不清空使自动链的重算每会话只发第一次,后续对靠
    ///   手动重试的补发自愈。
    private func engineRuleBecameFresh(
        _ summary: PairSummary, retryAfterDeadTask: Bool
    ) async -> Bool {
        let compatHash = summary.compatibilityHash
        if snapshotIsFreshInStore(compatHash: compatHash) { return true }
        let existingTask = engineRefreshTask
        let refresh = existingTask ?? refreshStaleEngineAssessment(for: summary)
        if let refresh { await refresh.value }
        guard !Task.isCancelled else { return false }
        if snapshotIsFreshInStore(compatHash: compatHash) { return true }
        if existingTask != nil, retryAfterDeadTask {
            // 补发前换对守卫(2026-10-07 三查 R1):门不都跑在会被换对取消的
            // 任务里(compute 换对不取消 translateTask;interpretGateTask 虽已
            // 持有,守卫是纵深防御)——await 醒来已不在本对 detail 时,补发的
            // refreshStaleEngineAssessment 会 engineRefreshTask?.cancel() 把
            // **新对刚起**的在飞重算取消,新对自动链被拒显网络错误。已换对
            // → 不补发,按未新鲜返回(调用方的 stale_pair_skip 守卫自会放弃,
            // 旧对留给重开后的链路接管)。
            guard currentDetailIfMatches(summary) != nil else { return false }
            // 死任务复用后仍未新鲜:补发一次重算(显式动作的自愈路径)
            let retry = refreshStaleEngineAssessment(for: summary)
            if let retry { await retry.value }
            guard !Task.isCancelled else { return false }
            if snapshotIsFreshInStore(compatHash: compatHash) { return true }
        }
        if case .success? = engineRefreshOutcomes[compatHash] {
            AppLogger.app.warning(
                "op=compatibility.engineRuleGate.refresh_ok_version_lag hash=\(compatHash, privacy: .public) expected=\(CompatibilitySnapshotStore.expectedEngineRuleVersion, privacy: .public) — 重算成功按放行(服务端版本落后=部署倒挂/缺字段,不拦生成)"
            )
            return true
        }
        return false
    }

    /// 引擎规则门的 store 复验:读失败显式日志 + 按未新鲜处理(false = 拦,
    /// 不拿读失败冒充「已新鲜」放行生成)。
    private func snapshotIsFreshInStore(compatHash: String) -> Bool {
        do {
            guard let snapshot = try compatibilityStore.get(compatibilityHash: compatHash) else {
                return false
            }
            return CompatibilitySnapshotStore.isFreshEngineRule(snapshot)
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.engineRuleGate.verify_failed hash=\(compatHash, privacy: .public) error=\(String(describing: error), privacy: .public) — 按未新鲜处理(不起生成)"
            )
            return false
        }
    }

    /// 引擎规则门未过时的失败文案(三入口共用,按对取根由)见
    /// `engineGateFailureMessage(for:)`——第九轮 #5 已从全局单值改为按对
    /// engineRefreshOutcomes;版本落后场景走门尾放行(不再停「未知错误」)。

    /// 进入 detail 后的自动起链守卫:仍在本对的 .idle 态且次数未耗尽才触发。
    /// 次数耗尽保持 .idle(UI 按 remainingReads 渲染达限卡);缓存命中/已起链
    /// (态已非 .idle)自然短路,不重复消耗。
    private func autoGenerateInterpretationIfIdle(summaryID: String) {
        guard case .detail(let currentSummary, _, let interpretState) = state,
              currentSummary.id == summaryID,
              case .idle = interpretState else { return }
        // 在飞守卫(2026-10-07 review 修复 #2):本对解读 Task 仍在飞(典型:
        // 豁免重生成)→ 不重复起链——起链会取消在飞任务并再扣一次配额/再花
        // 一次 LLM
        guard interpretInFlight?.compatHash != currentSummary.compatibilityHash else {
            AppLogger.app.info(
                "op=compatibility.autoGenerate skip reason=interpret_in_flight hash=\(currentSummary.compatibilityHash, privacy: .public)"
            )
            return
        }
        guard remainingReads > 0 else {
            AppLogger.app.info("op=compatibility.autoGenerate skip reason=quota_exhausted hash=\(currentSummary.compatibilityHash, privacy: .public)")
            return
        }
        AppLogger.app.info(
            "op=compatibility.autoGenerate.start compatibilityHash=\(currentSummary.compatibilityHash, privacy: .public)"
        )
        generateInterpretation()
    }

    /// L3/F1 跨语言自动翻译入口:有提议且本会话未自动过 → 直接翻(去重键
    /// (hash, target),防反复 openDetail 循环烧 LLM;失败走提示条手动重试)。
    private func autoTranslateCrossLanguageIfIdle(compatibilityHash: String) {
        guard translationOffer != nil, !isTranslating else { return }
        let key = compatibilityHash + "|" + AppLanguage.currentWire
        if let outcome = autoTranslationOutcomes[key] {
            guard outcome != .failed else {
                // F3(2026-10-02 修复;2026-10-06 收窄到「真失败」):落定失败后
                // 不再自动重试(防烧 LLM),但必须恢复失败态——静默 return 会让
                // translationFailed 停留 false(提示条不渲染),而 interpretState
                // 已是 .okFree/.okPaid 原文态(autoGenerate 不触发),页面停在
                // 旧语言,重启前无出路。
                translationFailed = true
                AppLogger.app.info("op=compatibility.autoTranslate.skip reason=already_failed key=\(key, privacy: .public) — 恢复失败提示条(手动重试)")
                return
            }
            // .interrupted:上次翻译被换对/退出 detail 打断——不是失败,重开续译
            // 剩余(成功即收口;真失败会改记 .failed,防循环烧 LLM)
            AppLogger.app.info("op=compatibility.autoTranslate.resume reason=interrupted key=\(key, privacy: .public) — 续译剩余原文")
        }
        autoTranslationOutcomes[key] = .interrupted
        AppLogger.app.info("op=compatibility.autoTranslate.start hash=\(compatibilityHash, privacy: .public)")
        acceptTranslation()
    }

    // MARK: - AI 合盘解读(按对触发,决策 D3)

    /// generateInterpretation / acceptTranslation 共用的请求侧输入
    /// (2026-10-02 抽取,单一事实源:两处各写一份会漂移——promptNameB /
    /// nameA 的裁决改一处漏一处时,生成与翻译的 user_input 维度分叉,
    /// 缓存键对齐静默破裂,译文落进无人读的键且不报错)。
    private struct CompatPromptInputs {
        let baziA: BaziResponse
        let baziB: BaziResponse
        let chartA: ChartPromptContext
        let chartB: ChartPromptContext
        let nameA: String
        let nameB: String
    }

    /// 组装双盘 PromptContextBuilder 上下文 + 两人称呼。
    /// decode 失败显式上抛(调用方 catch 转 failed 态,不吞)。
    private func buildCompatPromptInputs(
        chartASnapshot: ChartSnapshot,
        bSnapshot: ChartSnapshot,
        summary: PairSummary
    ) throws -> CompatPromptInputs {
        let baziA = try chartStore.decodeResponse(from: chartASnapshot)
        let baziB = try chartStore.decodeResponse(from: bSnapshot)
        let chartA = PromptContextBuilder.chartContext(
            from: baziA,
            gender: chartASnapshot.gender,
            cityDisplay: cityDisplay(for: chartASnapshot)
        )
        let chartB = PromptContextBuilder.chartContext(
            from: baziB,
            gender: bSnapshot.gender,
            cityDisplay: cityDisplay(for: bSnapshot)
        )
        // 2026-09-28 prompt 称谓修复:nameB 不能用 displayName 的兜底串
        // (「对方 · 1985-07-12」会被 v4 模板当人名通篇复述);alias 缺失时
        // 用纯「对方」。UI 列头(CompatibilityView)仍用 displayName,两口径分开。
        let nameB: String
        switch summary.entry {
        case .archived(let bHash):
            nameB = archivedCharts.first { $0.snapshotHash == bHash }?.alias
                ?? String(localized: "对方")
        case .temp(_, let alias, _, _):
            if let alias, !alias.isEmpty {
                nameB = alias
            } else {
                nameB = String(localized: "对方")
            }
        }
        return CompatPromptInputs(
            baziA: baziA, baziB: baziB, chartA: chartA, chartB: chartB,
            nameA: L10n.Compatibility.selfReferenceYou, nameB: nameB
        )
    }

    /// 触发该对 AI 解读(只对 detail 态当前对生效)。
    /// 购买成功后由 PaywallView onPurchaseSuccess 调用,亦按当前 detail 态对触发。
    /// - Parameter quotaExempt: R3(2026-10-02 review):翻译 STALE_SOURCE 降级
    ///   重生成豁免次数(语言切换引起,与深度解析 L4 同口径);用户主动生成
    ///   恒走默认 false(正常扣次数)。
    func generateInterpretation(quotaExempt: Bool = false) {
        guard case .detail(let summary, let response, _) = state else {
            // 不静默吞(CLAUDE.md 全局约束):UI 收到点击说明状态机错乱,显式记录
            AppLogger.app.error("op=compatibility.generateInterpretation invalid_state state=\(String(describing: self.state), privacy: .public)")
            return
        }
        let compatHash = summary.compatibilityHash
        // Bug5:记录本次豁免语义(失败态重试经 retryInterpretation 按对透传)。
        // 提升到快照守卫之前(2026-10-07 review):提前 return 的失败路径也要
        // 能 settle 结局——否则豁免链结局键停留 .interrupted,重进每轮空转
        // "翻译→原文过期→重新生成→本地失败"。
        // 按对收窄(2026-10-07 review #4):非豁免尝试只清**本对**的旧豁免
        // 标记——无条件置 nil 会把别对在飞/待重试的豁免语义一并抹掉(修复前:
        // X 对提前失败 return,Y 对标记被清,Y 的 .failed 重试退回扣次数)。
        if quotaExempt {
            exemptAttemptCompatHash = compatHash
        } else if exemptAttemptCompatHash == compatHash {
            exemptAttemptCompatHash = nil
        }
        guard let chartASnapshot = archivedCharts[safe: selectedChartAIndex]?.snapshot,
              let bSnapshot = try? chartStore.get(contentHash: summary.personBHash) else {
            // 豁免链提前失败也记 .failed(重开恢复走手动重试,不空转)
            settleExemptRegenOutcomeIfCurrent(
                compatHash: compatHash,
                attemptKey: compatHash + "|" + AppLanguage.currentWire
            )
            state = .detail(summary, response, .failed(message: String(localized: "命盘快照缺失,请重新合盘")))
            return
        }

        // 在飞标记(#2 修复):重进同对时 cacheReadTask 据此抑制翻译/重复起链
        let inFlightToken = UUID()
        interpretInFlight = (compatHash, inFlightToken)

        // M4:查本地 entitlement 决定 module(基础名 "compatibility")
        let hasEntitlement = entitlementStore.getActive(
            contentHash: compatHash,
            module: EntitlementModule.compatibility,
            userLocalId: UserIdentity.userLocalId
        ) != nil
        let module = hasEntitlement ? "compatibility_paid" : "compatibility_free"
        // 规则 2:用户主动触发 + 付费分支决策日志
        AppLogger.app.info("compatVM.generateInterpretation.start compatibilityHash=\(compatHash, privacy: .public) module=\(module, privacy: .public) hasEntitlement=\(hasEntitlement, privacy: .public)")

        cacheReadTask?.cancel()
        interpretTask?.cancel()
        translateTask?.cancel()
        // 重新生成取代翻译提议(D10.5:点过生成即不再需要翻译原文)
        translationOffer = nil
        isTranslating = false
        translationFailed = false
        state = .detail(summary, response, .fetching)

        interpretTask = Task { [weak self] in
            guard let self else { return }
            // 在飞标记收口:所有出口(成功/失败/取消)都经 defer 清,token
            // 比对防旧链误清新链标记
            defer {
                if self.interpretInFlight?.token == inFlightToken {
                    self.interpretInFlight = nil
                }
            }
            // 结局键快照:豁免链(STALE 降级)成功清键 / 失败记 .failed 都用
            // 链起跑时的语言拼键(镜像 acceptTranslation 的 attemptKey 口径)
            let attemptKey = compatHash + "|" + AppLanguage.currentWire
            do {
                let inputs = try self.buildCompatPromptInputs(
                    chartASnapshot: chartASnapshot, bSnapshot: bSnapshot,
                    summary: summary)
                // S07 阶段 2 拦截(免费亦拦):任一方无时辰(payload 判据)→ 不发
                // interpret 请求。正常路径拦截对进不了 detail(computePair 已拦),
                // 此处防御购买回调/状态机错乱;文案与对级拦截卡同源。
                if inputs.baziA.hourUnknownGate != .hourKnown || inputs.baziB.hourUnknownGate != .hourKnown {
                    AppLogger.app.warning(
                        "op=compatibility.generateInterpretation.skip reason=hour_unknown a_gate=\(String(describing: inputs.baziA.hourUnknownGate), privacy: .public) b_gate=\(String(describing: inputs.baziB.hourUnknownGate), privacy: .public) compatibilityHash=\(compatHash, privacy: .public)"
                    )
                    // 豁免链提前失败记 .failed(2026-10-07 review):不 settle 会
                    // 让结局键停留 .interrupted,重进每轮空转翻译→重生成→拦截
                    self.settleExemptRegenOutcomeIfCurrent(compatHash: compatHash, attemptKey: attemptKey)
                    // 回写守卫补漏(2026-10-07 review):与成功/失败路径同口径,
                    // 取当前 state 的 summary/response——链起跑与执行之间引擎
                    // 重算可能已原位刷新,用捕获的旧 response 回写会把卡片盖回
                    // 旧标签(或覆写另一对的详情)
                    if let (current, currentResponse) = self.currentDetailIfMatches(summary) {
                        self.state = .detail(
                            current, currentResponse,
                            .failed(message: L10n.PaywallGate.compatibilityReason)
                        )
                    }
                    return
                }
                let resp = try await self.orchestrator.runInterpretation(
                    compatibilityHash: compatHash,
                    chartA: inputs.chartA,
                    chartB: inputs.chartB,
                    assessment: response.qualitativeAssessment,
                    syncedFortune: response.syncedFortune,
                    context: self.context,
                    // 2026-09-27 A/B 代号修复:A 恒命主本人 → 「你/you」;
                    // B 走 inputs.nameB(alias / 纯「对方」,helper 内裁决)——
                    // prompt 全文与后端残留 A/B 后置替换共用这两个称呼
                    nameA: inputs.nameA,
                    nameB: inputs.nameB,
                    module: module,
                    quotaExempt: quotaExempt,
                    // 2026-10-07 P0 收口:compat 族 token(快照存档回传)
                    contextToken: response.contextToken
                )

                if Task.isCancelled { return }

                // 豁免链成功清键(2026-10-07 review 修复 D):提前到陈旧完成守卫
                // **之前**——用户已换对时落地的成功同样要清(修复前该 return 跳过
                // 清键:exemptAttemptCompatHash 残留 + 结局键停留 .interrupted,
                // 重进同对被误判"被打断"再走一轮翻译→重生成)。清的是簿记,不写
                // UI,不受换对守卫管辖;用户手动链标记本就是 nil,天然 no-op。
                if self.exemptAttemptCompatHash == compatHash {
                    self.exemptAttemptCompatHash = nil
                    self.autoTranslationOutcomes.removeValue(forKey: attemptKey)
                }

                // 陈旧完成守卫(2026-10-01):await 期间可能已换对(compute 取消
                // computeTask 但不取消 interpretTask)——旧对的完成/失败不得覆写
                // 新对的 detail 态。镜像 openDetail cacheReadTask 的 summary.id
                // 守卫;非 detail 态(computing 等)同判陈旧(被换走即不再回写)。
                // 回写取**当前** state 的 response(2026-10-07 review):await
                // 期间引擎规则重算可能已原位刷新评估卡,用链起跑时捕获的旧
                // response 回写会把卡片覆盖回旧标签。
                guard let (current, currentResponse) = self.currentDetailIfMatches(summary) else {
                    AppLogger.app.info(
                        "compatVM.generateInterpretation.stale_completion_skip compatibilityHash=\(compatHash, privacy: .public) state=\(String(describing: self.state), privacy: .public)"
                    )
                    return
                }

                let newState: InterpretState = hasEntitlement
                    ? .okPaid(text: resp.interpretation, cached: resp.cached)
                    : .okFree(text: resp.interpretation, cached: resp.cached)
                self.state = .detail(current, currentResponse, newState)

                // 解读成功 → 同步刷新 summaries 中该对的 isInterpreted
                // (返回 list 时卡片立刻显示「已解读」标记)
                self.markSummaryInterpreted(id: current.id)
            } catch let error as CompatibilityError {
                // 豁免链真失败落定先于 UI 态守卫(2026-10-07 review 修复):用户
                // 已离开该对时失败同样要记 .failed + 清在飞语义——修复前只在
                // canWriteInterpretState 通过时才 settle,离开时失败让结局键停留
                // .interrupted,之后每次重进都重复"翻译→原文过期→重生成"循环
                self.settleExemptRegenOutcomeIfCurrent(compatHash: compatHash, attemptKey: attemptKey)
                if !Task.isCancelled, let (current, currentResponse) = self.currentDetailIfMatches(summary) {
                    self.state = .detail(current, currentResponse, .failed(message: error.errorDescription ?? L10n.Common.unknownError))
                }
            } catch let error as DeepAnalysisError {
                self.settleExemptRegenOutcomeIfCurrent(compatHash: compatHash, attemptKey: attemptKey)
                if !Task.isCancelled, let (current, currentResponse) = self.currentDetailIfMatches(summary) {
                    if case .dailyLimitReached(let reset, _) = error {
                        self.state = .detail(current, currentResponse, .dailyLimitReached(nextReset: reset))
                    } else {
                        self.state = .detail(current, currentResponse, .failed(message: error.errorDescription ?? L10n.Common.unknownError))
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // 取消分诊(2026-10-07 双 review;同轮再修):URLSession 取消抛
                // URLError(.cancelled)(APIClient 包成 APIError.networkError 再抛),
                // 不进 is CancellationError 分支——两层解包判定
                // (Self.isURLErrorCancelled)。
                // - Task 已取消 = 我方发起(换对 clearDetail / 新链 cancel):
                //   中断语义,静默返回(豁免链结局保持 .interrupted,重开自动续)。
                // - 仅请求被取消而 Task 未取消(session 失效等基建性取消):
                //   不是用户离开,状态机却停在 .fetching 且 interpretInFlight 已
                //   被 defer 清掉——页面死转圈且无重试入口(手动生成入口已拔除,
                //   2026-10-07 review 🔴)。按真失败落 .failed(重试入口在),
                //   豁免链 settle 照常。
                if Task.isCancelled {
                    AppLogger.app.info(
                        "compatVM.generateInterpretation.cancelled compatibilityHash=\(compatHash, privacy: .public) — 记 interrupted,不落 failed"
                    )
                    return
                }
                if Self.isURLErrorCancelled(error) {
                    AppLogger.app.error(
                        "compatVM.generateInterpretation.url_cancelled_without_task compatibilityHash=\(compatHash, privacy: .public) — 基建性取消按失败处理(不得停在 .fetching 死转圈)"
                    )
                }
                self.settleExemptRegenOutcomeIfCurrent(compatHash: compatHash, attemptKey: attemptKey)
                if let (current, currentResponse) = self.currentDetailIfMatches(summary) {
                    let userError = UserFacingError.from(error, stage: .interpret)
                    if case .dailyLimitReached(let reset) = userError {
                        self.state = .detail(current, currentResponse, .dailyLimitReached(nextReset: reset))
                    } else {
                        self.state = .detail(current, currentResponse, .failed(message: userError.errorDescription ?? L10n.Common.unknownError))
                    }
                }
            }
        }
    }

    /// 购买成功后的重跑入口(PaywallView onPurchaseSuccess,按对绑定 D4)。
    /// 引擎规则成门(第八轮购买路径补漏;第九轮 #1/#4 收编统一门内入口
    /// runGatedGeneration):门等待期(.idle)购买完成时直调 generateInterpretation
    /// 会把旧标签写进 prompt——付费解读落 (hash, compatibility_paid) 键,后端
    /// 缓存让它活过 24h,「评估卡刑害/正文和谐」的错配对已付款用户长期存在。
    /// 正常扣次(豁免语义恒不透传,allowExemptPassthrough=false)。快照已新鲜
    /// 时门读 store 即短路,无额外等待。
    func generateInterpretationAfterPurchase() {
        runGatedGeneration(allowExemptPassthrough: false)
    }

    /// .failed / .dailyLimitReached 态的重试入口(结果页 onGenerateInterpret
    /// 接线,2026-10-06):按对透传上次尝试的豁免语义——STALE_SOURCE 降级链
    /// 失败后的重试不再把语言切换成本转嫁给用户配额;别对的 .failed(非豁免
    /// 来源)不蹭豁免。用户主动重算/自动起链仍直调 generateInterpretation()
    /// (正常扣次,入口会覆写标记);购买成功回调走
    /// generateInterpretationAfterPurchase()。
    ///
    /// 引擎规则成门(第九轮外评再修,原「重试不走门」):门失败态的 .failed
    /// 正是重试入口,直连生成会让离线打开的过期对在网络恢复后被旧标签污染
    /// 正文并落双层缓存——正是这道门要防的。门未过 → 无条件写 .failed 透真
    /// 根因(可再试;门等待期间并发链落定的 .okFree 会被盖回——镜像购买
    /// 回调的「显式动作失败反馈优先于展示保留」取舍);豁免语义门后按对
    /// 重读透传(见 runGatedGeneration 尾注)。
    func retryInterpretation() {
        runGatedGeneration(allowExemptPassthrough: true)
    }

    /// 门内生成统一入口(第九轮 review #1/#4;撞车消解收编 bug3 会话 R1
    /// 三加固):手动重试 / 购买回调共用——先过引擎规则门
    /// (retryAfterDeadTask=true:显式动作是网络恢复后的自愈入口,死重算任务
    /// 须补发一次重算),门过且仍在原对才转 generateInterpretation;门败显式
    /// 落 .failed 透**按对**重算根因。Task 持有在 interpretGateTask(#4:
    /// 不持有 = 购买回调的 Task 无人管,退出/换对后与自动链并发双起
    /// generateInterpretation = 双 LLM + 双扣次数);openDetail /
    /// clearDetailKeepRoster 取消。
    private func runGatedGeneration(allowExemptPassthrough: Bool) {
        guard case .detail(let summary, _, _) = state else {
            // 不静默吞(CLAUDE.md 全局约束):入口到达但不在 detail 态,说明
            // 状态机错乱(或用户已离开),显式记录
            AppLogger.app.error(
                "op=compatibility.runGatedGeneration invalid_state state=\(String(describing: self.state), privacy: .public)"
            )
            return
        }
        interpretGateTask?.cancel()
        interpretGateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let ruleFresh = await self.engineRuleBecameFresh(summary, retryAfterDeadTask: true)
            if Task.isCancelled { return }
            // 门等待期间换对/退出 → 放弃(重开/新对的链路自会接管)
            guard let (current, currentResponse) = self.currentDetailIfMatches(summary) else {
                AppLogger.app.info(
                    "op=compatibility.runGatedGeneration.stale_pair_skip hash=\(summary.compatibilityHash, privacy: .public)"
                )
                return
            }
            guard ruleFresh else {
                // 显式动作(重试/购买):失败反馈优先于展示保留(生成失败的既有
                // 语义同样会把 .okFree 盖成 .failed);.fetching 在飞链随后落地
                // 会覆盖本失败态,自愈不积压。
                AppLogger.app.warning(
                    "op=compatibility.runGatedGeneration.deferred reason=engine_rule_stale hash=\(summary.compatibilityHash, privacy: .public) — 重算未成,不把旧标签写进生成 prompt"
                )
                self.state = .detail(
                    current, currentResponse,
                    .failed(message: self.engineGateFailureMessage(for: summary.compatibilityHash))
                )
                return
            }
            // 在飞守卫(三查 R1):门等待是重算级(秒级),期间态保持 .failed、
            // 重试按钮持续可点,连点产生的多个门任务串行落定——无守卫时后者
            // 取消重启先落定的在飞链(已发请求被取消 = 服务端配额与本地台账
            // 漂移)。本对已有在飞生成(先落定的重试/购买回调/自动链)→ 交给
            // 它,不再起链(镜像 autoGenerateInterpretationIfIdle 的口径)。
            guard self.interpretInFlight?.compatHash != summary.compatibilityHash else {
                AppLogger.app.info(
                    "op=compatibility.runGatedGeneration skip reason=interpret_in_flight hash=\(summary.compatibilityHash, privacy: .public) — 在飞链让位,不重复起链"
                )
                return
            }
            // 豁免语义门后重读(三查 R1 / code-review P2):门等待是重算级,
            // tap 时刻捕获的 exemptAttemptCompatHash 会过期——期间并发豁免链
            // 成功已清标记(再透传 = 双 LLM + 失效豁免覆盖新正文),反向新设
            // 标记同理拿到旧 false。此处与 generateInterpretation 同一 MainActor
            // 同步块,无交错窗口。
            let passthrough = allowExemptPassthrough
                && self.exemptAttemptCompatHash == summary.compatibilityHash
            if passthrough {
                AppLogger.app.info("op=compatibility.runGatedGeneration.quota_exempt_passthrough")
            }
            self.generateInterpretation(quotaExempt: passthrough)
        }
    }

    /// 引擎规则门失败的用户文案:按对取最近一次重算失败根因(第九轮 #5:
    /// 全局单值会透出别对的错误/被别对的成功清掉);无失败记录(未跑重算/
    /// A 盘缺失早退/取消)→ 未知错误。
    private func engineGateFailureMessage(for compatHash: String) -> String {
        if case .failure(let refreshError)? = engineRefreshOutcomes[compatHash] {
            return UserFacingError.from(
                refreshError, stage: .compatibilityDeterministic
            ).errorDescription ?? L10n.Common.unknownError
        }
        return L10n.Common.unknownError
    }

    /// 豁免重生成链(STALE 降级)失败落定(2026-10-07 review):重开恢复提示条
    /// 走手动(retryInterpretation 透传豁免,不转嫁配额)。仅当本次失败确属
    /// 豁免链(exemptAttemptCompatHash 仍是本对)才写翻译结局键——用户手动链
    /// 标记为 nil,不写(手动失败与翻译提议的自动续译互不相干)。
    private func settleExemptRegenOutcomeIfCurrent(compatHash: String, attemptKey: String) {
        guard exemptAttemptCompatHash == compatHash else { return }
        autoTranslationOutcomes[attemptKey] = .failed
    }

    /// 解读/翻译 Task 回写守卫(2026-10-07 review 升级,原 canWriteInterpretState):
    /// 当前态仍是该对的 detail 才允许回写,并返回**当前** state 的
    /// summary/response——链起跑时捕获的旧 response 不得回写 UI:await 期间
    /// 引擎规则重算(refreshStaleEngineAssessment)可能已原位刷新评估卡,
    /// 旧 response 回写会把卡片覆盖回旧标签。await 期间换对(computing /
    /// 别对 detail / 非 detail)→ 陈旧完成不得覆写新对 UI,返回 nil。
    private func currentDetailIfMatches(
        _ summary: PairSummary
    ) -> (summary: PairSummary, response: CompatibilityResponse)? {
        guard case .detail(let current, let currentResponse, _) = state,
              current.id == summary.id else { return nil }
        return (current, currentResponse)
    }

    /// URL 层取消判定(2026-10-07 三查补漏):APIClient 会把 session.data 的
    /// URLError 包装成 `APIError.networkError` 抛出,裸 URLError 转型只覆盖
    /// 未经过网络栈包装的路径——两层都判,取消分诊才不依赖
    /// `Task.isCancelled` 单腿。
    /// 注意:命中 ≠ 中断语义——Task 未取消时是基建性取消(session 失效),
    /// 按真失败处理(见 generateInterpretation 的取消分诊注释)。
    private static func isURLErrorCancelled(_ error: Error) -> Bool {
        if case .networkError(let urlError)? = error as? APIError {
            return urlError.code == .cancelled
        }
        return (error as? URLError)?.code == .cancelled
    }

    /// 取消在飞解读链并同步清在飞标记(2026-10-07 review 收口,原
    /// acceptTranslation / clearDetailKeepRoster 两处同款内联):cancel 后旧链的
    /// catch/defer 收口要等网络取消错误传回 MainActor(毫秒窗口),窗口内重进
    /// 同对会被 openDetail 的 .fetching 初始态 + 在飞守卫判成「生成中」而实际
    /// 无任务在跑(永久转圈)。集中一处防后续新增取消点漏清标记。
    /// generateInterpretation **不走**此 helper——它先设新标记再 cancel 旧链,
    /// 旧链 defer 的 token 比对(nil ≠ token)天然不误伤新标记。
    private func cancelInterpretChain() {
        interpretTask?.cancel()
        interpretInFlight = nil
    }

    // MARK: - 跨语言翻译执行(D10.4/D10.5,S7)

    /// 翻译执行入口(L3/F1 起双来源:openDetail 自动触发 + 失败提示条手动重试;
    /// 原 D10.5「点按钮才翻」已修订为打开即自动)。原文 → 目标语言,不消耗
    /// 次数。入参组装镜像 generateInterpretation(同一 PromptContextBuilder
    /// 口径,缓存键对齐的前提)。
    func acceptTranslation() {
        guard let offer = translationOffer, !isTranslating else { return }
        guard case .detail(let summary, let response, _) = state else { return }
        let compatHash = summary.compatibilityHash
        // 结局记录键(2026-10-06):Task 各出口按「真失败 / 中断」分诊写入,
        // 重开时 autoTranslateCrossLanguageIfIdle 据此决定续译还是恢复提示条
        let attemptKey = compatHash + "|" + AppLanguage.currentWire
        guard let chartASnapshot = archivedCharts[safe: selectedChartAIndex]?.snapshot,
              let bSnapshot = try? chartStore.get(contentHash: summary.personBHash) else {
            state = .detail(summary, response, .failed(message: String(localized: "命盘快照缺失,请重新合盘")))
            return
        }
        AppLogger.app.info(
            "compatVM.acceptTranslation.start compatibilityHash=\(compatHash, privacy: .public) module=\(offer.module, privacy: .public) source=\(offer.sourceLanguage, privacy: .public)"
        )
        isTranslating = true
        translationFailed = false
        cacheReadTask?.cancel()
        cancelInterpretChain()
        translateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isTranslating = false }
            do {
                // 与 generateInterpretation 同一份请求构造(缓存键对齐前提;
                // 改称呼/上下文口径只改 buildCompatPromptInputs 一处)
                let inputs = try self.buildCompatPromptInputs(
                    chartASnapshot: chartASnapshot, bSnapshot: bSnapshot,
                    summary: summary)
                let resp = try await self.orchestrator.translateInterpretation(
                    compatibilityHash: compatHash,
                    chartA: inputs.chartA,
                    chartB: inputs.chartB,
                    assessment: response.qualitativeAssessment,
                    syncedFortune: response.syncedFortune,
                    context: self.context,
                    nameA: inputs.nameA,
                    nameB: inputs.nameB,
                    module: offer.module,
                    sourceLanguage: offer.sourceLanguage,
                    sourcePromptVersion: offer.promptVersion,
                    sourceInterpretation: offer.text,
                    // 2026-10-07 P0 收口:翻译同闸(译文落共享键,盘身须与 token 一致)
                    contextToken: response.contextToken
                )
                if Task.isCancelled {
                    self.autoTranslationOutcomes[attemptKey] = .interrupted
                    return
                }
                // 陈旧完成守卫(2026-10-02 review,镜像 generateInterpretation 的
                // ad124ef):compute()/continueAfterAddHourRemap 换对不取消
                // translateTask(同 ad124ef 修 interpretTask 前的漏取消),旧对
                // 翻译在飞完成时 Task.isCancelled 仍为 false,若无守卫会无条件
                // 覆写新对 state。openDetail 虽同步 cancel + MainActor 串行使
                // isCancelled 检查已够,守卫对不取消路径承载真实负载。仍在本对
                // detail 才允许回写。
                guard let (current, currentResponse) = self.currentDetailIfMatches(summary) else {
                    self.autoTranslationOutcomes[attemptKey] = .interrupted
                    AppLogger.app.info(
                        "compatVM.acceptTranslation.stale_completion_skip compatibilityHash=\(compatHash, privacy: .public)"
                    )
                    return
                }
                let hasEntitlement = self.entitlementStore.getActive(
                    contentHash: compatHash,
                    module: EntitlementModule.compatibility,
                    userLocalId: UserIdentity.userLocalId
                ) != nil
                let newState: InterpretState = hasEntitlement
                    ? .okPaid(text: resp.interpretation, cached: resp.cached)
                    : .okFree(text: resp.interpretation, cached: resp.cached)
                self.translationOffer = nil
                self.state = .detail(current, currentResponse, newState)
                self.markSummaryInterpreted(id: current.id)
                // 译完收口:结局键清除——未来同键新提议(如再次版本 bump)可重新
                // 自动翻译
                self.autoTranslationOutcomes.removeValue(forKey: attemptKey)
            } catch is CancellationError {
                self.autoTranslationOutcomes[attemptKey] = .interrupted
                return
            } catch {
                if Task.isCancelled {
                    self.autoTranslationOutcomes[attemptKey] = .interrupted
                    return
                }
                // 失败分级(D10.4 #4:已译成的保留——翻译无部分成功,此处指不丢原文):
                // - STALE_SOURCE(R3,2026-10-02 review 修订):原文版本过期 →
                //   直接自动起重新生成(quotaExempt 豁免合盘次数——语言切换引起,
                //   与深度解析 L4 口径一致;此前让用户手动点重试且照常扣次数),
                //   UI 走现有「推演中」态,无需用户介入
                // - 其他(503 保真失败等,可重试翻译):恢复原文显示 + 提示条保留,
                //   用户可再点「翻译为××」(不烧次数,也不逼用户走重新生成)
                AppLogger.app.warning(
                    "compatVM.acceptTranslation.failed compatibilityHash=\(compatHash, privacy: .public) error=\(String(describing: error), privacy: .public) — 原文与提示条保留"
                )
                if APIError.isStaleSource(error) {
                    guard self.currentDetailIfMatches(summary) != nil else {
                        self.autoTranslationOutcomes[attemptKey] = .interrupted
                        return
                    }
                    // 引擎重算门(2026-10-07 review #3):豁免重生成与自动生成
                    // 同门——本对规则版本过期且重算未成时,重生成会把旧标签写进
                    // 新生成正文并落双层缓存。门未过 → 恢复失败提示条走手动
                    // (网络恢复、重算成功后手动重试自愈:再点提示条重试 → 409 →
                    // 门已过 → 豁免重生成),原文展示态不动。retryAfterDeadTask
                    // =true:手动重试会再次进门,复用的死重算任务须补发重算,
                    // 否则门被死任务钉死、自愈承诺落空(三查 R1)。
                    let ruleFresh = await self.engineRuleBecameFresh(summary, retryAfterDeadTask: true)
                    if Task.isCancelled { return }
                    // 门等待期间换对/退出 → 中断语义(重开自动续),不落提示条
                    guard self.currentDetailIfMatches(summary) != nil else {
                        self.autoTranslationOutcomes[attemptKey] = .interrupted
                        return
                    }
                    guard ruleFresh else {
                        AppLogger.app.warning(
                            "compatVM.acceptTranslation.stale_source_regen_deferred compatibilityHash=\(compatHash, privacy: .public) — 引擎规则过期未重算成,暂不重生成(旧标签不得进 prompt)"
                        )
                        self.translationFailed = true
                        self.autoTranslationOutcomes[attemptKey] = .failed
                        return
                    }
                    AppLogger.app.warning(
                        "compatVM.acceptTranslation.stale_source_downgrade compatibilityHash=\(compatHash, privacy: .public) — 自动转免费重新生成(豁免配额)"
                    )
                    // 结局记 .interrupted(2026-10-07 review 修订,原 .failed):
                    // 豁免重生成**还没跑**,先记 .failed 是把「进行中」谎报成
                    // 「已失败」——用户中途退出再进来会看到假失败提示条,而
                    // 非自动续跑。落定点在 generateInterpretation:成功清键、
                    // 真失败记 .failed(settleExemptRegenOutcomeIfCurrent)。
                    // 期间被换对/退出打断 → 本键保持 .interrupted,重开自动
                    // 续跑(镜像深度解析的分诊口径)。
                    self.autoTranslationOutcomes[attemptKey] = .interrupted
                    self.generateInterpretation(quotaExempt: true)
                    return
                }
                // 同上:失败回写也须仍在本对 detail(换对后旧对失败态不得覆写),
                // 且用当前 state 的 response(引擎重算落定后不得覆写回旧标签)
                guard let (current, currentResponse) = self.currentDetailIfMatches(summary) else { return }
                let hasEntitlement = self.entitlementStore.getActive(
                    contentHash: compatHash,
                    module: EntitlementModule.compatibility,
                    userLocalId: UserIdentity.userLocalId
                ) != nil
                let restored: InterpretState = hasEntitlement
                    ? .okPaid(text: offer.text, cached: true)
                    : .okFree(text: offer.text, cached: true)
                // L3/F1:可重试失败 → 提示条转「翻译失败 · 重试」(原文照常展示);
                // 结局记 .failed(重开恢复提示条走手动)
                self.translationFailed = true
                self.autoTranslationOutcomes[attemptKey] = .failed
                self.state = .detail(current, currentResponse, restored)
            }
        }
    }

    /// 解读成功后同步标记 summaries 中该对为已解读(返回 list 时卡片立刻显示标记)。
    private func markSummaryInterpreted(id: String) {
        guard let idx = summaries.firstIndex(where: { $0.id == id }) else { return }
        let old = summaries[idx]
        summaries[idx] = PairSummary(
            id: old.id,
            entry: old.entry,
            personBHash: old.personBHash,
            displayName: old.displayName,
            birthDate: old.birthDate,
            dayMaster: old.dayMaster,
            fiveElements: old.fiveElements,
            dayMasterRelation: old.dayMasterRelation,
            compatibilityHash: old.compatibilityHash,
            isInterpreted: true,
            status: old.status
        )
    }

    // MARK: - 重置

    /// 清出 detail/computing 态、保留名单(2026-09-29 S5 改名,原 backToConfig——
    /// 配置页已退役,调用方:detail 快照缺失重试 / 换人 sheet 移出当前对方 /
    /// 测试 teardown)。cancel 三任务 + 进 .configuring(结果壳渲染 P5/P6 态)。
    func clearDetailKeepRoster() {
        computeTask?.cancel()
        cancelInterpretChain()
        cacheReadTask?.cancel()
        translateTask?.cancel()
        engineRefreshTask?.cancel()
        interpretGateTask?.cancel()
        isTranslating = false
        translationOffer = nil
        translationFailed = false
        state = .configuring
    }

    // MARK: - 查询(detail 态用)

    var remainingReads: Int { orchestrator.remainingReads() }
    var nextDailyReset: Date { orchestrator.nextDailyReset() }

    /// 当前 detail 态的 B 盘 ChartSnapshot(供 CompatibilityMainView 渲染双盘对比)。
    /// 非 detail 态 / snapshot 缺失返回 nil(UI 显式提示);fetch 失败显式日志(不静默吞)。
    var currentDetailBSnapshot: ChartSnapshot? {
        guard case .detail(let summary, _, _) = state else { return nil }
        do {
            return try chartStore.get(contentHash: summary.personBHash)
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.currentDetailBSnapshot fetch_failed b_hash=\(summary.personBHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// 当前 detail 态的 A 盘 ChartSnapshot。
    var currentDetailASnapshot: ChartSnapshot? {
        archivedCharts[safe: selectedChartAIndex]?.snapshot
    }

    /// PaywallView 注入用:按对化语义,仅 detail 态返回该对 hash。
    /// S01 之前是单对 1 对 1 语义(全局 lastCompatibilityHash);S02 改为按对。
    var lastCompatibilityHashForPaywall: String? {
        if case .detail(let summary, _, _) = state {
            return summary.compatibilityHash
        }
        return nil
    }

    /// S07:当前 detail 对的付费墙拦截判据(任一方无时辰 → 拦截态)。
    /// 判据单一事实源 = 双方存档 payload decode;正常路径拦截对进不了 detail
    /// (computePair 已拦),此处防御注入。非 detail 态 / B 快照缺失 → 只看 A;
    /// decode 失败显式记日志后按 .hourKnown 放行(购买链路错误已在别处显式传播,
    /// 不用拦截态掩盖解码故障)。
    var currentDetailHourUnknownGate: HourUnknownGate {
        guard case .detail(let summary, _, _) = state,
              let aSnapshot = archivedCharts[safe: selectedChartAIndex]?.snapshot else {
            return .hourKnown
        }
        do {
            let baziA = try chartStore.decodeResponse(from: aSnapshot)
            if baziA.hourUnknownGate != .hourKnown { return baziA.hourUnknownGate }
            guard let bSnapshot = try chartStore.get(contentHash: summary.personBHash) else {
                return .hourKnown
            }
            return try chartStore.decodeResponse(from: bSnapshot).hourUnknownGate
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.currentDetailHourUnknownGate decode_failed error=\(String(describing: error), privacy: .public)"
            )
            return .hourKnown
        }
    }

    /// 供结果页构造双盘对比;View 不直接访问 ChartSnapshotStore。
    func makeDualPillars(
        chartASnapshot: ChartSnapshot,
        chartBSnapshot: ChartSnapshot
    ) throws -> [DualPillarSource] {
        let baziA = try chartStore.decodeResponse(from: chartASnapshot)
        let baziB = try chartStore.decodeResponse(from: chartBSnapshot)
        return DualPillarSource.from(a: baziA, b: baziB)
    }

    // MARK: - Private

    /// openDetail 失败时的兜底 response(qualitative/syncedFortune 为占位空值)。
    /// 用户看到错误 interpretState,MainView 不崩(qualitative 字段为空字符串,syncedFortune 空数组)。
    private static func fallbackResponse(for summary: PairSummary) -> CompatibilityResponse {
        CompatibilityResponse(
            compatibilityHash: summary.compatibilityHash,
            personAChart: nil,
            personBChart: nil,
            qualitativeAssessment: QualitativeAssessmentDTO(
                fiveElements: summary.fiveElements,
                dayMasterRelation: summary.dayMasterRelation,
                zodiacMatch: "—",
                branchHarmony: "—"
            ),
            syncedFortune: [],
            calcRuleSnapshot: nil
        )
    }

    /// ChartSnapshot 城市可读展示(用经度或 cityLongitude 兜底)。
    private func cityDisplay(for snapshot: ChartSnapshot) -> String {
        // ChartSnapshot 不存城市名,只有 cityLongitude。展示经度足够 prompt 使用。
        let lon = snapshot.cityLongitude
        let hemisphere = lon >= 0 ? String(localized: "东经") : String(localized: "西经")
        return "\(hemisphere)\(String(format: "%.2f", abs(lon)))"
    }
}

// MARK: - 辅助类型

/// 已存档命盘的展示封装(避免 View 直查 SwiftData)。
struct ArchivedChart: Identifiable, Hashable {
    let snapshotHash: String
    let alias: String
    let birthDate: Date
    let gender: String
    let dayMaster: String
    /// 年支生肖英文 asset 名(2026-09-25 暗色走查 #11:命主行头像与「我的」tab 统一
    /// 为生肖线稿;nil = 年柱歧义/decode 不到,视图层 resolve 成墨点,不猜)。
    /// 存原始数据而非派生 mode——ArchivedChart 是 Hashable,ZodiacAvatarMode 不是;
    /// 且三态判定本就属渲染层(单一事实源 ZodiacAvatarMode.resolve)。
    /// 默认 nil:测试的最小构造(与头像无关的 VM 逻辑)免重复样板
    /// (var + 默认值才进 memberwise init 的可选参数;let 常量默认值会被排除)。
    var yearBranchZodiac: String? = nil
    let snapshot: ChartSnapshot

    var id: String { snapshotHash }
}

/// errorDescription 是**用户可见文案**(2026-08-16:代码性错误不进 UI)。
/// hash 留在 associated value,throw 点已记 missing_snapshot 日志。
enum CompatibilityViewModelError: LocalizedError {
    case archivedSnapshotMissing(hash: String)

    var errorDescription: String? {
        switch self {
        case .archivedSnapshotMissing:
            return String(localized: "命盘数据异常,请重新排盘")
        }
    }
}

/// App 模块内共享的安全下标。
///
/// 注:Swift 无法把 extension 限定到「仅本文件/仅某些 Array」，
/// 此扩展在 App target 内对所有 Array 生效（internal，不出模块）。
/// 若后续拆 SDK 需收窄，改用 wrapper 类型或 free function。
internal extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
