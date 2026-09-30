import SwiftData
import XCTest
@testable import QiCompass

/// S1 换人入口单测(2026-09-29 结果页主页化 P3):
/// - selectPartner 同人 + .detail → no-op(零 compute 请求)
/// - 换人触发 compute 且单选让位(池行让位移出名单 / 临时人让位保留)
/// - currentPartner 派生正确(存档池行 / 临时人推演前 / 无勾选 nil)
/// - 推演中换人 → 上一次 compute 被 cancel,终态为新对 detail
/// - 勾选被守卫拒收(满员)→ 不发起 compute(不按旧勾选算错人)
@MainActor
final class CompatibilitySelectPartnerTests: XCTestCase {

    private var container: ModelContainer!
    private var chartStore: ChartSnapshotStore!
    private var compatibilityStore: CompatibilitySnapshotStore!
    private var entitlementStore: EntitlementStore!
    private var vm: CompatibilityViewModel!
    /// 记录型 API 双打:no-op 断言依赖「零 compatibility 请求」。
    private var recording: SelectPartnerRecordingAPIClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        CompatibilityRosterPersistence.clear()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        chartStore = ChartSnapshotStore(context: context)
        compatibilityStore = CompatibilitySnapshotStore(context: context)
        entitlementStore = EntitlementStore(modelContext: context)
        recording = SelectPartnerRecordingAPIClient()
        let interpretStore = InterpretationCacheStore(context: context)
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: recording),
            cacheStore: interpretStore
        )
        let orchestrator = CompatibilityOrchestrator(
            apiClient: recording,
            compatibilityStore: compatibilityStore,
            chartStore: chartStore,
            interpretStore: interpretStore,
            counter: DailyReadCounter.makeIsolatedForTesting(),
            interpretationReader: reader
        )
        vm = CompatibilityViewModel(
            orchestrator: orchestrator,
            chartStore: chartStore,
            compatibilityStore: compatibilityStore,
            entitlementStore: entitlementStore,
            modelContext: context
        )
        vm.tempGender = "male"
    }

    override func tearDownWithError() throws {
        vm = nil
        recording = nil
        entitlementStore = nil
        compatibilityStore = nil
        chartStore = nil
        container = nil
        CompatibilityRosterPersistence.clear()
        try super.tearDownWithError()
    }

    // MARK: - 同人 no-op

    func testSelectPartner_同人且detail态_noop_零请求() async throws {
        let chartA = try insertChart(hash: "sp_a_known", alias: "A", hourKnown: true)
        let chartB = try insertChart(hash: "sp_b_known", alias: "B", hourKnown: true)
        vm.archivedCharts = [chartA, chartB]
        vm.selectedChartAIndex = 0
        vm.roster = [.archived(snapshotHash: "sp_b_known")]
        vm.selectedEntryIds = ["archived:sp_b_known"]

        vm.compute()
        let reached = await waitForDetailState()
        XCTAssertTrue(reached, "前置:算成直达 detail,实际:\(vm.state)")
        let callsBefore = await recording.compatibilityCallCount()

        // sheet 点当前已选者:VM 守卫 no-op(仅关 sheet 不重算)
        vm.selectPartner(.archived(snapshotHash: "sp_b_known"))

        let callsAfter = await recording.compatibilityCallCount()
        XCTAssertEqual(callsAfter, callsBefore, "同人 + detail 态不得再发请求")
        await drainDetailBackgroundTasks()
    }

    // MARK: - 换人触发 compute + 单选让位

    func testSelectPartner_换人_单选让位_池行移出名单_直达新对detail() async throws {
        let chartA = try insertChart(hash: "sp2_a_known", alias: "A", hourKnown: true)
        let chartB = try insertChart(hash: "sp2_b_known", alias: "B", hourKnown: true)
        let chartC = try insertChart(hash: "sp2_c_known", alias: "C", hourKnown: true)
        vm.archivedCharts = [chartA, chartB, chartC]
        vm.selectedChartAIndex = 0
        vm.roster = [.archived(snapshotHash: "sp2_b_known")]
        vm.selectedEntryIds = ["archived:sp2_b_known"]

        vm.selectPartner(.archived(snapshotHash: "sp2_c_known"))

        // 让位语义与 toggleArchived 换选一致:原池行随取消勾选移出名单
        XCTAssertEqual(vm.selectedEntryIds, ["archived:sp2_c_known"], "换人后唯一勾选 = 新对方")
        XCTAssertFalse(vm.roster.contains { $0.archivedSnapshotHash == "sp2_b_known" },
                       "原池行让位移出名单(资格⇔勾选不变量)")
        XCTAssertEqual(vm.roster.count, 1)

        let reached = await waitForDetailState()
        XCTAssertTrue(reached, "换人后算成直达 detail,实际:\(vm.state)")
        if case .detail(let summary, _, _) = vm.state {
            XCTAssertEqual(summary.personBHash, "sp2_c_known", "detail 态携带新对")
        }
        await drainDetailBackgroundTasks()
    }

    func testSelectPartner_临时人换人_原临时人让位保留名单() async throws {
        let chartA = try insertChart(hash: "sp3_a_known", alias: "A", hourKnown: true)
        vm.archivedCharts = [chartA]
        vm.selectedChartAIndex = 0
        let first: RosterEntry = .temp(
            input: PersonBInput(
                birthDatetime: "1991-06-06T09:30:00", timezone: "Asia/Shanghai",
                gender: "female", longitude: 116.4074
            ),
            alias: "甲", resolvedHash: nil,
            place: .custom(longitude: 116.4074, timezone: "Asia/Shanghai")
        )
        let second: RosterEntry = .temp(
            input: PersonBInput(
                birthDatetime: "1992-08-08T10:00:00", timezone: "Asia/Shanghai",
                gender: "female", longitude: 116.4074
            ),
            alias: "乙", resolvedHash: nil,
            place: .custom(longitude: 116.4074, timezone: "Asia/Shanghai")
        )
        vm.roster = [first, second]
        vm.selectedEntryIds = [first.id]

        vm.selectPartner(second)

        XCTAssertEqual(vm.selectedEntryIds, [second.id], "临时人让位只清勾选")
        XCTAssertEqual(vm.roster.count, 2, "让位 ≠ 移出:两位临时人都保留名单(对方池语义)")

        let reached = await waitForDetailState()
        XCTAssertTrue(reached, "实际:\(vm.state)")
        await drainDetailBackgroundTasks()
    }

    // MARK: - currentPartner 派生

    func testCurrentPartner_派生正确_三种形态() throws {
        let chartA = try insertChart(hash: "sp4_a_known", alias: "A", hourKnown: true)
        let chartB = try insertChart(hash: "sp4_b_known", alias: "B", hourKnown: true)
        vm.archivedCharts = [chartA, chartB]
        vm.selectedChartAIndex = 0

        // 无勾选 → nil(头部渲染「选择对方」占位)
        vm.roster = []
        vm.selectedEntryIds = []
        XCTAssertNil(vm.currentPartner)

        // 存档池行(无 summary)→ 按 archivedCharts 派生,推演开始头部即切名(P3)
        let entryB = RosterEntry.archived(snapshotHash: "sp4_b_known")
        vm.roster = [entryB]
        vm.selectedEntryIds = [entryB.id]
        let display = try XCTUnwrap(vm.currentPartner)
        XCTAssertEqual(display.name, "B")
        XCTAssertEqual(display.dayMaster, "甲")
        XCTAssertEqual(display.dayMasterElementKey, "wood")
        XCTAssertNotNil(display.birthDateString)
        XCTAssertEqual(display.entryID, entryB.id)

        // 临时人推演前 → alias + 出生地钟面日期前缀,日主未知
        let tempEntry: RosterEntry = .temp(
            input: PersonBInput(
                birthDatetime: "1993-05-05T08:15:00", timezone: "America/Los_Angeles",
                gender: "male", longitude: -118.2437
            ),
            alias: "洛杉矶朋友", resolvedHash: nil,
            place: .custom(longitude: -118.2437, timezone: "America/Los_Angeles")
        )
        vm.roster = [tempEntry]
        vm.selectedEntryIds = [tempEntry.id]
        let tempDisplay = try XCTUnwrap(vm.currentPartner)
        XCTAssertEqual(tempDisplay.name, "洛杉矶朋友")
        XCTAssertEqual(tempDisplay.birthDateString, "1993-05-05",
                       "推演前 = 出生地钟面日期前缀(不经设备时区换算)")
        XCTAssertNil(tempDisplay.dayMaster, "临时人推演前日主未知")
    }

    // MARK: - 推演中换人(cancel 竞态)

    func testSelectPartner_推演中换人_旧任务cancel_终态为新对() async throws {
        let chartA = try insertChart(hash: "sp5_a_known", alias: "A", hourKnown: true)
        let chartB = try insertChart(hash: "sp5_b_known", alias: "B", hourKnown: true)
        let chartC = try insertChart(hash: "sp5_c_known", alias: "C", hourKnown: true)
        vm.archivedCharts = [chartA, chartB, chartC]
        vm.selectedChartAIndex = 0

        vm.selectPartner(.archived(snapshotHash: "sp5_b_known"))
        if case .computing = vm.state {
            // 期望:推演中
        } else {
            XCTFail("前置:应处推演态,实际:\(vm.state)")
        }

        // 推演中换人 → compute() 内既有 cancel(D13);头部立即切到 C
        vm.selectPartner(.archived(snapshotHash: "sp5_c_known"))
        XCTAssertEqual(vm.currentPartner?.name, "C", "推演开始头部即切名")

        let reached = await waitForDetailState()
        XCTAssertTrue(reached, "实际:\(vm.state)")
        if case .detail(let summary, _, _) = vm.state {
            XCTAssertEqual(summary.personBHash, "sp5_c_known", "终态 = 新对 detail(旧任务被 cancel)")
        }
        // 旧对不得混入 summaries(cancel 短路未完成的循环)
        XCTAssertEqual(vm.summaries.count, 1)
        XCTAssertEqual(vm.summaries.first?.personBHash, "sp5_c_known")
        await drainDetailBackgroundTasks()
    }

    // MARK: - 守卫拒收 → 不发起 compute

    func testSelectPartner_满员守卫拒收_不按旧勾选发起compute() async throws {
        let chartA = try insertChart(hash: "sp6_a_known", alias: "A", hourKnown: true)
        let chartPool = try insertChart(hash: "sp6_pool_known", alias: "P", hourKnown: true)
        vm.archivedCharts = [chartA, chartPool]
        vm.selectedChartAIndex = 0
        // 8 位临时人占满名单,勾选第一位
        for i in 0..<8 {
            vm.roster.append(.temp(
                input: PersonBInput(
                    birthDatetime: "1990-01-0\(i + 1)T09:00:00", timezone: "Asia/Shanghai",
                    gender: "female", longitude: 116.4074 + Double(i)
                ),
                alias: "人\(i)", resolvedHash: nil,
                place: .custom(longitude: 116.4074, timezone: "Asia/Shanghai")
            ))
        }
        let current = vm.roster[0]
        vm.selectedEntryIds = [current.id]
        vm.state = .configuring

        // 满员 + 点存档池行(第 9 名)→ toggleArchived 上限守卫拒收;
        // selectPartner 不得带着旧勾选跑(算错人)
        vm.selectPartner(.archived(snapshotHash: "sp6_pool_known"))

        XCTAssertEqual(vm.selectedEntryIds, [current.id], "拒收路径勾选不变")
        if case .computing = vm.state {
            XCTFail("守卫拒收不得发起 compute(会按旧勾选算错对)")
        }
        let calls = await recording.compatibilityCallCount()
        XCTAssertEqual(calls, 0, "拒收 = 零请求")
    }

    // MARK: - 恢复态池行(在册未勾选)选中语义

    func testSelectPartner_池行在册未勾选_原地勾选_首击不移除() async throws {
        // 跨启动恢复可产出「池行在 roster 但未勾选」(上次对 CompatibilitySnapshot
        // 缺失/被清 → tryRestoreDetail 不预勾)。P3 点行 = 选中:首击必须原地勾选,
        // 不得误走 toggleArchived 的「再点 = 移除」分支静默丢人
        let chartA = try insertChart(hash: "spr_a_known", alias: "A", hourKnown: true)
        let chartB = try insertChart(hash: "spr_b_known", alias: "B", hourKnown: true)
        vm.archivedCharts = [chartA, chartB]
        vm.selectedChartAIndex = 0
        let entryB = RosterEntry.archived(snapshotHash: "spr_b_known")
        vm.roster = [entryB]            // 池行在册
        vm.selectedEntryIds = []        // 恢复未预勾(恢复态关键前提)
        vm.state = .configuring

        vm.selectPartner(entryB)

        XCTAssertEqual(vm.selectedEntryIds, [entryB.id], "首击原地勾选(不移除不重加)")
        XCTAssertTrue(vm.roster.contains { $0.id == entryB.id }, "池行不得被移出名单")
        XCTAssertEqual(vm.roster.count, 1)
        if case .computing = vm.state {
            // 期望:守卫放行,进入推演
        } else {
            XCTFail("在册未勾选池行首击应发起 compute,实际:\(vm.state)")
        }
        _ = await waitForDetailState()
        await drainDetailBackgroundTasks()
    }

    func testSelectPartner_在册未勾选池行换选_原临时人让位保留() async throws {
        // 同上,但当前勾选是一位临时人:换选在册未勾选池行 → 临时人让位保留名单,
        // 池行原地勾选(不经历移除重加),roster 成员资格零丢失
        let chartA = try insertChart(hash: "spr2_a_known", alias: "A", hourKnown: true)
        let chartB = try insertChart(hash: "spr2_b_known", alias: "B", hourKnown: true)
        vm.archivedCharts = [chartA, chartB]
        vm.selectedChartAIndex = 0
        let temp: RosterEntry = .temp(
            input: PersonBInput(
                birthDatetime: "1994-04-04T11:00:00", timezone: "Asia/Shanghai",
                gender: "male", longitude: 116.4074
            ),
            alias: "旧人", resolvedHash: nil,
            place: .custom(longitude: 116.4074, timezone: "Asia/Shanghai")
        )
        let entryB = RosterEntry.archived(snapshotHash: "spr2_b_known")
        vm.roster = [temp, entryB]
        vm.selectedEntryIds = [temp.id]
        vm.state = .configuring

        vm.selectPartner(entryB)

        XCTAssertEqual(vm.selectedEntryIds, [entryB.id])
        XCTAssertTrue(vm.roster.contains { $0.id == temp.id }, "临时人让位只清勾选不移出")
        XCTAssertEqual(vm.roster.count, 2, "roster 成员资格零丢失")
        if case .computing = vm.state {
        } else {
            XCTFail("应发起 compute,实际:\(vm.state)")
        }
        _ = await waitForDetailState()
        await drainDetailBackgroundTasks()
    }

    // MARK: - S2 契约(force 重算 / 修改返回值 / 移除当前对方)

    func testSelectPartner_force_同人detail态_仍重算() async throws {
        let chartA = try insertChart(hash: "s2f_a_known", alias: "A", hourKnown: true)
        let chartB = try insertChart(hash: "s2f_b_known", alias: "B", hourKnown: true)
        vm.archivedCharts = [chartA, chartB]
        vm.selectedChartAIndex = 0
        vm.roster = [.archived(snapshotHash: "s2f_b_known")]
        vm.selectedEntryIds = ["archived:s2f_b_known"]

        vm.compute()
        let reached = await waitForDetailState()
        XCTAssertTrue(reached, "前置:detail 在展,实际:\(vm.state)")
        let callsBefore = await recording.compatibilityCallCount()

        // 无 force:同人 no-op(S1 契约回归)
        vm.selectPartner(.archived(snapshotHash: "s2f_b_known"))
        let calls = await recording.compatibilityCallCount()
        XCTAssertEqual(calls, callsBefore, "无 force 同人 detail = no-op")

        // force:绕过 no-op(修改当前对方 / 补时辰后重算路径)。
        // 注意:同输入对的 force 重算可能命中 S05 增量预查(零网络,期望行为),
        // 断言按状态机路径——force 后立即离开 detail 进推演态,而非请求数
        vm.selectPartner(.archived(snapshotHash: "s2f_b_known"), force: true)
        if case .computing = vm.state {
            // 期望:force 立即触发 compute(compute 同步置 .computing)
        } else {
            XCTFail("force 必须重新走 compute 路径,实际:\(vm.state)")
        }
        _ = await waitForDetailState()
        await drainDetailBackgroundTasks()
    }

    func testUpdateTempEntry_返回新entry_勾选随迁() throws {
        let entry: RosterEntry = .temp(
            input: PersonBInput(
                birthDatetime: "1991-06-06T09:30:00", timezone: "Asia/Shanghai",
                gender: "female", longitude: 116.4074, placeName: "自定义地点"
            ),
            alias: "乙", resolvedHash: "hash_b1",
            place: .custom(longitude: 116.4074, timezone: "Asia/Shanghai")
        )
        vm.roster = [entry]
        vm.selectedEntryIds = [entry.id]

        // 回填后改日期 → 输入变(id 变)
        XCTAssertTrue(vm.beginEditTempEntry(entry))
        vm.tempBirthDate = Date(timeIntervalSince1970: 700_000_000)
        let updated = try vm.updateTempEntry(entry)

        // S2 契约:返回替换后的新 entry(调用方据此 force 重算)
        XCTAssertNotEqual(updated.id, entry.id, "输入变了 → 新 id")
        XCTAssertTrue(vm.selectedEntryIds.contains(updated.id), "勾选随迁到新 entry")
        XCTAssertEqual(vm.roster.first?.id, updated.id)
    }

    func test移除当前对方_清选_切配置态_不发请求() async throws {
        let chartA = try insertChart(hash: "s2r_a_known", alias: "A", hourKnown: true)
        let chartB = try insertChart(hash: "s2r_b_known", alias: "B", hourKnown: true)
        vm.archivedCharts = [chartA, chartB]
        vm.selectedChartAIndex = 0
        vm.roster = [.archived(snapshotHash: "s2r_b_known")]
        vm.selectedEntryIds = ["archived:s2r_b_known"]

        vm.compute()
        let reached = await waitForDetailState()
        XCTAssertTrue(reached, "前置:detail 在展,实际:\(vm.state)")
        let callsBefore = await recording.compatibilityCallCount()

        // 换人 sheet 移除当前对方的组合流(View 层 removeEntry 的 VM 侧效果):
        // 勾选随清 + 切出 detail(P6 态入口),不自动选下一位、不发请求
        vm.removeRosterEntry(.archived(snapshotHash: "s2r_b_known"))
        vm.clearDetailKeepRoster()

        XCTAssertTrue(vm.selectedEntryIds.isEmpty, "移出当前对方 → 勾选清空")
        XCTAssertTrue(vm.roster.isEmpty)
        if case .configuring = vm.state {
            // 期望:切出 detail(S3 起 .configuring 渲染为结果壳 P6 态)
        } else {
            XCTFail("移除当前对方应切出 detail,实际:\(vm.state)")
        }
        let calls = await recording.compatibilityCallCount()
        XCTAssertEqual(calls, callsBefore, "移除不得发起任何合盘请求")
    }

    // MARK: - applyHashRemap(S10 补时辰后结果壳重算的前置)

    func testApplyHashRemap_roster与勾选id原地换血() throws {
        let oldEntry = RosterEntry.archived(snapshotHash: "old_hash")
        let keeper = RosterEntry.archived(snapshotHash: "keep_hash")
        vm.roster = [oldEntry, keeper]
        vm.selectedEntryIds = [oldEntry.id]

        vm.applyHashRemap(from: "old_hash", to: "new_hash")

        XCTAssertEqual(vm.roster, [.archived(snapshotHash: "new_hash"), keeper],
                       "名单内该行原地换新 hash")
        XCTAssertEqual(vm.selectedEntryIds, [RosterEntry.archived(snapshotHash: "new_hash").id],
                       "勾选 id 随迁(内嵌 hash)")
    }

    // MARK: - 补时辰续接选人(P1-1,2026-09-30:重算补时辰的那个人)

    func testContinueAfterAddHourRemap_他人盘目标_选补时辰的人而非当前对方() async throws {
        let chartA = try insertChart(hash: "ca_a_known", alias: "A", hourKnown: true)
        let chartX = try insertChart(hash: "ca_x_known", alias: "X", hourKnown: true)
        // Y 补时辰后的新盘(hourKnown;旧三柱盘不在池——loadArchivedCharts 只见
        // link 指向的新盘,镜像 AddHour submit 补写 link 后的状态)
        let chartY = try insertChart(hash: "ca_y_new", alias: "Y", hourKnown: true)
        vm.archivedCharts = [chartA, chartX, chartY]
        vm.selectedChartAIndex = 0
        vm.roster = [.archived(snapshotHash: "ca_x_known")]
        vm.selectedEntryIds = ["archived:ca_x_known"]
        vm.compute()
        let reached = await waitForDetailState()
        XCTAssertTrue(reached, "前置:当前对方 X 在展,实际:\(vm.state)")

        // 换人 sheet 点无时辰的 Y → 补时辰 dismiss:内存 remap + 续接(P1-1 主场景)
        vm.applyHashRemap(from: "ca_y_old", to: "ca_y_new")
        vm.continueAfterAddHourRemap(
            target: .partnerChart(hash: "ca_y_old"),
            remap: (old: "ca_y_old", new: "ca_y_new")
        )

        // 选中与推演的都是 Y(新 hash),不再是 X(旧当前对方)
        XCTAssertEqual(vm.selectedEntryIds, ["archived:ca_y_new"],
                       "续接选中补时辰的人")
        let reachedY = await waitForDetailState()
        XCTAssertTrue(reachedY, "Y 应算成直达 detail,实际:\(vm.state)")
        if case .detail(let summary, _, _) = vm.state {
            XCTAssertEqual(summary.personBHash, "ca_y_new", "重算的是补时辰的人")
        } else {
            XCTFail("应进入 Y 的 detail,实际:\(vm.state)")
        }
        await drainDetailBackgroundTasks()
    }

    func testContinueAfterAddHourRemap_自己盘目标_维持当前对方强制重算() async throws {
        // A 补时辰:A 换新盘 → 选人不变,当前对按新 A 强制重算(旧行为保持)
        let chartANew = try insertChart(hash: "ca2_a_new", alias: "A", hourKnown: true)
        let chartB = try insertChart(hash: "ca2_b_known", alias: "B", hourKnown: true)
        vm.archivedCharts = [chartANew, chartB]
        vm.selectedChartAIndex = 0
        vm.roster = [.archived(snapshotHash: "ca2_b_known")]
        vm.selectedEntryIds = ["archived:ca2_b_known"]
        vm.compute()
        _ = await waitForDetailState()

        vm.applyHashRemap(from: "ca2_a_old", to: "ca2_a_new")
        vm.continueAfterAddHourRemap(
            target: .selfChart,
            remap: (old: "ca2_a_old", new: "ca2_a_new")
        )

        XCTAssertEqual(vm.selectedEntryIds, ["archived:ca2_b_known"],
                       "自己盘补时辰不改选人")
        if case .computing = vm.state {
            // 期望:force 立即重算(compute 同步置 .computing)
        } else {
            XCTFail("当前对应被强制重算,实际:\(vm.state)")
        }
        _ = await waitForDetailState()
        await drainDetailBackgroundTasks()
    }

    func testContinueAfterAddHourRemap_目标与remap不符_回落旧行为() async throws {
        let chartA = try insertChart(hash: "ca3_a", alias: "A", hourKnown: true)
        let chartX = try insertChart(hash: "ca3_x", alias: "X", hourKnown: true)
        vm.archivedCharts = [chartA, chartX]
        vm.selectedChartAIndex = 0
        vm.roster = [.archived(snapshotHash: "ca3_x")]
        vm.selectedEntryIds = ["archived:ca3_x"]
        vm.compute()
        _ = await waitForDetailState()

        // 状态错乱(remap 与开 sheet 时目标不符)→ 显式记日志 + 回落:当前对方 force 重算
        vm.applyHashRemap(from: "ca3_other_old", to: "ca3_other_new")
        vm.continueAfterAddHourRemap(
            target: .partnerChart(hash: "mismatch_old"),
            remap: (old: "ca3_other_old", new: "ca3_other_new")
        )

        XCTAssertEqual(vm.selectedEntryIds, ["archived:ca3_x"], "回落不改选人")
        if case .computing = vm.state {
        } else {
            XCTFail("回落应对当前对方强制重算,实际:\(vm.state)")
        }
        _ = await waitForDetailState()
        await drainDetailBackgroundTasks()
    }

    // MARK: - 辅助(fixture 与 BatchTests 同款)

    @discardableResult
    private func insertChart(
        hash: String, alias: String, hourKnown: Bool
    ) throws -> ArchivedChart {
        let pillar = PillarDTO(
            ganZhi: "甲子", gan: "甲", zhi: "子",
            ganElement: "wood", zhiElement: "water",
            hideGan: ["癸"], shishenGan: "比肩", shishenZhi: ["正印"],
            nayin: "海中金", dishi: "沐浴", xunkong: "戌亥"
        )
        let ganzhi = GanZhiNaYinDTO(ganZhi: "甲子", nayin: "海中金")
        let request = BaziCalculateRequest(
            birthDatetime: "1990-03-15T12:00:00",
            timezone: "Asia/Shanghai",
            gender: "male",
            longitude: 116.4074,
            latitude: 39.9042,
            placeName: "北京",
            geonameId: 1816670,
            ziHourRule: "zi_next_day",
            hourKnown: hourKnown
        )
        let response = BaziResponse(
            contentHash: hash,
            trueSolarTime: nil,
            trueSolarOffsetMinutes: 0,
            pillars: PillarsDTO(year: pillar, month: pillar, day: pillar, hour: hourKnown ? pillar : nil),
            mingGong: ganzhi, shenGong: ganzhi, taiYuan: ganzhi,
            elementBalance: ElementBalanceDTO(wood: 2, fire: 1, earth: 1, metal: 1, water: 3),
            favorableElements: ["木", "水"], unfavorableElements: ["土"],
            dayMasterStrength: "balanced",
            tiaoshouApplied: false,
            xijiMethod: "扶抑+调候", patternHint: nil,
            shensha: [], luckPillars: [],
            currentLuckPillar: nil, currentYearPillar: nil,
            currentDayPillar: nil, currentHourPillar: nil,
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1, birthTimezone: "Asia/Shanghai",
                hourKnown: hourKnown, pillarAmbiguity: nil
            ),
            boundaryWarning: nil,
            yearBranchZodiac: "Rat",
            yearBranchFriends: ["Ox"], yearBranchClash: "Horse"
        )
        let result = try chartStore.upsert(response: response, request: request)
        return ArchivedChart(
            snapshotHash: hash,
            alias: alias,
            birthDate: result.snapshot.birthSolarTime,
            gender: "male",
            dayMaster: "甲",
            snapshot: result.snapshot
        )
    }

    private func waitForDetailState(timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .detail = vm.state { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        if case .detail = vm.state { return true }
        return false
    }

    /// teardown 竞态防护(镜像 BatchTests.drainDetailBackgroundTasks)。
    private func drainDetailBackgroundTasks() async {
        vm.clearDetailKeepRoster()
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}

// MARK: - 记录型 API 双打

private enum SelectPartnerTestError: Error { case unexpectedCall }

/// compatibility 请求记录后返回合法夹具(命中即计数;no-op 断言依赖零计数);
/// 其余端点被调即抛错(负向哨兵)。
private actor SelectPartnerRecordingAPIClient: APIClient {
    private var compatibilityRequests: [CompatibilityRequest] = []

    func compatibilityCallCount() -> Int { compatibilityRequests.count }

    func health() async throws -> HealthResponse {
        HealthResponse(
            status: "ok", lunarPythonVersion: "1.4.8",
            model: "sp-recording-test", aiProvider: "anthropic", aiModel: "claude-test"
        )
    }

    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse {
        compatibilityRequests.append(request)
        // 模式 B(personB 非 nil):orchestrator 要求 response.personBChart 内嵌
        // BaziResponse 以隐式落地(不落 link,D6);contentHash 按出生输入派生保证
        // 同输入同 hash(内容寻址语义)
        var personBChart: BaziResponse? = nil
        if let personB = request.personB {
            let digest = personB.birthDatetime.replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: "-", with: "")
            personBChart = Self.mockBazi(contentHash: "sp_b_\(digest)")
        }
        return CompatibilityResponse(
            compatibilityHash: "sp_pair_\(compatibilityRequests.count)",
            personAChart: nil,
            personBChart: personBChart,
            qualitativeAssessment: QualitativeAssessmentDTO(
                fiveElements: "互补", dayMasterRelation: "同气",
                zodiacMatch: "六合", branchHarmony: "无冲无刑"
            ),
            syncedFortune: [],
            calcRuleSnapshot: nil
        )
    }

    /// 模式 B 隐式落地用 BaziResponse 夹具(时柱在场 → hourKnown,日主「甲」)。
    private static func mockBazi(contentHash: String) -> BaziResponse {
        let pillar = PillarDTO(
            ganZhi: "甲子", gan: "甲", zhi: "子",
            ganElement: "wood", zhiElement: "water",
            hideGan: ["癸"], shishenGan: "比肩", shishenZhi: ["正印"],
            nayin: "海中金", dishi: "沐浴", xunkong: "戌亥"
        )
        let ganzhi = GanZhiNaYinDTO(ganZhi: "甲子", nayin: "海中金")
        return BaziResponse(
            contentHash: contentHash,
            trueSolarTime: nil,
            trueSolarOffsetMinutes: 0,
            pillars: PillarsDTO(year: pillar, month: pillar, day: pillar, hour: pillar),
            mingGong: ganzhi, shenGong: ganzhi, taiYuan: ganzhi,
            elementBalance: ElementBalanceDTO(wood: 2, fire: 1, earth: 1, metal: 1, water: 3),
            favorableElements: ["木", "水"], unfavorableElements: ["土"],
            dayMasterStrength: "balanced",
            tiaoshouApplied: false,
            xijiMethod: "扶抑+调候", patternHint: nil,
            shensha: [], luckPillars: [],
            currentLuckPillar: nil, currentYearPillar: nil,
            currentDayPillar: nil, currentHourPillar: nil,
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1, birthTimezone: "Asia/Shanghai",
                hourKnown: true, pillarAmbiguity: nil
            ),
            boundaryWarning: nil,
            yearBranchZodiac: "Rat",
            yearBranchFriends: ["Ox"], yearBranchClash: "Horse"
        )
    }

    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        throw SelectPartnerTestError.unexpectedCall
    }
    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        throw SelectPartnerTestError.unexpectedCall
    }
    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse {
        throw SelectPartnerTestError.unexpectedCall
    }
    func redeem(request: EntitlementRedeemRequest) async throws -> EntitlementRedeemResponse {
        throw SelectPartnerTestError.unexpectedCall
    }
    func entitlementList() async throws -> EntitlementListResponse {
        throw SelectPartnerTestError.unexpectedCall
    }
    func signIn(request: SignInRequest) async throws -> SignInResponse {
        throw SelectPartnerTestError.unexpectedCall
    }
    func syncPull() async throws -> SyncPullResponse {
        throw SelectPartnerTestError.unexpectedCall
    }
    func syncPush(request: SyncPushRequest) async throws -> SyncPushResponse {
        throw SelectPartnerTestError.unexpectedCall
    }
}
