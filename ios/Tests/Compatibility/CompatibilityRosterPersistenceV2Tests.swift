import SwiftData
import XCTest
@testable import QiCompass

/// 合盘名单持久化 V2(R1-R5,2026-09-30)单元测试。
///
/// 覆盖 docs/合盘名单持久化修复-plan.md §4 场景 A-F + 校验/迁移/损坏/remap/
/// 恢复不回写,以及 §3.2 行禁用纯函数。老 API(save/load/cleanup)已删除,
/// AddHourFlowTests / CompatibilityViewModelBatchTests 的存量断言同步改写
/// (R5 迁移用例在 BatchTests)。
@MainActor
final class CompatibilityRosterPersistenceV2Tests: XCTestCase {

    private var container: ModelContainer!
    private var chartStore: ChartSnapshotStore!
    private var compatibilityStore: CompatibilitySnapshotStore!
    private var vm: CompatibilityViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        CompatibilityRosterPersistence.clear()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        chartStore = ChartSnapshotStore(context: context)
        compatibilityStore = CompatibilitySnapshotStore(context: context)
        let apiClient = MockAPIClient()
        let interpretStore = InterpretationCacheStore(context: context)
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: apiClient),
            cacheStore: interpretStore
        )
        let orchestrator = CompatibilityOrchestrator(
            apiClient: apiClient,
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
            entitlementStore: EntitlementStore(modelContext: context),
            modelContext: context
        )
        vm.tempGender = "female"
    }

    override func tearDown() async throws {
        await MainActor.run {
            vm?.clearDetailKeepRoster()
        }
        // openDetail 的 cacheReadTask 可能仍在途(容器释放竞态),让步等它退出
        try? await Task.sleep(nanoseconds: 500_000_000)
        vm = nil
        chartStore = nil
        compatibilityStore = nil
        container = nil
        CompatibilityRosterPersistence.clear()
    }

    // MARK: - 脚手架

    private static func makePlace(displayName: String, longitude: Double = 116.4074,
                                  timezone: String = "Asia/Shanghai", gid: Int = 1) -> CityRecord {
        CityRecord(
            geonameId: gid, name: displayName, nameZh: displayName, countryCode: "CN",
            admin1Name: nil, countryNameZh: "中国", latitude: 39.9042, longitude: longitude,
            timezone: timezone, population: 1_000_000, isCN: true
        )
    }

    /// 构造真 payload 命盘并落档(R3 直达 detail 需可 decode 的 B 快照)。
    @discardableResult
    private func insertChart(hash: String, hourKnown: Bool = true) throws -> ArchivedChart {
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
            pillars: PillarsDTO(
                year: pillar, month: pillar,
                day: pillar,
                hour: hourKnown ? pillar : nil
            ),
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
                hourKnown: hourKnown,
                pillarAmbiguity: nil
            ),
            boundaryWarning: nil,
            yearBranchZodiac: "Rat",
            yearBranchFriends: ["Ox"], yearBranchClash: "Horse"
        )
        _ = try chartStore.upsert(response: response, request: request)
        let snapshot = try XCTUnwrap(try chartStore.get(contentHash: hash))
        return ArchivedChart(
            snapshotHash: hash, alias: "A\(hash.suffix(1))",
            birthDate: snapshot.birthSolarTime, gender: "male",
            dayMaster: "甲", snapshot: snapshot
        )
    }

    /// 直接构造 .temp entry(V2 seeding / 名单操作用)。
    private static func tempEntry(alias: String, birthDatetime: String,
                                  resolvedHash: String? = nil) -> RosterEntry {
        .temp(
            input: PersonBInput(
                birthDatetime: birthDatetime,
                timezone: "Asia/Shanghai",
                gender: "female",
                longitude: 116.4074
            ),
            alias: alias,
            resolvedHash: resolvedHash,
            place: .city(makePlace(displayName: "北京"))
        )
    }

    /// 新建 VM 恢复(模拟杀 App 重开;同一 container + UserDefaults)。
    private func makeRestoredVM(archived: [ArchivedChart]) -> CompatibilityViewModel {
        let context = container.mainContext
        let apiClient = MockAPIClient()
        let interpretStore = InterpretationCacheStore(context: context)
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: apiClient),
            cacheStore: interpretStore
        )
        let orchestrator = CompatibilityOrchestrator(
            apiClient: apiClient,
            compatibilityStore: compatibilityStore,
            chartStore: chartStore,
            interpretStore: interpretStore,
            counter: DailyReadCounter.makeIsolatedForTesting(),
            interpretationReader: reader
        )
        let restored = CompatibilityViewModel(
            orchestrator: orchestrator,
            chartStore: chartStore,
            compatibilityStore: compatibilityStore,
            entitlementStore: EntitlementStore(modelContext: context),
            modelContext: context
        )
        restored.archivedCharts = archived
        restored.state = .configuring
        restored.restoreRosterStateIfAvailable()
        return restored
    }

    // MARK: - 场景 A/B/F:三人名单 + 称呼 + 选中最后换到那位

    func testV2_三人名单带称呼_跨启动恢复_选中最后换到那位() throws {
        let chartA = try insertChart(hash: "v2_a")
        vm.archivedCharts = [chartA]
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempPlace = .city(Self.makePlace(displayName: "北京"))
        vm.tempGender = "female"

        vm.tempAlias = "小王"
        let wang = try vm.addTempToRoster()
        vm.tempAlias = "妈妈"
        let mama = try vm.addTempToRoster()
        vm.tempAlias = "Lisa"
        let lisa = try vm.addTempToRoster()
        // 同生日不同称呼不会撞 id?—— id 含 alias,可区分;切到妈妈再切 Lisa
        vm.toggleEntrySelection(mama)
        vm.toggleEntrySelection(lisa)

        let restored = makeRestoredVM(archived: [chartA])

        XCTAssertEqual(restored.roster.count, 3, "场景 A:三人全在,不再只剩最后一位")
        XCTAssertEqual(Set(restored.roster.compactMap(\.tempAlias)), ["小王", "妈妈", "Lisa"],
                       "场景 B:称呼跨启动不丢")
        XCTAssertEqual(restored.selectedEntryIds, [lisa.id], "场景 F:选中 = 最后换到的那位")
        if case .detail = restored.state {
            XCTFail("无缓存不得直达 detail,实际:\(restored.state)")
        }
        XCTAssertEqual(wang.id, wang.id)
        XCTAssertEqual(mama.tempAlias, "妈妈")
        XCTAssertTrue(try compatibilityStore.list(personAHash: "v2_a", context: "general").isEmpty,
                      "零请求:恢复不产生合盘快照")
    }

    // MARK: - 场景 C:最后一次合盘失败(拦截对)→ 名单不变

    func testV2_合盘拦截对compute_名单不丢_恢复后完好() async throws {
        let chartA = try insertChart(hash: "v2_ca", hourKnown: false)  // A 无时辰 → 整对拦
        vm.archivedCharts = [chartA]
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempPlace = .city(Self.makePlace(displayName: "北京"))
        vm.tempGender = "female"
        vm.tempAlias = "小王"
        _ = try vm.addTempToRoster()
        vm.tempAlias = "Lisa"
        let lisa = try vm.addTempToRoster()
        vm.toggleEntrySelection(lisa)

        vm.compute()
        // 等待 compute Task 落地(.list 单卡拦截)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, vm.state != .list {
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertEqual(vm.state, .list, "拦截对应进 .list 兜底,实际:\(vm.state)")

        let restored = makeRestoredVM(archived: [chartA])
        XCTAssertEqual(restored.roster.count, 2, "场景 C:合盘失败不影响名单")
        XCTAssertEqual(restored.selectedEntryIds, [lisa.id], "选中保留")
    }

    // MARK: - 场景 D:移出当前对方 → 恢复后不在名单、无选中、零请求

    func testV2_移出当前对方_恢复后不在_无选中_零请求() throws {
        let chartA = try insertChart(hash: "v2_da")
        vm.archivedCharts = [chartA]
        let wang = Self.tempEntry(alias: "小王", birthDatetime: "1990-01-01T10:00:00")
        let lisa = Self.tempEntry(alias: "Lisa", birthDatetime: "1992-08-08T10:00:00")
        // 经公开路径入册 + 选中
        // (直塞 roster 不触发持久化,改用 toggle 前先塞入名单模拟已入册)
        vm.roster = [wang, lisa]
        vm.toggleEntrySelection(lisa)
        vm.removeRosterEntry(lisa)

        let restored = makeRestoredVM(archived: [chartA])
        XCTAssertEqual(restored.roster.map(\.tempAlias), ["小王"], "场景 D:被移出的人不复活")
        XCTAssertTrue(restored.selectedEntryIds.isEmpty, "无选中(回 P6,不自动选下一位)")
        XCTAssertTrue(try compatibilityStore.list(personAHash: "v2_da", context: "general").isEmpty,
                      "零请求")
    }

    // MARK: - 场景 E:未算过的成员(resolvedHash nil)→ 恢复后仍在

    func testV2_未算过的成员_恢复后仍在_resolvedHash为nil() throws {
        let chartA = try insertChart(hash: "v2_ea")
        vm.archivedCharts = [chartA]
        let fresh = Self.tempEntry(alias: "新同事", birthDatetime: "1995-05-05T09:00:00")
        CompatibilityRosterPersistence.saveV2(
            personAHash: "v2_ea", context: "general",
            roster: .init(entries: [fresh.persisted], selectedEntryID: nil)
        )

        let restored = makeRestoredVM(archived: [chartA])
        XCTAssertEqual(restored.roster.count, 1, "场景 E:没算过的人不再消失")
        XCTAssertNil(restored.roster.first?.resolvedContentHash, "resolvedHash 保持 nil")
    }

    // MARK: - R3:选中者有缓存 → 直达 detail,displayName 是称呼,零请求

    func testV2_选中者有缓存_恢复直达detail_称呼保留_零请求() throws {
        let chartA = try insertChart(hash: "v2_fa")
        _ = try insertChart(hash: "v2_fb")  // B 盘真 payload(rebuild 需要 decode)
        let entry = Self.tempEntry(alias: "妈妈", birthDatetime: "1991-06-18T08:30:00",
                                   resolvedHash: "v2_fb")
        CompatibilityRosterPersistence.saveV2(
            personAHash: "v2_fa", context: "general",
            roster: .init(entries: [entry.persisted], selectedEntryID: entry.id)
        )
        // 命中缓存的 CompatibilitySnapshot(canonicalKey 直查路径)
        _ = try compatibilityStore.upsertQualitative(
            response: CompatibilityResponse(
                compatibilityHash: CompatibilitySnapshotStore.canonicalKey(
                    aHash: "v2_fa", bHash: "v2_fb", context: "general"),
                personAChart: nil, personBChart: nil,
                qualitativeAssessment: QualitativeAssessmentDTO(
                    fiveElements: "互补", dayMasterRelation: "同气",
                    zodiacMatch: "六合", branchHarmony: "无冲无刑"
                ),
                syncedFortune: [], calcRuleSnapshot: nil
            ),
            personAHash: "v2_fa", personBHash: "v2_fb", context: "general"
        )

        let restored = makeRestoredVM(archived: [chartA])
        guard case .detail(let summary, _, _) = restored.state else {
            return XCTFail("有缓存应零请求直达 detail,实际:\(restored.state)")
        }
        XCTAssertEqual(summary.displayName, "妈妈",
                       "R3:传名单真实 entry,称呼不再变回「对方 · 日期」兜底名")
        XCTAssertEqual(restored.selectedEntryIds, [entry.id])
        XCTAssertEqual(restored.summaries.count, 1)
    }

    // MARK: - R3 补充:选中者无缓存 → .configuring + 选中保留 + 零请求

    func testV2_选中者无缓存_留在configuring_选中保留_零请求() throws {
        let chartA = try insertChart(hash: "v2_ga")
        _ = try insertChart(hash: "v2_gb")
        let entry = Self.tempEntry(alias: "Lisa", birthDatetime: "1992-08-08T10:00:00",
                                   resolvedHash: "v2_gb")
        CompatibilityRosterPersistence.saveV2(
            personAHash: "v2_ga", context: "general",
            roster: .init(entries: [entry.persisted], selectedEntryID: entry.id)
        )

        let restored = makeRestoredVM(archived: [chartA])
        XCTAssertEqual(restored.state, .configuring, "无缓存不自动发请求(P6 有选中态)")
        XCTAssertEqual(restored.selectedEntryIds, [entry.id], "选中保留(头部显示该人)")
        XCTAssertTrue(try compatibilityStore.list(personAHash: "v2_ga", context: "general").isEmpty)
    }

    // MARK: - 校验:archived 快照被删剔除;temp resolvedHash 失效置 nil 保留成员

    func testV2_校验_archived被删剔除_temp的resolvedHash被删置nil() throws {
        let chartA = try insertChart(hash: "v2_ha")
        let temp = Self.tempEntry(alias: "妈妈", birthDatetime: "1991-06-18T08:30:00",
                                  resolvedHash: "ghost_resolved")
        CompatibilityRosterPersistence.saveV2(
            personAHash: "v2_ha", context: "general",
            roster: .init(
                entries: [.archived(snapshotHash: "ghost_archived"), temp.persisted],
                selectedEntryID: nil
            )
        )

        let restored = makeRestoredVM(archived: [chartA])
        XCTAssertEqual(restored.roster.count, 1, ".archived 快照缺失剔除,.temp 恒保留")
        XCTAssertNil(restored.roster.first?.resolvedContentHash,
                     "resolvedHash 指向的快照被删 → 置 nil(下次合盘重新请求)")
        XCTAssertEqual(restored.roster.first?.tempAlias, "妈妈")
    }

    // MARK: - selectedEntryID 不在名单 → 清空

    func testV2_选中id不在名单_恢复后清空选中() throws {
        let chartA = try insertChart(hash: "v2_ia")
        let temp = Self.tempEntry(alias: "小王", birthDatetime: "1990-01-01T10:00:00")
        CompatibilityRosterPersistence.saveV2(
            personAHash: "v2_ia", context: "general",
            roster: .init(entries: [temp.persisted], selectedEntryID: "archived:ghost")
        )

        let restored = makeRestoredVM(archived: [chartA])
        XCTAssertTrue(restored.selectedEntryIds.isEmpty, "悬空 selectedEntryID 清空")
        XCTAssertNil(CompatibilityRosterPersistence.loadV2()?.selectedEntryID, "清空结果落盘")
    }

    // MARK: - 损坏 JSON(V2 / 老 key)

    func testV2_损坏JSON_名单空_key自愈_不崩() throws {
        let chartA = try insertChart(hash: "v2_ja")
        UserDefaults.standard.set(Data("not-json".utf8), forKey: "compat.rosterV2")

        let restored = makeRestoredVM(archived: [chartA])
        XCTAssertTrue(restored.roster.isEmpty, "损坏 → 视为空,不崩")
        // loadV2 删损坏 key;恢复末次 persistRoster 写回干净空名单(自愈)
        let healed = CompatibilityRosterPersistence.loadV2()
        XCTAssertTrue(healed?.entries.isEmpty ?? false, "自愈后为干净空名单,非损坏残留")
    }

    func testV2_老key损坏JSON_迁移视为无_不崩() throws {
        let chartA = try insertChart(hash: "v2_ka")
        UserDefaults.standard.set(Data("not-json".utf8), forKey: "compat.roster")

        let restored = makeRestoredVM(archived: [chartA])
        XCTAssertTrue(restored.roster.isEmpty)
        XCTAssertNil(UserDefaults.standard.data(forKey: "compat.roster"), "损坏老 key 迁移时删除")
    }

    // MARK: - remap:.temp 的 resolvedHash 换新

    func testV2_remap_temp的resolvedHash换新_选中id不变() throws {
        let temp = Self.tempEntry(alias: "妈妈", birthDatetime: "1991-06-18T08:30:00",
                                  resolvedHash: "old_hash")
        CompatibilityRosterPersistence.saveV2(
            personAHash: "a_unrelated", context: "general",
            roster: .init(entries: [temp.persisted], selectedEntryID: temp.id)
        )

        CompatibilityRosterPersistence.remapHash(from: "old_hash", to: "new_hash")

        let loaded = try XCTUnwrap(CompatibilityRosterPersistence.loadV2())
        XCTAssertEqual(loaded.entries.first, .temp(
            input: temp.tempInput!, alias: "妈妈", resolvedHash: "new_hash",
            place: .city(Self.makePlace(displayName: "北京"))
        ), "temp 的 resolvedHash 命中老 hash → 换新")
        XCTAssertEqual(loaded.selectedEntryID, temp.id,
                       "temp id 不内嵌 hash,选中不动")
        XCTAssertEqual(CompatibilityRosterPersistence.loadPersonAHash(), "a_unrelated",
                       "无关 A 盘不动")
    }

    // MARK: - 恢复不写脏:全量恢复后持久化内容不漂移

    func testV2_恢复全程_持久化内容不漂移() throws {
        let chartA = try insertChart(hash: "v2_la")
        let b1 = Self.tempEntry(alias: "小王", birthDatetime: "1990-01-01T10:00:00")
        let b2 = Self.tempEntry(alias: "Lisa", birthDatetime: "1992-08-08T10:00:00")
        let seeded = CompatibilityRosterPersistence.PersistedRoster(
            entries: [b1.persisted, b2.persisted], selectedEntryID: b2.id
        )
        CompatibilityRosterPersistence.saveV2(
            personAHash: "v2_la", context: "general", roster: seeded
        )
        let before = CompatibilityRosterPersistence.loadV2()

        _ = makeRestoredVM(archived: [chartA])

        XCTAssertEqual(CompatibilityRosterPersistence.loadV2(), before,
                       "恢复只读不写(无清理发生时内容零漂移)")
        XCTAssertEqual(CompatibilityRosterPersistence.loadV2(), seeded)
    }
}
