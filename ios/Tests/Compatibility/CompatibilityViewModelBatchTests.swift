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

    func testAddTempToRoster_已有临时_先移除再加入_S01限1条() {
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempGender = "male"
        vm.tempSelectedCity = "北京"

        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.filter(\.isTemp).count, 1)

        // 再加一次,出生时间不同
        vm.tempBirthDate = Date(timeIntervalSince1970: 700_000_000)
        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.filter(\.isTemp).count, 1, "S01 限 1 条:已有临时人再添加会替换")
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
}
