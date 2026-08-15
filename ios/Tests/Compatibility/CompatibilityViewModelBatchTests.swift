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
        // 防止上个测试的 UserDefaults 持久化污染本测试
        CompatibilityRosterPersistence.clear()
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
        // S06 测试会写 UserDefaults.standard,清掉避免污染其他测试
        CompatibilityRosterPersistence.clear()
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

    // MARK: - 测试 fixture(S04:结构化地点)

    /// 构造测试用 CityRecord(默认北京坐标)。
    private static func makePlace(displayName: String, longitude: Double = 116.4074,
                                  timezone: String = "Asia/Shanghai", gid: Int = 1) -> CityRecord {
        CityRecord(
            geonameId: gid, name: displayName, nameZh: displayName, countryCode: "CN",
            admin1Name: nil, countryNameZh: "中国", latitude: 39.9042, longitude: longitude,
            timezone: timezone, population: 1_000_000, isCN: true
        )
    }

    // MARK: - addTempToRoster(S01 限 1 条 / 校验不静默吞)

    func testAddTempToRoster_出生时间未来_抛错() {
        vm.tempBirthDate = Date().addingTimeInterval(60)  // 1 分钟后
        XCTAssertThrowsError(try vm.addTempToRoster()) { error in
            XCTAssertTrue(error.localizedDescription.contains("不能晚于当下"))
        }
        XCTAssertTrue(vm.roster.isEmpty, "校验失败不应入名单")
    }

    func testAddTempToRoster_未选城市_抛错() {
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempPlace = nil
        vm.tempUseManualLongitude = false
        XCTAssertThrowsError(try vm.addTempToRoster()) { error in
            XCTAssertTrue(error.localizedDescription.contains("出生城市"))
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
        vm.tempPlace = Self.makePlace(displayName: "北京", gid: 1816670)

        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.filter(\.isTemp).count, 1)

        // S04:再加一次,出生时间不同 → 名单内 2 条独立 temp
        vm.tempBirthDate = Date(timeIntervalSince1970: 700_000_000)
        vm.tempPlace = Self.makePlace(displayName: "上海", longitude: 121.4737, gid: 1796236)
        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.filter(\.isTemp).count, 2, "S04 改造:多条独立 temp,不再替换")
    }

    func testAddTempToRoster_相同临时人_去重拒绝() {
        // review 修复 1:两个完全相同 input(同时间/性别/城市/alias)→ 同 entry.id → 第二次抛错
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempGender = "male"
        vm.tempPlace = Self.makePlace(displayName: "北京", gid: 1816670)
        vm.tempAlias = "相亲对象甲"
        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.count, 1)

        // 同输入再调一次 → 应抛错(文案 2026-08-14 去「临时」)
        XCTAssertThrowsError(try vm.addTempToRoster(), "相同 entry.id 必须拒绝") { error in
            XCTAssertTrue(error.localizedDescription.contains("已存在相同的对方"))
        }
        XCTAssertEqual(vm.roster.count, 1, "去重:roster 不应增加重复条目")
    }

    // MARK: - S04 多临时人 + 称呼 + resolvedHash 回填

    func testAddTempToRoster_多条不重复_直到上限8() {
        vm.archivedCharts = [Self.makeChart(hash: "h_a", alias: "A")]
        vm.selectedChartAIndex = 0

        // 加 7 个不同 temp(配合 1 个存档 = 8 满员)
        for i in 0..<7 {
            vm.tempBirthDate = Date(timeIntervalSince1970: TimeInterval(638_000_000 + i * 86400))
            vm.tempPlace = Self.makePlace(displayName: "城市\(i)", gid: 100 + i)
            try? vm.addTempToRoster()
        }
        XCTAssertEqual(vm.tempCountInRoster, 7)
        XCTAssertEqual(vm.roster.count, 7)

        // 第 8 个 temp(总第 8 名额,可加入)
        vm.tempBirthDate = Date(timeIntervalSince1970: 1_000_000_000)
        vm.tempPlace = Self.makePlace(displayName: "城市8", gid: 108)
        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.count, 8)

        // 第 9 个 temp 触发上限
        vm.tempBirthDate = Date(timeIntervalSince1970: 1_100_000_000)
        vm.tempPlace = Self.makePlace(displayName: "城市9", gid: 109)
        XCTAssertThrowsError(try vm.addTempToRoster(), "上限 8 必须拦截第 9 个 temp")
    }

    func testAddTempToRoster_手动经度优先于残留城市() throws {
        // S04 review:草稿会恢复上次城市;开了手动经度后手动值必须生效,
        // 不能被残留 tempPlace 静默覆盖(错误显式传播:用户输入不得丢弃)
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempPlace = Self.makePlace(displayName: "上海", longitude: 121.4737, gid: 1796236)
        vm.tempUseManualLongitude = true
        vm.tempManualLongitude = 87.62

        try vm.addTempToRoster()

        let input = try XCTUnwrap(vm.roster.first?.tempInput)
        XCTAssertEqual(input.timezone, TimeZone.current.identifier, "手动经度过渡路径用设备时区")
        XCTAssertEqual(input.longitude, 87.62, accuracy: 1e-9, "手动经度必须优先于残留城市经度")
        XCTAssertNil(input.latitude)
        XCTAssertNil(input.placeName)
        XCTAssertNil(input.geonameId)
    }

    func testTempPlaceCalendar_手动经度开启回退设备时区() {
        // WYSIWYG:表盘时区必须与请求 timezone 同源,防「表盘城市时区 / 请求设备时区」分裂
        vm.tempPlace = Self.makePlace(displayName: "洛杉矶", longitude: -118.2437,
                                      timezone: "America/Los_Angeles", gid: 5368361)
        vm.tempUseManualLongitude = false
        XCTAssertEqual(vm.tempPlaceCalendar.timeZone.identifier, "America/Los_Angeles",
                       "城市模式表盘 = 出生城市时区")
        vm.tempUseManualLongitude = true
        XCTAssertEqual(vm.tempPlaceCalendar.timeZone.identifier, TimeZone.current.identifier,
                       "手动经度模式表盘 = 设备时区(与请求构造一致)")
    }

    func testAddTempToRoster_称呼字段_空字符串视为nil() {
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempPlace = Self.makePlace(displayName: "北京")
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
        vm.tempPlace = Self.makePlace(displayName: "北京")
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
        vm.tempPlace = Self.makePlace(displayName: "测试城市", gid: 999)
        vm.tempUseManualLongitude = true
        vm.tempManualLongitude = 88.88
        vm.tempAlias = "测试"

        vm.resetTempDraftForm()

        // setUp 已 clear persistence → loadTempDraft 返回 default(硬编码)
        XCTAssertEqual(vm.tempBirthDate, Date(timeIntervalSince1970: 638_000_000))
        XCTAssertEqual(vm.tempGender, "male")
        XCTAssertNil(vm.tempPlace, "默认草稿无城市(S04 砍默认,必选)")
        XCTAssertFalse(vm.tempUseManualLongitude)
        XCTAssertEqual(vm.tempManualLongitude, 116.41)
        XCTAssertEqual(vm.tempAlias, "")  // alias 永远清空(不持久化)
    }

    // MARK: - tempDraft 持久化(下次添加默认值用上次填过的)

    func testTempDraft_roundTrip_save后load一致() {
        CompatibilityRosterPersistence.clear()
        let state = CompatibilityRosterPersistence.TempDraftState(
            birthDate: Date(timeIntervalSince1970: 700_000_000),
            gender: "female",
            place: Self.makePlace(displayName: "上海", longitude: 121.4737, gid: 1796236),
            useManualLongitude: true,
            manualLongitude: 121.47
        )
        CompatibilityRosterPersistence.saveTempDraft(state)
        let loaded = CompatibilityRosterPersistence.loadTempDraft()
        XCTAssertEqual(loaded, state)
    }

    func testTempDraft_无持久化时_load返回default() {
        CompatibilityRosterPersistence.clear()
        let loaded = CompatibilityRosterPersistence.loadTempDraft()
        XCTAssertEqual(loaded, CompatibilityRosterPersistence.defaultTempDraft)
        XCTAssertNil(loaded.place, "默认草稿无城市(S04 砍默认)")
        XCTAssertEqual(loaded.gender, "male")
    }

    func testAddTempToRoster_成功后草稿持久化_下次读到上次值() throws {
        CompatibilityRosterPersistence.clear()
        // 模拟用户改字段后添加
        vm.tempBirthDate = Date(timeIntervalSince1970: 700_000_000)
        vm.tempGender = "female"
        vm.tempPlace = Self.makePlace(displayName: "上海", longitude: 121.4737, gid: 1796236)
        vm.tempAlias = "相亲对象甲"

        try vm.addTempToRoster()  // 成功 → saveTempDraft

        // 重新 load 草稿:应得到上面的字段值
        let loaded = CompatibilityRosterPersistence.loadTempDraft()
        XCTAssertEqual(loaded.birthDate, Date(timeIntervalSince1970: 700_000_000))
        XCTAssertEqual(loaded.gender, "female")
        XCTAssertEqual(loaded.place?.displayName, "上海")
    }

    @MainActor
    func testVMInit_从持久化加载草稿字段() throws {
        CompatibilityRosterPersistence.clear()
        // 先存一个草稿
        CompatibilityRosterPersistence.saveTempDraft(.init(
            birthDate: Date(timeIntervalSince1970: 800_000_000),
            gender: "female",
            place: Self.makePlace(displayName: "广州", longitude: 113.2644, gid: 1809858),
            useManualLongitude: true,
            manualLongitude: 113.23
        ))
        // 新建 VM(init body 会 loadTempDraft)
        let newVM = CompatibilityViewModel(
            orchestrator: orchestrator,
            chartStore: chartStore,
            compatibilityStore: compatibilityStore,
            entitlementStore: entitlementStore,
            modelContext: container.mainContext
        )
        XCTAssertEqual(newVM.tempBirthDate, Date(timeIntervalSince1970: 800_000_000))
        XCTAssertEqual(newVM.tempGender, "female")
        XCTAssertEqual(newVM.tempPlace?.displayName, "广州")
        XCTAssertTrue(newVM.tempUseManualLongitude)
        XCTAssertEqual(newVM.tempManualLongitude, 113.23)
        XCTAssertEqual(newVM.tempAlias, "", "alias 不持久化,VM init 后默认空")
    }

    func testResetTempDraftForm_添加成功后_读到本次填过的字段() throws {
        CompatibilityRosterPersistence.clear()
        vm.tempBirthDate = Date(timeIntervalSince1970: 750_000_000)
        vm.tempGender = "female"
        vm.tempPlace = Self.makePlace(displayName: "深圳", longitude: 114.0579, gid: 1795565)
        vm.tempAlias = "对象A"

        try vm.addTempToRoster()
        vm.resetTempDraftForm()  // View 在 addTemp 成功后会调

        // reset 后字段应回填本次保存的草稿值(不是硬编码默认)
        XCTAssertEqual(vm.tempBirthDate, Date(timeIntervalSince1970: 750_000_000))
        XCTAssertEqual(vm.tempGender, "female")
        XCTAssertEqual(vm.tempPlace?.displayName, "深圳")
        XCTAssertEqual(vm.tempAlias, "", "alias 永远清空")
    }

    func testRosterEntry_resolvedHash_默认nil_符合S04契约() {
        // 验证 entry 字段语义,不依赖计算回填(mock orchestrator 留后续)
        let entry: RosterEntry = .temp(
            input: PersonBInput(
                birthDatetime: "1990-03-15T14:30:00",
                timezone: "Asia/Shanghai",
                gender: "male",
                longitude: 116.4074
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

    // MARK: - S06 跨启动恢复与名单持久化

    func testRosterPersistence_roundTrip_save后load一致() {
        CompatibilityRosterPersistence.clear()
        CompatibilityRosterPersistence.save(
            personAHash: "hash_a",
            context: "marriage",
            rosterHashes: ["h1", "h2", "h3"]
        )
        let loaded = CompatibilityRosterPersistence.load()
        XCTAssertEqual(loaded.personAHash, "hash_a")
        XCTAssertEqual(loaded.context, "marriage")
        XCTAssertEqual(loaded.rosterHashes, ["h1", "h2", "h3"])
    }

    func testRosterPersistence_无数据时_load返回默认() {
        CompatibilityRosterPersistence.clear()
        let loaded = CompatibilityRosterPersistence.load()
        XCTAssertNil(loaded.personAHash)
        XCTAssertEqual(loaded.context, "general", "无持久化 context 时 fallback default")
        XCTAssertTrue(loaded.rosterHashes.isEmpty)
    }

    func testRosterPersistence_cleanupInvalidHashes_剔除并写回() {
        CompatibilityRosterPersistence.clear()
        CompatibilityRosterPersistence.save(
            personAHash: "hash_a",
            context: "general",
            rosterHashes: ["valid_1", "invalid_x", "valid_2", "invalid_y"]
        )
        let isValid: (String) -> Bool = { hash in
            hash.hasPrefix("valid_")
        }
        let cleaned = CompatibilityRosterPersistence.cleanupInvalidHashes(
            persistedHashes: ["valid_1", "invalid_x", "valid_2", "invalid_y"],
            isValid: isValid
        )
        XCTAssertEqual(cleaned, ["valid_1", "valid_2"])

        // 写回应生效
        let reloaded = CompatibilityRosterPersistence.load()
        XCTAssertEqual(reloaded.rosterHashes, ["valid_1", "valid_2"])
    }

    @MainActor
    func testRestoreRosterStateIfAvailable_context和Ahash和名单预填() throws {
        CompatibilityRosterPersistence.clear()
        // 构造存档 + 同步 insert ChartSnapshot 到 SwiftData(让 chartStore.get 能找到)
        let hashes = ["a_real", "b_real", "c_real"]
        var archived: [ArchivedChart] = []
        for hash in hashes {
            let snapshot = ChartSnapshot(
                contentHash: hash,
                birthSolarTime: Date(timeIntervalSince1970: 638_000_000),
                gender: "male",
                cityLongitude: 116.41,
                ziHourRule: "zi_next_day",
                calcRuleSnapshot: Data(),
                payload: Data()
            )
            container.mainContext.insert(snapshot)
            archived.append(ArchivedChart(
                snapshotHash: hash, alias: hash.uppercased(),
                birthDate: snapshot.birthSolarTime, gender: "male",
                dayMaster: "甲", snapshot: snapshot
            ))
        }
        try container.mainContext.save()
        vm.archivedCharts = archived

        // 持久化设置 a_real 为 A,context = marriage,名单 [b_real, c_real]
        CompatibilityRosterPersistence.save(
            personAHash: "a_real",
            context: "marriage",
            rosterHashes: ["b_real", "c_real"]
        )

        vm.restoreRosterStateIfAvailable()

        XCTAssertEqual(vm.context, "marriage")
        XCTAssertEqual(vm.currentPersonAHash, "a_real")
        XCTAssertEqual(vm.roster.count, 2)
        XCTAssertTrue(vm.selectedArchivedHashes.contains("b_real"))
        XCTAssertTrue(vm.selectedArchivedHashes.contains("c_real"))
    }

    @MainActor
    func testRestoreRosterStateIfAvailable_Ahash失效_fallback最新link() {
        CompatibilityRosterPersistence.clear()
        // 构造存档:archivedCharts 已是 createdAt DESC(模拟 loadArchivedCharts 行为)
        // A hash 失效 fallback 不需要 ChartSnapshot 存在,因为名单空,不会触发 isValid 校验
        vm.archivedCharts = [
            Self.makeChart(hash: "new_link", alias: "New"),
            Self.makeChart(hash: "old_link", alias: "Old"),
        ]
        // 持久化一个失效的 A hash
        CompatibilityRosterPersistence.save(
            personAHash: "deleted_link",
            context: "general",
            rosterHashes: []
        )

        vm.restoreRosterStateIfAvailable()

        // 失效 → fallback 最新 link = new_link(archivedCharts 首位)
        XCTAssertEqual(vm.currentPersonAHash, "new_link")
    }

    @MainActor
    func testRestoreRosterStateIfAvailable_名单含无效hash_静默剔除() throws {
        CompatibilityRosterPersistence.clear()
        // 真存档:把 a_real ChartSnapshot 插入(让 aHash 有效),不插 ghost_hash
        let aSnapshot = ChartSnapshot(
            contentHash: "a_real",
            birthSolarTime: Date(timeIntervalSince1970: 638_000_000),
            gender: "male",
            cityLongitude: 116.41,
            ziHourRule: "zi_next_day",
            calcRuleSnapshot: Data(),
            payload: Data()
        )
        container.mainContext.insert(aSnapshot)
        try container.mainContext.save()
        vm.archivedCharts = [ArchivedChart(
            snapshotHash: "a_real", alias: "A",
            birthDate: aSnapshot.birthSolarTime, gender: "male",
            dayMaster: "甲", snapshot: aSnapshot
        )]

        // 持久化名单含无效 hash(无 ChartSnapshot 对应)
        CompatibilityRosterPersistence.save(
            personAHash: "a_real",
            context: "general",
            rosterHashes: ["ghost_hash"]  // 没有 ChartSnapshot,校验失败
        )

        vm.restoreRosterStateIfAvailable()

        XCTAssertEqual(vm.roster.count, 0, "无效 hash 应剔除,名单变空")
        XCTAssertTrue(vm.selectedArchivedHashes.isEmpty)

        // 持久化名单也应已写回干净(空数组)
        let reloaded = CompatibilityRosterPersistence.load()
        XCTAssertTrue(reloaded.rosterHashes.isEmpty)
    }

    @MainActor
    func testRestoreRosterStateIfAvailable_0存档_不恢复() {
        CompatibilityRosterPersistence.clear()
        CompatibilityRosterPersistence.save(
            personAHash: "x", context: "general", rosterHashes: ["y"]
        )
        vm.archivedCharts = []  // 0 存档
        vm.restoreRosterStateIfAvailable()
        // 应跳过(走 .empty 流程)
        XCTAssertEqual(vm.context, "general")  // context 仍是 VM 默认
        XCTAssertTrue(vm.roster.isEmpty)
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
        vm.tempPlace = Self.makePlace(displayName: "上海", longitude: 121.4737, gid: 1796236)
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
        vm.tempPlace = Self.makePlace(displayName: "北京")
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
