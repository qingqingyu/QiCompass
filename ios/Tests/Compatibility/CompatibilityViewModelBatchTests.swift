import SwiftData
import XCTest
@testable import QiCompass

/// 合盘多选改造 S01 — VM 名单管理 + 名单空拦截 + 上限 8 单元测试。
///
/// 覆盖决策:
/// - D1:A 盘保持单选(自己不可入名单)
/// - D2:名单上限 8(存档勾选 + 临时输入合计)
/// - D6:临时人不建 UserSnapshotLink(本测试断言 roster 内 .temp 不依赖 link)
/// - D13:名单空校验拦截
///
/// **不覆盖**(留后续 slice):
/// - 串行批量调用顺序 / i/N 进度:需 mock orchestrator → 后续提取 protocol
/// - 模式 A/B 请求构造正确性:同上
@MainActor
final class CompatibilityViewModelBatchTests: XCTestCase {

    private var container: ModelContainer!
    private var orchestrator: CompatibilityOrchestrator!
    private var chartStore: ChartSnapshotStore!
    private var compatibilityStore: CompatibilitySnapshotStore!
    private var entitlementStore: EntitlementStore!
    private var vm: CompatibilityViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        chartStore = ChartSnapshotStore(context: context)
        compatibilityStore = CompatibilitySnapshotStore(context: context)
        entitlementStore = EntitlementStore(modelContext: context)
        // Orchestrator 依赖 APIClient 等,本测试不触发 compute() 内的 orchestrator.runDeterministic,
        // 所以注入一个最小可用实例。APIClient 用 MockAPIClient(不会被调用)。
        let apiClient = MockAPIClient()
        let interpretStore = InterpretationCacheStore(context: context)
        let identityResolver = AIIdentityResolver(apiClient: apiClient)
        let counter = DailyReadCounter()
        let reader = CachedInterpretationReader(
            identityResolver: identityResolver,
            cacheStore: interpretStore
        )
        orchestrator = CompatibilityOrchestrator(
            apiClient: apiClient,
            compatibilityStore: compatibilityStore,
            chartStore: chartStore,
            interpretStore: interpretStore,
            counter: counter,
            interpretationReader: reader
        )
        vm = CompatibilityViewModel(
            orchestrator: orchestrator,
            chartStore: chartStore,
            compatibilityStore: compatibilityStore,
            entitlementStore: entitlementStore,
            modelContext: context
        )
    }

    override func tearDownWithError() throws {
        vm = nil
        orchestrator = nil
        chartStore = nil
        compatibilityStore = nil
        entitlementStore = nil
        container = nil
        super.tearDown()
    }

    // MARK: - D2 名单上限 8

    func testRosterMax_常量等于8() {
        XCTAssertEqual(CompatibilityViewModel.rosterMax, 8, "决策 D2 名单上限 = 8(全局池 10/天 配套)")
    }

    // MARK: - toggleArchived(决策 D1 自己不入名单 / D2 上限 8)

    func testToggleArchived_加入并移除() {
        // 模拟 A 盘 = "hash_a",勾选 hash_b
        vm.archivedCharts = [
            Self.makeChart(hash: "hash_a", alias: "A"),
            Self.makeChart(hash: "hash_b", alias: "B"),
        ]
        vm.selectedChartAIndex = 0

        vm.toggleArchived(hash: "hash_b")
        XCTAssertEqual(vm.roster.count, 1)
        XCTAssertTrue(vm.selectedArchivedHashes.contains("hash_b"))

        vm.toggleArchived(hash: "hash_b")
        XCTAssertEqual(vm.roster.count, 0)
        XCTAssertTrue(vm.selectedArchivedHashes.isEmpty)
    }

    func testToggleArchived_排除A盘自己() {
        // 决策 D1 红线:A 盘自己不可入名单
        vm.archivedCharts = [
            Self.makeChart(hash: "hash_a", alias: "A"),
            Self.makeChart(hash: "hash_b", alias: "B"),
        ]
        vm.selectedChartAIndex = 0
        XCTAssertEqual(vm.currentPersonAHash, "hash_a")

        vm.toggleArchived(hash: "hash_a")  // 勾 A 盘自己 → 拒绝
        XCTAssertTrue(vm.roster.isEmpty, "A 盘自己不可入名单")
    }

    func testToggleArchived_上限8_第9个拒绝() {
        vm.archivedCharts = (0..<9).map { Self.makeChart(hash: "h\($0)", alias: "A\($0)") }
        vm.selectedChartAIndex = 0  // A = "h0"

        // 前 8 个(h1..h8)加入,正好达上限
        for i in 1...8 {
            vm.toggleArchived(hash: "h\(i)")
        }
        XCTAssertEqual(vm.roster.count, 8, "上限 8 应允许")

        // 第 9 个(h0 自己也被排除了,这里换 h0 不行,需要再造一个非 A 的)
        vm.archivedCharts.append(Self.makeChart(hash: "h9", alias: "A9"))
        vm.toggleArchived(hash: "h9")
        XCTAssertEqual(vm.roster.count, 8, "第 9 个必须被拒绝(D2 上限)")
    }

    // MARK: - addTempToRoster(S01 限 1 条 / 校验不静默吞)

    func testAddTempToRoster_出生时间未来_抛错() {
        vm.tempBirthDate = Date().addingTimeInterval(60)  // 1 分钟后
        XCTAssertThrowsError(try vm.addTempToRoster()) { error in
            XCTAssertTrue(error.localizedDescription.contains("不能晚于当下"))
        }
        XCTAssertTrue(vm.roster.isEmpty, "校验失败不应入名单")
    }

    func testAddTempToRoster_城市为空_抛错() {
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempSelectedCity = "   "
        vm.tempUseManualLongitude = false
        XCTAssertThrowsError(try vm.addTempToRoster()) { error in
            XCTAssertTrue(error.localizedDescription.contains("B 盘城市"))
        }
    }

    func testAddTempToRoster_经度越界_抛错() {
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempUseManualLongitude = true
        vm.tempManualLongitude = 999.0
        XCTAssertThrowsError(try vm.addTempToRoster()) { error in
            XCTAssertTrue(error.localizedDescription.contains("经度"))
        }
    }

    func testAddTempToRoster_多条独立_不替换_S04改造() {
        // S04 改造:不再替换,而是 append 多条
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempGender = "male"
        vm.tempSelectedCity = "北京"

        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.filter(\.isTemp).count, 1)

        // S04:再加一次,出生时间不同 → 名单内 2 条独立 temp
        vm.tempBirthDate = Date(timeIntervalSince1970: 700_000_000)
        vm.tempSelectedCity = "上海"
        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.filter(\.isTemp).count, 2, "S04 改造:多条独立 temp,不再替换")
    }

    // MARK: - S04 多临时人 + 称呼 + resolvedHash 回填

    func testAddTempToRoster_多条不重复_直到上限8() {
        vm.archivedCharts = [Self.makeChart(hash: "h_a", alias: "A")]
        vm.selectedChartAIndex = 0

        // 加 7 个不同 temp(配合 1 个存档 = 8 满员)
        for i in 0..<7 {
            vm.tempBirthDate = Date(timeIntervalSince1970: TimeInterval(638_000_000 + i * 86400))
            vm.tempSelectedCity = "城市\(i)"
            try? vm.addTempToRoster()
        }
        XCTAssertEqual(vm.tempCountInRoster, 7)
        XCTAssertEqual(vm.roster.count, 7)

        // 第 8 个 temp(总第 8 名额,可加入)
        vm.tempBirthDate = Date(timeIntervalSince1970: 1_000_000_000)
        vm.tempSelectedCity = "城市8"
        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.count, 8)

        // 第 9 个 temp 触发上限
        vm.tempBirthDate = Date(timeIntervalSince1970: 1_100_000_000)
        vm.tempSelectedCity = "城市9"
        XCTAssertThrowsError(try vm.addTempToRoster(), "上限 8 必须拦截第 9 个 temp")
    }

    func testAddTempToRoster_称呼字段_空字符串视为nil() {
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempSelectedCity = "北京"
        vm.tempAlias = "   "  // 全空白
        try? vm.addTempToRoster()

        if case .temp(_, let alias, _) = vm.roster.first(where: { $0.isTemp }) {
            XCTAssertNil(alias, "空白 alias 应被 trim 为 nil(走兜底名策略)")
        } else {
            XCTFail("roster 应有一个 temp")
        }
    }

    func testAddTempToRoster_称呼字段_保留非空值() {
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempSelectedCity = "北京"
        vm.tempAlias = "  相亲对象甲  "  // 带空格
        try? vm.addTempToRoster()

        if case .temp(_, let alias, _) = vm.roster.first(where: { $0.isTemp }) {
            XCTAssertEqual(alias, "相亲对象甲", "alias 应被 trim 保留非空值")
        }
    }

    func testResetTempDraftForm_字段全部重置() {
        // 先污染字段
        vm.tempBirthDate = Date(timeIntervalSince1970: 999_999_999)
        vm.tempGender = "female"
        vm.tempSelectedCity = "测试城市"
        vm.tempUseManualLongitude = true
        vm.tempManualLongitude = 88.88
        vm.tempAlias = "测试"

        vm.resetTempDraftForm()

        XCTAssertEqual(vm.tempBirthDate, Date(timeIntervalSince1970: 638_000_000))
        XCTAssertEqual(vm.tempGender, "male")
        XCTAssertEqual(vm.tempSelectedCity, "北京")
        XCTAssertFalse(vm.tempUseManualLongitude)
        XCTAssertEqual(vm.tempManualLongitude, 116.41)
        XCTAssertEqual(vm.tempAlias, "")
    }

    func testRosterEntry_resolvedHash_默认nil_符合S04契约() {
        // 验证 entry 字段语义,不依赖计算回填(mock orchestrator 留后续)
        let entry: RosterEntry = .temp(
            input: PersonBInput(
                birthDatetime: Date(timeIntervalSince1970: 638_000_000),
                gender: "male",
                city: "北京",
                longitude: nil
            ),
            alias: nil,
            resolvedHash: nil
        )
        XCTAssertNil(entry.resolvedContentHash, "首次输入 resolvedHash 必须为 nil,等计算后回填")
        XCTAssertEqual(entry.tempAlias, nil)
        XCTAssertNotNil(entry.tempInput)
    }

    func testRosterEntry_archived_resolvedHash等于snapshotHash() {
        let entry: RosterEntry = .archived(snapshotHash: "abc123")
        XCTAssertEqual(entry.resolvedContentHash, "abc123", "archived 的 resolvedHash 就是 snapshotHash")
        XCTAssertEqual(entry.archivedSnapshotHash, "abc123")
        XCTAssertNil(entry.tempAlias)
    }

    func testAddTempToRoster_存档加临时_混合名单() {
        // 决策 D2 混合名单 = 存档 + 临时
        vm.archivedCharts = [
            Self.makeChart(hash: "h_a", alias: "A"),
            Self.makeChart(hash: "h_b", alias: "B"),
        ]
        vm.selectedChartAIndex = 0
        vm.toggleArchived(hash: "h_b")

        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempSelectedCity = "上海"
        try? vm.addTempToRoster()

        XCTAssertEqual(vm.roster.count, 2, "混合名单 = 1 存档 + 1 临时")
        XCTAssertEqual(vm.roster.filter { !$0.isTemp }.count, 1)
        XCTAssertEqual(vm.roster.filter(\.isTemp).count, 1)
    }

    // MARK: - removeRosterEntry

    func testRemoveRosterEntry_存档和临时都可移除() {
        vm.archivedCharts = [Self.makeChart(hash: "h_a", alias: "A"), Self.makeChart(hash: "h_b", alias: "B")]
        vm.selectedChartAIndex = 0
        vm.toggleArchived(hash: "h_b")
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempSelectedCity = "北京"
        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.count, 2)

        if let archivedEntry = vm.roster.first(where: { !$0.isTemp }) {
            vm.removeRosterEntry(archivedEntry)
        }
        XCTAssertEqual(vm.roster.count, 1)

        if let tempEntry = vm.roster.first(where: { $0.isTemp }) {
            vm.removeRosterEntry(tempEntry)
        }
        XCTAssertTrue(vm.roster.isEmpty)
    }

    // MARK: - compute() 名单空拦截(决策 D13)

    func testCompute_名单空_进入failed态_不调orchestrator() {
        vm.archivedCharts = [Self.makeChart(hash: "h_a", alias: "A")]
        vm.selectedChartAIndex = 0
        vm.roster = []  // 空名单

        vm.compute()

        if case .failed(let userError) = vm.state {
            XCTAssertTrue(userError.errorDescription?.contains("至少选择一位对方") == true, "空名单拦截文案")
        } else {
            XCTFail("空名单应进入 .failed 态,实际:\(vm.state)")
        }
    }

    func testCompute_0存档_进入empty态() {
        vm.archivedCharts = []
        vm.roster = [.archived(snapshotHash: "h_b")]
        vm.compute()
        if case .empty = vm.state {
            // 期望
        } else {
            XCTFail("0 存档应进入 .empty 态,实际:\(vm.state)")
        }
    }

    // MARK: - S02 detail 态(openDetail / closeDetail / paywall 按对绑定)

    func testLastCompatibilityHashForPaywall_非detail态_返回nil() {
        // S02 红线:paywall 按对绑定 → 非 detail 态无 hash
        vm.state = .configuring
        XCTAssertNil(vm.lastCompatibilityHashForPaywall)
        vm.state = .list
        XCTAssertNil(vm.lastCompatibilityHashForPaywall)
    }

    func testOpenDetail_快照缺失_进入detailFailed态_不静默吞() throws {
        // 不构造 CompatibilitySnapshot → openDetail 走 fallback response + .failed interpretState
        let summary = PairSummary(
            id: "compat_hash_1",
            entry: .archived(snapshotHash: "h_b"),
            personBHash: "h_b",
            displayName: "对方",
            birthDate: nil,
            dayMaster: "甲",
            fiveElements: "互补",
            dayMasterRelation: "同气",
            compatibilityHash: "compat_hash_1",
            isInterpreted: false,
            status: .computed
        )

        vm.openDetail(summary)

        if case .detail(let s, _, let interpret) = vm.state {
            XCTAssertEqual(s.id, "compat_hash_1")
            if case .failed(let msg) = interpret {
                XCTAssertTrue(msg.contains("合盘"), "detail 快照缺失应显式 .failed interpretState")
            } else {
                XCTFail("快照缺失应进入 .failed interpretState,实际:\(interpret)")
            }
        } else {
            XCTFail("openDetail 应进入 .detail 态,实际:\(vm.state)")
        }
    }

    func testOpenDetail_有快照_进入detailIdle态() throws {
        // 构造 CompatibilitySnapshot
        let response = CompatibilityResponse(
            compatibilityHash: "compat_hash_2",
            personAChart: nil,
            personBChart: nil,
            qualitativeAssessment: QualitativeAssessmentDTO(
                fiveElements: "互补佳", dayMasterRelation: "同气",
                zodiacMatch: "六合", branchHarmony: "无冲无刑"
            ),
            syncedFortune: [],
            calcRuleSnapshot: nil
        )
        let snapshot = try insertCompatibilitySnapshot(response: response, aHash: "h_a", bHash: "h_b", context: "general")

        let summary = PairSummary(
            id: snapshot.compatibilityHash,
            entry: .archived(snapshotHash: "h_b"),
            personBHash: "h_b",
            displayName: "对方",
            birthDate: nil,
            dayMaster: "甲",
            fiveElements: "互补佳",
            dayMasterRelation: "同气",
            compatibilityHash: snapshot.compatibilityHash,
            isInterpreted: false,
            status: .computed
        )

        vm.openDetail(summary)

        if case .detail(let s, _, let interpret) = vm.state {
            XCTAssertEqual(s.id, snapshot.compatibilityHash)
            if case .idle = interpret {
                // 期望 idle(后台 cache 查询是 async,本同步断言只看 idle 初始)
            } else {
                XCTFail("快照存在但无 24h cache 时应进入 .idle,实际:\(interpret)")
            }
        } else {
            XCTFail("openDetail 应进入 .detail 态,实际:\(vm.state)")
        }

        // paywall hash 按对化:detail 态返回该对 hash
        XCTAssertEqual(vm.lastCompatibilityHashForPaywall, snapshot.compatibilityHash)
    }

    func testCloseDetail_返回list态_保留summaries() {
        // 先模拟 list 态 + summaries
        let summary = PairSummary(
            id: "compat_hash_3",
            entry: .archived(snapshotHash: "h_b"),
            personBHash: "h_b",
            displayName: "对方",
            birthDate: nil,
            dayMaster: "甲",
            fiveElements: "互补",
            dayMasterRelation: "同气",
            compatibilityHash: "compat_hash_3",
            isInterpreted: false,
            status: .computed
        )
        vm.summaries = [summary]
        vm.state = .list

        vm.openDetail(summary)
        if case .detail = vm.state {
            // 期望进入 detail
        } else {
            XCTFail("应进入 detail 态")
        }

        vm.closeDetail()
        if case .list = vm.state {
            // 期望返回 list
        } else {
            XCTFail("closeDetail 应返回 list 态,实际:\(vm.state)")
        }
        XCTAssertEqual(vm.summaries.count, 1, "closeDetail 后 summaries 应保留")
    }

    // MARK: - S03 对级错误隔离

    func testRetryPair_非failed态_拒绝重试() {
        // computed 态调 retryPair 应跳过
        let summary = PairSummary(
            id: "compat_ok",
            entry: .archived(snapshotHash: "h_b"),
            personBHash: "h_b",
            displayName: "对方",
            birthDate: nil,
            dayMaster: "甲",
            fiveElements: "互补",
            dayMasterRelation: "同气",
            compatibilityHash: "compat_ok",
            isInterpreted: false,
            status: .computed
        )
        vm.summaries = [summary]
        vm.state = .list

        vm.retryPair(summary: summary)
        XCTAssertTrue(vm.retryingIds.isEmpty, "computed 态不应进入重试")
    }

    func testRetryPair_非list态_拒绝重试() {
        let summary = PairSummary(
            id: "failed:h_b",
            entry: .archived(snapshotHash: "h_b"),
            personBHash: "",
            displayName: "对方",
            birthDate: nil,
            dayMaster: "—",
            fiveElements: "",
            dayMasterRelation: "",
            compatibilityHash: "",
            isInterpreted: false,
            status: .failed(.generic(message: "test"))
        )
        vm.state = .configuring  // 非 list
        vm.retryPair(summary: summary)
        XCTAssertTrue(vm.retryingIds.isEmpty, "非 list 态不应进入重试")
    }

    func testMakeFailedSummary_可以通过构造验证字段() {
        // 间接测:retryPair 在非 list 态会失败,但 makeFailedSummary 字段对失败卡片展示是关键
        // 这里直接构造一个 failed summary 验证字段语义
        let entry: RosterEntry = .archived(snapshotHash: "h_b")
        let summary = PairSummary(
            id: "failed:h_b",
            entry: entry,
            personBHash: "",
            displayName: "对方",
            birthDate: nil,
            dayMaster: "—",
            fiveElements: "",
            dayMasterRelation: "",
            compatibilityHash: "",
            isInterpreted: false,
            status: .failed(.networkUnavailable)
        )
        XCTAssertEqual(summary.id, "failed:h_b")
        XCTAssertTrue(summary.isComputed == false)
        if case .failed(let err) = summary.status {
            XCTAssertEqual(err, .networkUnavailable)
        } else {
            XCTFail("status 应为 .failed")
        }
    }

    func testGenerateInterpretation_非detail态_不静默吞() {
        // 状态机错乱调用 → 不静默吞,显式日志(此测试断言不崩)
        vm.state = .configuring
        vm.generateInterpretation()
        // state 不变(避免误进 fetching)
        if case .configuring = vm.state {
            // 期望
        } else {
            XCTFail("非 detail 态调用 generateInterpretation 不应改变 state")
        }
    }

    // MARK: - 辅助

    /// 构造最小 ArchivedChart(只含 hash + alias,够 toggleArchived 用)。
    /// snapshot 字段为 force-unwrap,因 roster 管理测试不触 decode。
    private static func makeChart(hash: String, alias: String) -> ArchivedChart {
        // 用占位 ChartSnapshot(snapshot 不被 roster 管理路径解)
        let placeholder = ChartSnapshot(
            contentHash: hash,
            birthSolarTime: Date(timeIntervalSince1970: 638_000_000),
            gender: "male",
            cityLongitude: 116.41,
            ziHourRule: "zi_next_day",
            calcRuleSnapshot: Data(),
            payload: Data()
        )
        return ArchivedChart(
            snapshotHash: hash,
            alias: alias,
            birthDate: placeholder.birthSolarTime,
            gender: "male",
            dayMaster: "甲",
            snapshot: placeholder
        )
    }

    /// 插入一个 CompatibilitySnapshot(S02 detail 测试用)。
    @discardableResult
    private func insertCompatibilitySnapshot(
        response: CompatibilityResponse,
        aHash: String,
        bHash: String,
        context: String
    ) throws -> CompatibilitySnapshot {
        let result = try compatibilityStore.upsertQualitative(
            response: response,
            personAHash: aHash,
            personBHash: bHash,
            context: context
        )
        return result.snapshot
    }
}
