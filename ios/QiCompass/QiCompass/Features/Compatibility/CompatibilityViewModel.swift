import Foundation
import SwiftUI
import SwiftData

// MARK: - 状态机

/// 合盘主状态机(决策 D2 + 多选改造 D10)。
///
/// 七态(多选改造后):
/// - loading:命盘列表加载中
/// - empty:0 存档,引导去深度解析
/// - configuring:配置态(A 单选 + B 名单 + context)
/// - computing(completed, total):批量确定性合盘进行中(决策 D3 串行)
/// - list([PairSummary]):结果列表(决策 D9 每对方一张卡)
/// - ready(response, interpretState):旧 1 对 1 详情态(S01 后无新代码进入;S02 改 detail)
/// - failed(message):显式错误(S01 整体级;S03 后仅系统级)
enum CompatibilityViewState: Equatable {
    case loading
    case empty
    case configuring
    case computing(completed: Int, total: Int)
    case list([PairSummary])
    case ready(CompatibilityResponse, InterpretState)
    case failed(UserFacingError)

    static func == (lhs: CompatibilityViewState, rhs: CompatibilityViewState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading): return true
        case (.empty, .empty): return true
        case (.configuring, .configuring): return true
        case (.computing(let c1, let t1), .computing(let c2, let t2)):
            return c1 == c2 && t1 == t2
        case (.list(let a), .list(let b)):
            // PairSummary 用 id 作相等性代理(完整比较太重)
            return a.map(\.id) == b.map(\.id)
        case (.failed(let a), .failed(let b)): return a == b
        case (.ready(let a1, let a2), .ready(let b1, let b2)):
            // response 用 compatibilityHash 作相等性代理(完整比较太重)
            return a1.compatibilityHash == b1.compatibilityHash && a2 == b2
        default: return false
        }
    }
}

// MARK: - ViewModel

/// 合盘 ViewModel:@Observable + 状态机驱动(多选改造)。
///
/// 多选核心:
/// - `roster: [RosterEntry]`(决策 D2 混合名单,上限 8)
/// - `compute()` 串行批量调 orchestrator.runDeterministic(决策 D3)
/// - 单对失败 → 整体 failed(S01 现状语义);S03 改对级隔离
/// - 临时人隐式落地 ChartSnapshot **不建 UserSnapshotLink**(红线 D6)
///
/// 错误显式传播:名单校验失败、快照 upsert 失败照常 throw / 上抛,不用默认值掩盖。
@Observable
@MainActor
final class CompatibilityViewModel {

    // MARK: 配置字段

    /// 已存档命盘列表(从 UserSnapshotLink + ChartSnapshot 取)
    var archivedCharts: [ArchivedChart] = []
    var selectedChartAIndex: Int = 0

    /// B 名单(决策 D2 混合名单 = 存档勾选 + 临时输入)。
    /// 上限 8 人(`rosterMax`,决策 D2 全局池配套)。
    var roster: [RosterEntry] = []

    /// 单临时人表单(S01 限 1 条,已存在名单中的 temp 会被新添加覆盖)。
    /// S04 扩为多条独立表单。
    var tempBirthDate: Date = Date(timeIntervalSince1970: 638_000_000)
    var tempGender: String = "male"
    var tempSelectedCity: String = "北京"
    var tempUseManualLongitude: Bool = false
    var tempManualLongitude: Double = 116.41

    /// context picker(通用 / 婚姻 / 事业;决策 D8 配置页全局)
    var context: String = "general"

    // MARK: 主状态

    var state: CompatibilityViewState = .loading

    // MARK: 依赖

    private let orchestrator: CompatibilityOrchestrator
    private let chartStore: ChartSnapshotStore
    private let compatibilityStore: CompatibilitySnapshotStore
    private let entitlementStore: EntitlementStore
    private let modelContext: ModelContext

    private var computeTask: Task<Void, Never>?
    private var interpretTask: Task<Void, Never>?

    /// 阶段 1 完成后的元数据(供阶段 2 / UI 使用)。
    /// 多选改造后:这些字段只在 S02 详情态按对使用,届时会按对化。
    /// S01 阶段 compute() 走 list 路径,不进入 ready,故这些字段保持初始值。
    private var lastCompatibilityHash: String?
    private var lastBChartSnapshot: ChartSnapshot?
    private var lastIsSnapshotNew: Bool = false

    /// M4:PaywallView 注入用(暴露最近一次合盘 hash 给购买流程绑定 entitlement)。
    /// 多选改造后 S02 会按对化,当前保留 1 对 1 语义(S01 不进入 ready,不会触发)。
    var lastCompatibilityHashForPaywall: String? { lastCompatibilityHash }

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
                let dayMaster = bazi.pillars.day.gan
                charts.append(ArchivedChart(
                    snapshotHash: hash,
                    alias: link.alias,
                    birthDate: snapshot.birthSolarTime,
                    gender: snapshot.gender,
                    dayMaster: dayMaster,
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
            // 不静默吞:错误显式传到 UI
            state = .failed(.generic(message: "读取命盘存档失败:\(error.localizedDescription)"))
        }
    }

