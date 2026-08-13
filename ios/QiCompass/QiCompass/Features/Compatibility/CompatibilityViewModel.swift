import Foundation
import SwiftUI
import SwiftData

// MARK: - 状态机

/// 合盘主状态机(多选改造 D10 + S02 detail 态)。
///
/// 七态:
/// - loading:命盘列表加载中
/// - empty:0 存档,引导去深度解析
/// - configuring:配置态(A 单选 + B 名单 + context)
/// - computing(completed, total):批量确定性合盘进行中(决策 D3 串行)
/// - list:结果列表(决策 D9 卡片;summaries 存 VM 字段,便于 detail ↔ list 切换)
/// - detail(summary, response, interpretState):单对详情(S02 新增),复用 CompatibilityMainView
/// - failed(message):显式错误(S01 整体级;S03 后仅系统级)
///
/// `.list` 不内嵌 summaries:summaries 存 VM 字段,detail 返回 list 时无需重新构造。
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

// MARK: - ViewModel

/// 合盘 ViewModel:@Observable + 状态机驱动(多选改造 + S02 detail 按对化)。
///
/// 多选 + detail 核心:
/// - `roster: [RosterEntry]`(决策 D2 混合名单,上限 8)
/// - `summaries: [PairSummary]`(list 态用,detail 切换时保留)
/// - `compute()` 串行批量 → list 态
/// - `openDetail(summary)` → detail 态(查 cache + 解 response + 构造 InterpretState)
/// - `generateInterpretation()` 按 detail 态的 summary.compatibilityHash 触发(决策 D3 AI 逐对按需)
/// - 临时人隐式落地 ChartSnapshot **不建 UserSnapshotLink**(红线 D6)
///
/// 错误显式传播:名单校验失败、快照 upsert 失败、cache decode 失败照常 throw / 上抛,不用默认值掩盖。
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

    // MARK: 主状态 + summaries

    var state: CompatibilityViewState = .loading

    /// list 态的卡片摘要(也用于 detail 返回 list 时恢复)。
    /// 进入 detail 时不清空,closeDetail 后仍可用。
    var summaries: [PairSummary] = []

    // MARK: 依赖

    private let orchestrator: CompatibilityOrchestrator
    private let chartStore: ChartSnapshotStore
    private let compatibilityStore: CompatibilitySnapshotStore
    private let entitlementStore: EntitlementStore
    private let modelContext: ModelContext

    private var computeTask: Task<Void, Never>?
    private var interpretTask: Task<Void, Never>?
    /// detail 态进入时的 cache 查询 task(完成后续刷新 interpretState)。
    private var cacheReadTask: Task<Void, Never>?

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

            var newSummaries: [PairSummary] = []
            newSummaries.reserveCapacity(rosterSnapshot.count)

            for (idx, entry) in rosterSnapshot.enumerated() {
                if Task.isCancelled { return }
                do {
                    let summary = try await self.computePair(
                        entry: entry,
                        chartA: chartA,
                        payloadA: payloadA,
                        contextValue: contextValue
                    )
                    newSummaries.append(summary)
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
                AppLogger.app.info("compatVM.compute.ok pairs=\(newSummaries.count, privacy: .public)")
                self.summaries = newSummaries
                self.state = .list
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
            // 进入 detail 但 interpretState 显式错误(不静默吞)
            let response = Self.fallbackResponse(for: summary)
            state = .detail(summary, response, .failed(message: "读取合盘快照失败:\(error.localizedDescription)"))
            return
        }
        guard let snapshot = compatSnapshot else {
            // 不静默吞:快照缺失(理论上不会发生,compute() 刚 upsert 过)
            AppLogger.app.error("op=compatibility.openDetail missing_snapshot hash=\(summary.compatibilityHash, privacy: .public)")
            let response = Self.fallbackResponse(for: summary)
            state = .detail(summary, response, .failed(message: "合盘快照缺失,请重新合盘"))
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
                calcRuleSnapshot: nil
            )
            state = .detail(summary, response, .idle)
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.openDetail decode_failed hash=\(summary.compatibilityHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            let response = Self.fallbackResponse(for: summary)
            state = .detail(summary, response, .failed(message: "合盘数据解码失败:\(error.localizedDescription)"))
            return
        }

        // 后台查 24h AI 缓存(命中 → interpretState 刷新为 .okFree/.okPaid cached:true)
        cacheReadTask?.cancel()
        let summaryHash = summary.compatibilityHash
        cacheReadTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let cached = try await self.orchestrator.cachedInterpretationIfFresh(
                    compatibilityHash: summaryHash
                ) {
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
                }
            } catch CompatibilityError.forbiddenWordsHit {
                guard case .detail(let currentSummary, let response, _) = self.state,
                      currentSummary.id == summary.id else { return }
                if !Task.isCancelled {
                    self.state = .detail(currentSummary, response, .failed(message: "解读包含不合规绝对结论,请重试"))
                }
            } catch is CancellationError {
                return
            } catch {
                AppLogger.persistence.error(
                    "op=compatibility.openDetail cache_read_failed hash=\(summaryHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                // 缓存读失败不阻塞 detail 态(用户可手动触发 AI 解读)
            }
        }
    }

    /// 返回 list 态(保留 summaries)。
    func closeDetail() {
        cacheReadTask?.cancel()
        interpretTask?.cancel()
        state = .list
    }

    // MARK: - AI 合盘解读(按对触发,决策 D3)

    /// 触发该对 AI 解读(只对 detail 态当前对生效)。
    /// 购买成功后由 PaywallView onPurchaseSuccess 调用,亦按当前 detail 态对触发。
    func generateInterpretation() {
        guard case .detail(let summary, let response, _) = state else {
            // 不静默吞(CLAUDE.md 全局约束):UI 收到点击说明状态机错乱,显式记录
            AppLogger.app.error("op=compatibility.generateInterpretation invalid_state state=\(String(describing: self.state), privacy: .public)")
            return
        }
        let compatHash = summary.compatibilityHash
        guard let chartASnapshot = archivedCharts[safe: selectedChartAIndex]?.snapshot,
              let bSnapshot = try? chartStore.get(contentHash: summary.personBHash) else {
            state = .detail(summary, response, .failed(message: "命盘快照缺失,请重新合盘"))
            return
        }

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
        state = .detail(summary, response, .fetching)

        interpretTask = Task { [weak self] in
            guard let self else { return }
            do {
                let baziA = try self.chartStore.decodeResponse(from: chartASnapshot)
                let baziB = try self.chartStore.decodeResponse(from: bSnapshot)
                let chartA = PromptContextBuilder.chartContext(
                    from: baziA,
                    gender: chartASnapshot.gender,
                    cityDisplay: self.cityDisplay(for: chartASnapshot)
                )
                let chartB = PromptContextBuilder.chartContext(
                    from: baziB,
                    gender: bSnapshot.gender,
                    cityDisplay: self.cityDisplay(for: bSnapshot)
                )

                let resp = try await self.orchestrator.runInterpretation(
                    compatibilityHash: compatHash,
                    chartA: chartA,
                    chartB: chartB,
                    assessment: response.qualitativeAssessment,
                    syncedFortune: response.syncedFortune,
                    context: self.context,
                    module: module
                )

                if Task.isCancelled { return }

                let newState: InterpretState = hasEntitlement
                    ? .okPaid(text: resp.interpretation, cached: resp.cached)
                    : .okFree(text: resp.interpretation, cached: resp.cached)
                self.state = .detail(summary, response, newState)

                // 解读成功 → 同步刷新 summaries 中该对的 isInterpreted
                // (返回 list 时卡片立刻显示「已解读」标记)
                self.markSummaryInterpreted(id: summary.id)
            } catch let error as CompatibilityError {
                if !Task.isCancelled {
                    self.state = .detail(summary, response, .failed(message: error.errorDescription ?? "未知错误"))
                }
            } catch let error as DeepAnalysisError {
                if !Task.isCancelled {
                    if case .dailyLimitReached(let reset, _) = error {
                        self.state = .detail(summary, response, .dailyLimitReached(nextReset: reset))
                    } else {
                        self.state = .detail(summary, response, .failed(message: error.errorDescription ?? "未知错误"))
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    let userError = UserFacingError.from(error, stage: .interpret)
                    if case .dailyLimitReached(let reset) = userError {
                        self.state = .detail(summary, response, .dailyLimitReached(nextReset: reset))
                    } else {
                        self.state = .detail(summary, response, .failed(message: userError.errorDescription ?? "未知错误"))
                    }
                }
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
            isInterpreted: true
        )
    }

    // MARK: - 重置

    /// 从 list 态切回配置态(顶部「修改名单」toolbar)。
    /// 兼容 detail(detail → list → config 两步,用户单按钮直达 config)。
    func backToConfig() {
        computeTask?.cancel()
        interpretTask?.cancel()
        cacheReadTask?.cancel()
        state = .configuring
    }

    // MARK: - 查询(detail 态用)

    var remainingReads: Int { orchestrator.remainingReads() }
    var nextDailyReset: Date { orchestrator.nextDailyReset() }

    /// 当前 detail 态的 B 盘 ChartSnapshot(供 CompatibilityMainView 渲染双盘对比)。
    /// 非 detail 态 / snapshot 缺失返回 nil(UI 显式提示)。
    var currentDetailBSnapshot: ChartSnapshot? {
        guard case .detail(let summary, _, _) = state else { return nil }
        return try? chartStore.get(contentHash: summary.personBHash)
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
