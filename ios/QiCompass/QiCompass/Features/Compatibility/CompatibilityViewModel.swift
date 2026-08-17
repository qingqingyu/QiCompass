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

    /// 单临时人表单(S04 草稿态:每次「添加」push 一条 .temp 到 roster,然后表单清空)。
    /// 多条独立 .temp 在 roster 内互不干扰。
    /// 默认值单一事实源:`CompatibilityRosterPersistence.defaultTempDraft`(VM init 会用持久化草稿覆盖)。
    var tempBirthDate: Date = CompatibilityRosterPersistence.defaultTempDraft.birthDate
    var tempGender: String = CompatibilityRosterPersistence.defaultTempDraft.gender
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

    /// 临时人钟面 → 裸钟面字符串(S02 契约;城市/自定义地点时区,S05)。
    private func tempWallTimeString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = tempPlaceCalendar.timeZone
        return formatter.string(from: tempBirthDate)
    }

    /// context picker(通用 / 婚姻 / 事业;决策 D8 配置页全局)
    var context: String = "general"

    // MARK: 主状态 + summaries

    var state: CompatibilityViewState = .loading

    /// list 态的卡片摘要(也用于 detail 返回 list 时恢复)。
    /// 进入 detail 时不清空,closeDetail 后仍可用。
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
            // 不静默吞:错误显式传到 UI(人话文案,原始 error 已记上方日志)
            state = .failed(.generic(message: "读取命盘存档失败,请重试"))
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

    /// 名单内是否已有临时人(S04 后多条,此处仅用于 UI 展示提示)。
    var hasTempInRoster: Bool {
        roster.contains { $0.isTemp }
    }

    /// 名单内临时人数量(S04 后多条)。
    var tempCountInRoster: Int {
        roster.filter(\.isTemp).count
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

    /// 添加临时对方到名单(S04:多条,每次 append 一条独立 .temp)。
    /// 校验失败抛 `UserFacingError`(不静默吞,CLAUDE.md 错误显式传播)。
    /// 成功后:写入 tempDraft 持久化 + 重置表单为"上次填过的"(alias 清空)。
    func addTempToRoster() throws {
        try validateTempForm()
        guard roster.count < Self.rosterMax else {
            throw UserFacingError.generic(message: "名单已达上限 \(Self.rosterMax) 人")
        }
        // 出生地字段解析走单一事实源(S05:城市/自定义地点;validateTempForm 已保证非空)
        guard let place = tempPlace else {
            throw UserFacingError.generic(message: "请选择出生城市")
        }
        let resolved = BirthPlaceResolver.resolve(place)
        let input = PersonBInput(
            birthDatetime: tempWallTimeString(),
            timezone: resolved.timezone,
            gender: tempGender,
            longitude: resolved.longitude,
            latitude: resolved.latitude,
            placeName: resolved.placeName,
            geonameId: resolved.geonameId
        )
        // alias 空字符串视为 nil(统一兜底名判定)
        let alias = tempAlias.trimmingCharacters(in: .whitespaces)
        let newEntry: RosterEntry = .temp(input: input, alias: alias.isEmpty ? nil : alias, resolvedHash: nil)
        // 去重:同 id entry 已在 roster → 抛错
        // 避免 ForEach 重复 id 警告 + 列表少卡 + 冗余 API 调用(内容寻址 → 同 hash)
        if roster.contains(where: { $0.id == newEntry.id }) {
            AppLogger.app.warning("op=compatibility.addTempToRoster skip reason=duplicate entry_id=\(newEntry.id, privacy: .public)")
            throw UserFacingError.generic(message: "名单已存在相同的对方")
        }
        // UX:保存当前字段为草稿(下次添加时默认值用这次的,加多个临时人时只改称呼/时间)
        CompatibilityRosterPersistence.saveTempDraft(
            .init(
                birthDate: tempBirthDate,
                gender: tempGender,
                place: tempPlace
            )
        )
        roster.append(newEntry)
    }

    /// 添加成功后由 View 调:重置表单为"上次填过的"(本次刚保存的草稿)。
    /// alias 不持久化,每次清空(避免连续加多个相同 alias 触发去重)。
    func resetTempDraftForm() {
        applyTempDraft(CompatibilityRosterPersistence.loadTempDraft())
        tempAlias = ""
    }

    /// 把草稿字段回填临时表单(init 与 resetTempDraftForm 共用;alias 不在内,永远单独处理)。
    private func applyTempDraft(_ draft: CompatibilityRosterPersistence.TempDraftState) {
        tempBirthDate = draft.birthDate
        tempGender = draft.gender
        tempPlace = draft.place
    }

    /// 移除名单一项。
    func removeRosterEntry(_ entry: RosterEntry) {
        roster.removeAll { $0.id == entry.id }
    }

    /// 临时表单校验(不静默吞)。
    /// - 出生时间未来 / 未选地点 / 自定义经度越界 → 抛 UserFacingError
    private func validateTempForm() throws {
        if tempBirthDate > Date() {
            AppLogger.app.warning("op=compatibility.validateTemp skip reason=b_birth_future")
            throw UserFacingError.generic(message: "B 盘出生时间不能晚于当下")
        }
        if tempPlace == nil {
            AppLogger.app.warning("op=compatibility.validateTemp skip reason=b_place_empty")
            throw UserFacingError.generic(message: "请选择出生城市,或在搜索页底部自定义地点")
        }
        if let tempPlace, !tempPlace.isCustomLongitudeValid {
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
                self.state = .list
                // S06:持久化 A / context / 名单 hash(compute() 成功后)
                self.persistRosterState(summaries: newSummaries)
            }
        }
    }

    // MARK: - S06 跨启动持久化与恢复

    /// 写入 UserDefaults(决策 D5)。
    /// 名单 hash 来自 summaries 的 personBHash(临时人已用 resolvedHash)。
    private func persistRosterState(summaries: [PairSummary]) {
        let aHash = currentPersonAHash ?? ""
        let hashes = summaries
            .filter(\.isComputed)
            .map(\.personBHash)
            .filter { !$0.isEmpty }
        CompatibilityRosterPersistence.save(
            personAHash: aHash,
            context: context,
            rosterHashes: hashes
        )
    }

    /// S06:跨启动恢复名单 + A + context(决策 D5/D8/D11/D13)。
    /// 调用时机:`loadArchivedCharts()` 完成后,0 存档外(进 .configuring 态时)。
    ///
    /// 流程:
    /// 1. 读持久化(context / aHash / rosterHashes)
    /// 2. 预填 context(默认 "general")
    /// 3. A hash 失效 fallback 最新 link(D13)
    /// 4. 名单 hash 清理无效项(D5 防脏数据;D6 红线:不转 link)
    /// 5. 名单非空 → 尝试恢复 list 态(零 API 调用)
    func restoreRosterStateIfAvailable() {
        guard !archivedCharts.isEmpty else { return }  // 0 存档走 .empty,不恢复

        let persisted = CompatibilityRosterPersistence.load()

        // 1. context
        context = persisted.context

        // 2. A hash 失效则 fallback 最新 link(D13)
        if let aHash = persisted.personAHash,
           let idx = archivedCharts.firstIndex(where: { $0.snapshotHash == aHash }) {
            selectedChartAIndex = idx
        } else {
            // 持久化 A 失效或未存 → fallback 最新 link(archivedCharts 已 createdAt DESC)
            if persisted.personAHash != nil {
                AppLogger.app.warning(
                    "op=compatibility.restore.a_hash_invalid fallback to latest link a_hash=\(persisted.personAHash ?? "nil", privacy: .public)"
                )
            }
            selectedChartAIndex = 0
        }

        // 3. 名单 hash 清理 + 预填(D5 防脏数据 + D6 不转 link)
        let validHashes = CompatibilityRosterPersistence.cleanupInvalidHashes(
            persistedHashes: persisted.rosterHashes
        ) { hash in
            // 校验:ChartSnapshot 存在(无论是否有 link,临时人隐式落地的 snapshot 也算)
            (try? self.chartStore.get(contentHash: hash)) != nil
        }
        roster = validHashes.map { .archived(snapshotHash: $0) }

        AppLogger.app.info(
            "op=compatibility.restore.ok a_hash=\(self.currentPersonAHash ?? "nil", privacy: .public) context=\(self.context, privacy: .public) roster_count=\(self.roster.count, privacy: .public)"
        )

        // 4. 名单非空 → 尝试恢复 list 态(零 API 调用)
        if !roster.isEmpty {
            tryRestoreList()
        }
    }

    /// S06:从 store.list(A, context) ∩ 名单 恢复 summaries + .list 态(零 API 调用)。
    /// 失败不静默吞:decode 失败的 snapshot 跳过该对(其他对仍恢复);list 查询失败保留 .configuring。
    private func tryRestoreList() {
        guard let aHash = currentPersonAHash else { return }
        do {
            let snapshots = try compatibilityStore.list(personAHash: aHash, context: context)
            // 名单过滤(D5 核心:删掉的对方不从快照库「复活」)
            let rosterHashes = Set(roster.compactMap { $0.resolvedContentHash })
            let filteredSnapshots = snapshots.filter { rosterHashes.contains($0.personBHash) }

            if filteredSnapshots.isEmpty { return }

            var restoredSummaries: [PairSummary] = []
            for snapshot in filteredSnapshots {
                // 跨启动恢复:entry 都是 .archived(snapshotHash:)(临时人持久化为 hash)
                // rebuildSummaryFromCache 内 displayName 会自动 fallback 兜底名
                let entry: RosterEntry = .archived(snapshotHash: snapshot.personBHash)
                do {
                    let summary = try rebuildSummaryFromCache(
                        entry: entry,
                        bHash: snapshot.personBHash,
                        snapshot: snapshot
                    )
                    restoredSummaries.append(summary)
                } catch {
                    AppLogger.persistence.error(
                        "op=compatibility.tryRestoreList.decode_failed hash=\(snapshot.compatibilityHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                    )
                    // 不静默吞:跳过该对,继续恢复其他对
                }
            }

            if !restoredSummaries.isEmpty {
                summaries = restoredSummaries
                state = .list
                AppLogger.app.info(
                    "op=compatibility.tryRestoreList.ok restored_count=\(restoredSummaries.count, privacy: .public) zero_api=true"
                )
            }
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.tryRestoreList.list_query_failed a_hash=\(aHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            // 不静默吞:保留 configuring 态,用户可手动重新计算
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
                let payloadA = ChartPayloadDTO.from(baziResponse: baziA)
                let newSummary = try await self.computePair(
                    entry: entry,
                    chartA: chartA,
                    payloadA: payloadA,
                    contextValue: contextValue
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
            displayName = archivedCharts.first { $0.snapshotHash == bHash }?.alias ?? "对方"
        case .temp(let input, let alias, _):
            if let alias, !alias.isEmpty {
                displayName = alias
            } else {
                // S04 兜底名:birthDatetime 已是裸钟面字符串,直接读(出生地钟面)
                displayName = "对方 · \(input.wallClockDisplay)"
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

    /// S04:回填临时人 resolvedHash 到 roster 内对应 entry(为 S05 增量预查 / S06 持久化铺路)。
    /// 用 input + alias 定位(id 不变 → ForEach 不重建)。
    private func backfillTempResolvedHash(input: PersonBInput, alias: String?, resolvedHash: String) {
        guard let idx = roster.firstIndex(where: { entry in
            if case .temp(let existingInput, let existingAlias, _) = entry,
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
        roster[idx] = .temp(input: input, alias: alias, resolvedHash: resolvedHash)
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
            throw UserFacingError.generic(message: "对方命盘快照缺失,请重新选择")
        }
        let baziB = try chartStore.decodeResponse(from: bChartSnapshot)
        let dayMaster = baziB.pillars.day.gan

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
                displayName = "对方 · \(dateStr)"
            }
        case .temp(_, let alias, _):
            if let alias, !alias.isEmpty {
                displayName = alias
            } else {
                let dateStr = Self.fallbackDateString(bChartSnapshot.birthSolarTime,
                                                      timezoneName: bChartSnapshot.cityTimezone)
                displayName = "对方 · \(dateStr)"
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
    private func computePair(
        entry: RosterEntry,
        chartA: ArchivedChart,
        payloadA: ChartPayloadDTO,
        contextValue: String
    ) async throws -> PairSummary {
        let aHash = chartA.snapshotHash

        // S05 增量预查(决策 D7):有 resolvedHash 时本地查 canonicalKey 命中跳过 API
        if let bHash = entry.resolvedContentHash {
            let canonicalKey = CompatibilitySnapshotStore.canonicalKey(
                aHash: aHash, bHash: bHash, context: contextValue
            )
            do {
                if let existing = try compatibilityStore.get(compatibilityHash: canonicalKey) {
                    AppLogger.app.info(
                        "op=compatibility.computePair.cache_hit canonicalKey=\(canonicalKey, privacy: .public) entry_id=\(entry.id, privacy: .public)"
                    )
                    return try rebuildSummaryFromCache(
                        entry: entry,
                        bHash: bHash,
                        snapshot: existing
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
                throw UserFacingError.generic(message: "B 盘存档已不存在,请重新选择")
            }
            let baziB = try chartStore.decodeResponse(from: bChart.snapshot)
            let payloadB = ChartPayloadDTO.from(baziResponse: baziB)
            request = CompatibilityRequest(
                personAHash: aHash,
                personBHash: bChart.snapshotHash,
                chartPayloadA: payloadA,
                chartPayloadB: payloadB,
                context: contextValue
            )
            bSnapshotForUI = bChart.snapshot

        case .temp(let input, _, _):
            request = CompatibilityRequest(
                personAHash: aHash,
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

        // 显示名(存档 = alias;临时 = alias 或「对方+出生日期」—— S04 兜底名策略)
        let displayName: String
        switch entry {
        case .archived(let bHash):
            displayName = archivedCharts.first { $0.snapshotHash == bHash }?.alias ?? "对方"
        case .temp(_, let alias, _):
            if let alias, !alias.isEmpty {
                displayName = alias
            } else {
                // S04 兜底名:「对方+出生日期」(按出生城市时区格式化真太阳时)
                let dateStr = Self.fallbackDateString(bSnapshot.birthSolarTime,
                                                      timezoneName: bSnapshot.cityTimezone)
                displayName = "对方 · \(dateStr)"
            }
        }

        // S04:临时人首次计算后回填 resolvedHash 到 roster(为 S05 增量预查 / S06 持久化铺路)
        if case .temp(let input, let alias, _) = entry {
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
            state = .detail(summary, response, .failed(message: "读取合盘数据失败,请重试"))
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
            state = .detail(summary, response, .failed(message: "合盘数据异常,请重新计算"))
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
            isInterpreted: true,
            status: old.status
        )
    }

    // MARK: - 重置

    /// 从 list 态切回配置态(顶部「编辑名单」toolbar)。
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

/// errorDescription 是**用户可见文案**(2026-08-16:代码性错误不进 UI)。
/// hash 留在 associated value,throw 点已记 missing_snapshot 日志。
enum CompatibilityViewModelError: LocalizedError {
    case archivedSnapshotMissing(hash: String)

    var errorDescription: String? {
        switch self {
        case .archivedSnapshotMissing:
            return "命盘数据异常,请重新排盘"
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