    // MARK: - 名单管理(决策 D2 / D11)

    /// 当前 A 盘 hash(候选池排除自己用)。
    var currentPersonAHash: String? {
        archivedCharts[safe: selectedChartAIndex]?.snapshotHash
    }

    /// 名单内已勾选存档 hash 集合(供多选 UI 回显)。
    var selectedArchivedHashes: Set<String> {
        Set(roster.compactMap { entry -> String? in
            if case .archived(let hash) = entry { return hash }
            return nil
        })
    }

    /// 名单内是否已有临时人(S01 限 1 条;S04 扩多条后此 helper 改语义或废弃)。
    var hasTempInRoster: Bool {
        roster.contains { $0.isTemp }
    }

    /// 勾选 / 取消勾选存档对方。
    /// - 排除 A 盘自己(决策 D1:A 盘保持单选,自己不可入名单)
    /// - 上限校验:加入时若已达 `rosterMax` 静默拒绝(UI 应提前 disable)
    func toggleArchived(hash: String) {
        if let idx = roster.firstIndex(where: { $0.archivedSnapshotHash == hash }) {
            roster.remove(at: idx)
            return
        }
        guard hash != currentPersonAHash else {
            AppLogger.app.warning("op=compatibility.toggleArchived skip reason=is_person_a hash=\(hash, privacy: .public)")
            return
        }
        guard roster.count < Self.rosterMax else {
            AppLogger.app.warning("op=compatibility.toggleArchived skip reason=roster_full hash=\(hash, privacy: .public)")
            return
        }
        roster.append(.archived(snapshotHash: hash))
    }

    /// 添加临时对方到名单。
    /// S01 限 1 条:已有临时人则先移除再加入(不抛错,允许用户改输入后覆盖)。
    /// 校验失败抛 `UserFacingError`(不静默吞,CLAUDE.md 错误显式传播)。
    func addTempToRoster() throws {
        try validateTempForm()
        // S01 限 1 条:已有临时人先移除
        roster.removeAll { $0.isTemp }
        guard roster.count < Self.rosterMax else {
            throw UserFacingError.generic(message: "名单已达上限 \(Self.rosterMax) 人")
        }
        let city: String? = tempUseManualLongitude ? nil : tempSelectedCity
        let longitude: Double? = tempUseManualLongitude ? tempManualLongitude : nil
        let input = PersonBInput(
            birthDatetime: tempBirthDate,
            gender: tempGender,
            city: city,
            longitude: longitude
        )
        roster.append(.temp(input: input, alias: nil))
    }

    /// 移除名单一项。
    func removeRosterEntry(_ entry: RosterEntry) {
        roster.removeAll { $0.id == entry.id }
    }

    /// 临时表单校验(不静默吞)。
    /// - 出生时间未来 / 城市 / 经度越界 → 抛 UserFacingError
    private func validateTempForm() throws {
        if tempBirthDate > Date() {
            AppLogger.app.warning("op=compatibility.validateTemp skip reason=b_birth_future")
            throw UserFacingError.generic(message: "B 盘出生时间不能晚于当下")
        }
        if !tempUseManualLongitude && tempSelectedCity.trimmingCharacters(in: .whitespaces).isEmpty {
            AppLogger.app.warning("op=compatibility.validateTemp skip reason=b_city_empty")
            throw UserFacingError.generic(message: "请选择 B 盘城市,或开启手动经度输入")
        }
        if tempUseManualLongitude && !(-180.0...180.0).contains(tempManualLongitude) {
            AppLogger.app.warning("op=compatibility.validateTemp skip reason=b_longitude_out_of_range")
            throw UserFacingError.generic(message: "B 盘经度需在 -180 到 180 之间")
        }
    }

    // MARK: - 批量合盘触发(决策 D3 串行 / D9 list / D13 名单空拦截)

    /// 触发批量合盘:校验名单 → 串行调 orchestrator.runDeterministic → .list 态。
    ///
    /// S01:单对失败 → 整体 failed(沿用现状语义);S03 改对级隔离 + 单对重试。
    /// 切 tab / backToConfig → computeTask cancel(决策 D13)。
    func compute() {
        let contextValue = self.context
        let rosterCount = self.roster.count
        let archivedCount = self.archivedCharts.count
        AppLogger.app.info("compatVM.compute.start roster_count=\(rosterCount, privacy: .public) context=\(contextValue, privacy: .public) archivedCount=\(archivedCount)")

        guard !archivedCharts.isEmpty else {
            AppLogger.app.warning("compatVM.compute.skip reason=empty_archive")
            state = .empty
            return
        }
        guard selectedChartAIndex < archivedCharts.count else {
            AppLogger.app.warning("compatVM.compute.skip reason=a_index_out_of_bounds selectedAIndex=\(self.selectedChartAIndex)")
            state = .failed(.generic(message: "A 盘选择越界,请重新选择"))
            return
        }
        // 决策 D13:名单空校验拦截
        guard !roster.isEmpty else {
            AppLogger.app.warning("compatVM.compute.skip reason=empty_roster")
            state = .failed(.generic(message: "请至少选择一位对方"))
            return
        }

        computeTask?.cancel()
        let total = roster.count
        state = .computing(completed: 0, total: total)

        // 捕获快照避免 Task 内被并发修改
        let chartA = archivedCharts[selectedChartAIndex]
        let rosterSnapshot = roster

        computeTask = Task { [weak self] in
            guard let self else { return }

            // 预解 A payload(每对复用,避免循环内重复 decode)
            let payloadA: ChartPayloadDTO
            do {
                let baziA = try self.chartStore.decodeResponse(from: chartA.snapshot)
                payloadA = ChartPayloadDTO.from(baziResponse: baziA)
            } catch {
                if !Task.isCancelled {
                    self.state = .failed(UserFacingError.from(error, stage: .compatibilityDeterministic))
                }
                return
            }

            var summaries: [PairSummary] = []
            summaries.reserveCapacity(rosterSnapshot.count)

            for (idx, entry) in rosterSnapshot.enumerated() {
                if Task.isCancelled { return }
                do {
                    let summary = try await self.computePair(
                        entry: entry,
                        chartA: chartA,
                        payloadA: payloadA,
                        contextValue: contextValue
                    )
                    summaries.append(summary)
                    if !Task.isCancelled {
                        self.state = .computing(completed: idx + 1, total: total)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if !Task.isCancelled {
                        AppLogger.app.error(
                            "op=compatibility.compute_pair_failed idx=\(idx) error=\(String(describing: error), privacy: .public)"
                        )
                        // S01:单对失败整体 failed(S03 改对级隔离)
                        self.state = .failed(UserFacingError.from(error, stage: .compatibilityDeterministic))
                    }
                    return
                }
            }

            if !Task.isCancelled {
                AppLogger.app.info("compatVM.compute.ok pairs=\(summaries.count, privacy: .public)")
                self.state = .list(summaries)
            }
        }
    }

    /// 计算单对并构造 PairSummary。
    /// - 模式 A:存档对方 → 直接解 B snapshot
    /// - 模式 B:临时对方 → 后端隐式落地后取回 B snapshot
    private func computePair(
        entry: RosterEntry,
        chartA: ArchivedChart,
        payloadA: ChartPayloadDTO,
        contextValue: String
    ) async throws -> PairSummary {
        let request: CompatibilityRequest
        var bSnapshotForUI: ChartSnapshot?

        switch entry {
        case .archived(let bHash):
            guard let bChart = archivedCharts.first(where: { $0.snapshotHash == bHash }) else {
                throw UserFacingError.generic(message: "B 盘存档已不存在,请重新选择")
            }
            let baziB = try chartStore.decodeResponse(from: bChart.snapshot)
            let payloadB = ChartPayloadDTO.from(baziResponse: baziB)
            request = CompatibilityRequest(
                personAHash: chartA.snapshotHash,
                personBHash: bChart.snapshotHash,
                chartPayloadA: payloadA,
                chartPayloadB: payloadB,
                context: contextValue
            )
            bSnapshotForUI = bChart.snapshot

        case .temp(let input, _):
            request = CompatibilityRequest(
                personAHash: chartA.snapshotHash,
                personB: input,
                chartPayloadA: payloadA,
                context: contextValue
            )
            bSnapshotForUI = nil
        }

        let result = try await orchestrator.runDeterministic(
            request: request,
            personAHash: chartA.snapshotHash
        )

        // 模式 B:B snapshot 是新隐式落地的,从 chartStore 取回
        if bSnapshotForUI == nil {
            bSnapshotForUI = try chartStore.get(contentHash: result.personBHash)
            // 不静默吞:刚隐式落地的 B snapshot 取不回说明持久化失败,
            // 该对无法构造卡片,显式抛错让上层进入对级失败(S01 走整体 failed;S03 隔离)。
            if bSnapshotForUI == nil {
                throw UserFacingError.generic(message: "B 盘隐式落地后取回失败,请重试")
            }
        }
        guard let bSnapshot = bSnapshotForUI else {
            throw UserFacingError.generic(message: "B 盘快照缺失")
        }

        let baziB = try chartStore.decodeResponse(from: bSnapshot)
        let dayMaster = baziB.pillars.day.gan

        // 显示名(存档 = alias;临时 = alias 或「对方」—— S04 兜底名扩为「对方+出生日期」)
        let displayName: String
        switch entry {
        case .archived(let bHash):
            displayName = archivedCharts.first { $0.snapshotHash == bHash }?.alias ?? "对方"
        case .temp(_, let alias):
            displayName = alias?.isEmpty == false ? alias! : "对方"
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
            isInterpreted: isInterpreted
        )
    }

    // MARK: - AI 合盘解读(旧 1 对 1 路径,多选改造后由 S02 按对化)

    /// 触发 AI 解读:用户点「生成合盘解读」。
    /// 多选改造后由 S02 在 detail 态按对触发;当前 S01 不进入 ready,此方法不会被调用。
    func generateInterpretation() {
        guard case .ready(let response, _) = state else {
            // 不静默吞(CLAUDE.md 全局约束):UI 收到点击说明状态机错乱,显式记录
            AppLogger.app.error("op=compatibility.generateInterpretation invalid_state state=\(String(describing: self.state), privacy: .public)")
            return
        }
        guard let compatHash = lastCompatibilityHash else {
            state = .ready(response, .failed(message: "合盘缓存键缺失,请重新合盘"))
            return
        }
        guard let chartASnapshot = archivedCharts[safe: selectedChartAIndex]?.snapshot,
              let bSnapshot = lastBChartSnapshot else {
            state = .ready(response, .failed(message: "命盘快照缺失,请重新合盘"))
            return
        }

        // M4 新增:查本地 entitlement 决定 module(基础名 "compatibility")
        let hasEntitlement = entitlementStore.getActive(
            contentHash: compatHash,
            module: EntitlementModule.compatibility,
            userLocalId: UserIdentity.userLocalId
        ) != nil
        let module = hasEntitlement ? "compatibility_paid" : "compatibility_free"
        // 规则 2:用户主动触发 + 付费分支决策日志
        AppLogger.app.info("compatVM.generateInterpretation.start compatibilityHash=\(compatHash, privacy: .public) module=\(module, privacy: .public) hasEntitlement=\(hasEntitlement, privacy: .public)")

        interpretTask?.cancel()
        state = .ready(response, .fetching)

        interpretTask = Task {
            do {
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

                let resp = try await orchestrator.runInterpretation(
                    compatibilityHash: compatHash,
                    chartA: chartA,
                    chartB: chartB,
                    assessment: response.qualitativeAssessment,
                    syncedFortune: response.syncedFortune,
                    context: context,
                    module: module
                )

                if !Task.isCancelled {
                    if hasEntitlement {
                        state = .ready(
                            response,
                            .okPaid(text: resp.interpretation, cached: resp.cached)
                        )
                    } else {
                        state = .ready(
                            response,
                            .okFree(text: resp.interpretation, cached: resp.cached)
                        )
                    }
                }
            } catch let error as CompatibilityError {
                if !Task.isCancelled {
                    state = .ready(response, .failed(message: error.errorDescription ?? "未知错误"))
                }
            } catch let error as DeepAnalysisError {
                if !Task.isCancelled {
                    // dailyLimitReached 独立形态(方案 step 4):禁用生成按钮、不显示重试
                    if case .dailyLimitReached(let reset, _) = error {
                        state = .ready(response, .dailyLimitReached(nextReset: reset))
                    } else {
                        state = .ready(response, .failed(message: error.errorDescription ?? "未知错误"))
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
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

    // MARK: - 重置

    /// 从结果态切回配置态(顶部「修改名单」 toolbar / detail 返回)。
    /// 兼容三种结果态:ready(旧)/ list(新)/ computing(中断)。
    func backToConfig() {
        computeTask?.cancel()
        interpretTask?.cancel()
        state = .configuring
    }

    // MARK: - 查询

    var remainingReads: Int { orchestrator.remainingReads() }
    var nextDailyReset: Date { orchestrator.nextDailyReset() }
    var bChartSnapshot: ChartSnapshot? { lastBChartSnapshot }
    var isSnapshotNew: Bool { lastIsSnapshotNew }

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

    /// ChartSnapshot 城市可读展示(用经度或 cityLongitude 兜底)。
    private func cityDisplay(for snapshot: ChartSnapshot) -> String {
        // ChartSnapshot 不存城市名,只有 cityLongitude。展示经度足够 prompt 使用。
        let lon = snapshot.cityLongitude
        let hemisphere = lon >= 0 ? "东经" : "西经"
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
    let snapshot: ChartSnapshot

    var id: String { snapshotHash }
}

enum CompatibilityViewModelError: LocalizedError {
    case archivedSnapshotMissing(hash: String)

    var errorDescription: String? {
        switch self {
        case .archivedSnapshotMissing(let hash):
            return "命盘存档缺少快照:\(hash)"
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
