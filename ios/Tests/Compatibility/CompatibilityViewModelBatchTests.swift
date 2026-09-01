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
        XCTAssertThrowsError(try vm.addTempToRoster()) { error in
            XCTAssertTrue(error.localizedDescription.contains("出生城市"))
        }
    }

    func testAddTempToRoster_自定义地点经度越界_抛错() {
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempPlace = .custom(longitude: 999.0, timezone: "Etc/GMT-8")
        XCTAssertThrowsError(try vm.addTempToRoster()) { error in
            XCTAssertTrue(error.localizedDescription.contains("经度"))
        }
    }

    func testAddTempToRoster_多条独立_不替换_S04改造() {
        // S04 改造:不再替换,而是 append 多条
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempGender = "male"
        vm.tempPlace = .city(Self.makePlace(displayName: "北京", gid: 1816670))

        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.filter(\.isTemp).count, 1)

        // S04:再加一次,出生时间不同 → 名单内 2 条独立 temp
        vm.tempBirthDate = Date(timeIntervalSince1970: 700_000_000)
        vm.tempPlace = .city(Self.makePlace(displayName: "上海", longitude: 121.4737, gid: 1796236))
        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.filter(\.isTemp).count, 2, "S04 改造:多条独立 temp,不再替换")
    }

    func testAddTempToRoster_相同临时人_去重拒绝() {
        // review 修复 1:两个完全相同 input(同时间/性别/城市/alias)→ 同 entry.id → 第二次抛错
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempGender = "male"
        vm.tempPlace = .city(Self.makePlace(displayName: "北京", gid: 1816670))
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
            vm.tempPlace = .city(Self.makePlace(displayName: "城市\(i)", gid: 100 + i))
            try? vm.addTempToRoster()
        }
        XCTAssertEqual(vm.tempCountInRoster, 7)
        XCTAssertEqual(vm.roster.count, 7)

        // 第 8 个 temp(总第 8 名额,可加入)
        vm.tempBirthDate = Date(timeIntervalSince1970: 1_000_000_000)
        vm.tempPlace = .city(Self.makePlace(displayName: "城市8", gid: 108))
        try? vm.addTempToRoster()
        XCTAssertEqual(vm.roster.count, 8)

        // 第 9 个 temp 触发上限
        vm.tempBirthDate = Date(timeIntervalSince1970: 1_100_000_000)
        vm.tempPlace = .city(Self.makePlace(displayName: "城市9", gid: 109))
        XCTAssertThrowsError(try vm.addTempToRoster(), "上限 8 必须拦截第 9 个 temp")
    }

    func testAddTempToRoster_自定义地点显式时区() throws {
        // S05:自定义地点 timezone 显式(不再默认设备时区);place_name=自定义地点
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempPlace = .custom(longitude: 87.62, timezone: "Asia/Urumqi")

        try vm.addTempToRoster()

        let input = try XCTUnwrap(vm.roster.first?.tempInput)
        XCTAssertEqual(input.timezone, "Asia/Urumqi")
        XCTAssertEqual(input.longitude, 87.62, accuracy: 1e-9)
        XCTAssertNil(input.latitude)
        XCTAssertEqual(input.placeName, "自定义地点")
        XCTAssertNil(input.geonameId)
    }

    func testTempPlaceCalendar_自定义地点用显式时区() {
        // WYSIWYG:表盘时区必须与请求 timezone 同源(城市 / 自定义地点两分支)
        vm.tempPlace = .custom(longitude: 87.62, timezone: "Asia/Urumqi")
        XCTAssertEqual(vm.tempPlaceCalendar.timeZone.identifier, "Asia/Urumqi")
        vm.tempPlace = .city(Self.makePlace(displayName: "洛杉矶", longitude: -118.2437,
                                             timezone: "America/Los_Angeles", gid: 5368361))
        XCTAssertEqual(vm.tempPlaceCalendar.timeZone.identifier, "America/Los_Angeles")
    }

    func testAddTempToRoster_称呼字段_空字符串视为nil() {
        vm.tempBirthDate = Date(timeIntervalSince1970: 638_000_000)
        vm.tempPlace = .city(Self.makePlace(displayName: "北京"))
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
        vm.tempPlace = .city(Self.makePlace(displayName: "北京"))
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
        vm.tempPlace = .city(Self.makePlace(displayName: "测试城市", gid: 999))
        vm.tempAlias = "测试"

        vm.resetTempDraftForm()

        // setUp 已 clear persistence → loadTempDraft 返回 default(硬编码)
        XCTAssertEqual(vm.tempBirthDate, Date(timeIntervalSince1970: 638_000_000))
        XCTAssertEqual(vm.tempGender, "male")
        XCTAssertNil(vm.tempPlace, "默认草稿无地点(S04 砍默认,必选)")
        XCTAssertEqual(vm.tempAlias, "")  // alias 永远清空(不持久化)
    }

    // MARK: - tempDraft 持久化(下次添加默认值用上次填过的)

    func testTempDraft_roundTrip_save后load一致() {
        CompatibilityRosterPersistence.clear()
        let state = CompatibilityRosterPersistence.TempDraftState(
            birthDate: Date(timeIntervalSince1970: 700_000_000),
            gender: "female",
            place: .city(Self.makePlace(displayName: "上海", longitude: 121.4737, gid: 1796236))
        )
        CompatibilityRosterPersistence.saveTempDraft(state)
        let loaded = CompatibilityRosterPersistence.loadTempDraft()
        XCTAssertEqual(loaded, state)
    }

    func testTempDraft_roundTrip_自定义地点_place编码形状钉死() {
        // S05:PlaceSelection.custom 的 Codable 是编译器合成,round-trip 钉住编码形状
        // (合成行为变化不应静默走「日志+草稿丢失」降级路径)
        CompatibilityRosterPersistence.clear()
        let state = CompatibilityRosterPersistence.TempDraftState(
            birthDate: Date(timeIntervalSince1970: 700_000_000),
            gender: "female",
            place: .custom(longitude: 87.62, timezone: "Asia/Urumqi")
        )
        CompatibilityRosterPersistence.saveTempDraft(state)
        let loaded = CompatibilityRosterPersistence.loadTempDraft()
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.place?.displayLabel, "自定义地点 · GMT+6")
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
        vm.tempPlace = .city(Self.makePlace(displayName: "上海", longitude: 121.4737, gid: 1796236))
        vm.tempAlias = "相亲对象甲"

        try vm.addTempToRoster()  // 成功 → saveTempDraft

        // 重新 load 草稿:应得到上面的字段值
        let loaded = CompatibilityRosterPersistence.loadTempDraft()
        XCTAssertEqual(loaded.birthDate, Date(timeIntervalSince1970: 700_000_000))
        XCTAssertEqual(loaded.gender, "female")
        XCTAssertEqual(loaded.place?.displayLabel, "上海, 中国")
    }

    @MainActor
    func testVMInit_从持久化加载草稿字段() throws {
        CompatibilityRosterPersistence.clear()
        // 先存一个草稿
        CompatibilityRosterPersistence.saveTempDraft(.init(
            birthDate: Date(timeIntervalSince1970: 800_000_000),
            gender: "female",
            place: .city(Self.makePlace(displayName: "广州", longitude: 113.2644, gid: 1809858))
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
        XCTAssertEqual(newVM.tempPlace?.displayLabel, "广州, 中国")
        XCTAssertEqual(newVM.tempAlias, "", "alias 不持久化,VM init 后默认空")
    }

    func testResetTempDraftForm_添加成功后_读到本次填过的字段() throws {
        CompatibilityRosterPersistence.clear()
        vm.tempBirthDate = Date(timeIntervalSince1970: 750_000_000)
        vm.tempGender = "female"
        vm.tempPlace = .city(Self.makePlace(displayName: "深圳", longitude: 114.0579, gid: 1795565))
        vm.tempAlias = "对象A"

        try vm.addTempToRoster()
        vm.resetTempDraftForm()  // View 在 addTemp 成功后会调

        // reset 后字段应回填本次保存的草稿值(不是硬编码默认)
        XCTAssertEqual(vm.tempBirthDate, Date(timeIntervalSince1970: 750_000_000))
        XCTAssertEqual(vm.tempGender, "female")
        XCTAssertEqual(vm.tempPlace?.displayLabel, "深圳, 中国")
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
    func testRestoreRosterStateIfAvailable_持久化context被忽略_Ahash和名单预填() throws {
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

        // 2026-08-16 维度 picker 移除:context 固定 "general",持久化的 marriage 被忽略
        XCTAssertEqual(vm.context, "general")
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
        vm.tempPlace = .city(Self.makePlace(displayName: "上海", longitude: 121.4737, gid: 1796236))
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
        vm.tempPlace = .city(Self.makePlace(displayName: "北京"))
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

    // MARK: - S07 时辰未知对级拦截(任一方无时辰 → 整对拦,免费亦拦)

    /// 构造指定时辰状态的命盘并落档,返回可直接喂 VM 的 ArchivedChart。
    /// hourKnown=false 时柱缺失(时辰未知);dayPresent=false 再叠加日柱歧义。
    @discardableResult
    private func insertChart(
        hash: String,
        alias: String,
        hourKnown: Bool,
        dayPresent: Bool = true
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
            pillars: PillarsDTO(
                year: pillar, month: pillar,
                day: dayPresent ? pillar : nil,
                hour: hourKnown ? pillar : nil
            ),
            mingGong: ganzhi, shenGong: ganzhi, taiYuan: ganzhi,
            elementBalance: ElementBalanceDTO(wood: 2, fire: 1, earth: 1, metal: 1, water: 3),
            favorableElements: ["木", "水"], unfavorableElements: ["土"],
            dayMasterStrength: dayPresent ? "balanced" : "unknown_hour",
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
                pillarAmbiguity: dayPresent ? nil : PillarAmbiguityDTO(day: true)
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
            dayMaster: dayPresent ? "甲" : "—",
            snapshot: result.snapshot
        )
    }

    /// 轮询等待 compute() 的 Task 落到 .list(compute 是 async Task,断言需等待)。
    private func waitForListState(timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if vm.state == .list { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return vm.state == .list
    }

    func testCompute_A盘无时辰_全部对拦截态_零合盘快照() async throws {
        let chartA = try insertChart(hash: "s07_a_unknown", alias: "A", hourKnown: false)
        let chartB = try insertChart(hash: "s07_b_known", alias: "B", hourKnown: true)
        vm.archivedCharts = [chartA, chartB]
        vm.selectedChartAIndex = 0
        vm.roster = [.archived(snapshotHash: "s07_b_known")]

        vm.compute()
        let reached = await waitForListState()
        XCTAssertTrue(reached, "compute 应正常进入 .list,实际:\(vm.state)")

        let summary = try XCTUnwrap(vm.summaries.first)
        XCTAssertTrue(summary.isHourUnknownBlocked, "A 盘无时辰 → 该对整对拦截(免费亦拦),实际:\(summary.status)")
        XCTAssertEqual(summary.personBHash, "s07_b_known", "拦截对保留存档对方 hash(roster 持久化需要)")

        // 零 API 调用证明:没有产生任何 CompatibilitySnapshot(阶段 1 从未发起)
        let snapshots = try compatibilityStore.list(personAHash: "s07_a_unknown", context: "general")
        XCTAssertTrue(snapshots.isEmpty, "拦截对不得发起确定性合盘(后端契约必 422)")

        // 拦截对的存档 hash 保留在持久化名单(该人仍在名单,补时辰后重算)
        let persisted = CompatibilityRosterPersistence.load()
        XCTAssertEqual(persisted.rosterHashes, ["s07_b_known"])
    }

    func testCompute_B盘无时辰_仅该对拦截_其余照算() async throws {
        let chartA = try insertChart(hash: "s07_a2_known", alias: "A", hourKnown: true)
        let chartBUnknown = try insertChart(hash: "s07_b2_unknown", alias: "B无时辰", hourKnown: false)
        vm.archivedCharts = [chartA, chartBUnknown]
        vm.selectedChartAIndex = 0
        vm.roster = [
            .archived(snapshotHash: "s07_b2_unknown"),
            .temp(
                input: PersonBInput(
                    birthDatetime: "1992-08-08T10:00:00",
                    timezone: "Asia/Shanghai",
                    gender: "female",
                    longitude: 116.4074
                ),
                alias: "临时人",
                resolvedHash: nil
            ),
        ]

        vm.compute()
        let reached = await waitForListState()
        XCTAssertTrue(reached, "compute 应正常进入 .list,实际:\(vm.state)")
        XCTAssertEqual(vm.summaries.count, 2)

        let blocked = vm.summaries.first { $0.displayName == "B无时辰" }
        XCTAssertTrue(blocked?.isHourUnknownBlocked == true, "存档 B 无时辰 → 该对拦截(对级隔离)")

        let tempPair = vm.summaries.first { $0.displayName == "临时人" }
        XCTAssertTrue(tempPair?.isComputed == true, "双方有时辰的临时对照常计算(回归)")

        // 只有临时对产生快照;拦截对零阶段 1 调用
        let snapshots = try compatibilityStore.list(personAHash: "s07_a2_known", context: "general")
        XCTAssertEqual(snapshots.count, 1, "仅临时对落快照")
    }

    func testCompute_双方有时辰_回归照算() async throws {
        let chartA = try insertChart(hash: "s07_a3_known", alias: "A", hourKnown: true)
        let chartB = try insertChart(hash: "s07_b3_known", alias: "B", hourKnown: true)
        vm.archivedCharts = [chartA, chartB]
        vm.selectedChartAIndex = 0
        vm.roster = [.archived(snapshotHash: "s07_b3_known")]

        vm.compute()
        let reached = await waitForListState()
        XCTAssertTrue(reached, "compute 应正常进入 .list,实际:\(vm.state)")

        let summary = try XCTUnwrap(vm.summaries.first)
        XCTAssertTrue(summary.isComputed, "双方有时辰 → 行为与现状完全一致,实际:\(summary.status)")
    }

    func testGenerateInterpretation_任一方无时辰_阶段2拦截_不消耗次数() async throws {
        // A 无时辰 + B 有时辰的 detail 态(正常路径拦截对进不了 detail,此处直构状态机)
        let chartA = try insertChart(hash: "s07_a4_unknown", alias: "A", hourKnown: false)
        let chartB = try insertChart(hash: "s07_b4_known", alias: "B", hourKnown: true)
        vm.archivedCharts = [chartA, chartB]
        vm.selectedChartAIndex = 0

        let summary = PairSummary(
            id: "s07_compat_hash",
            entry: .archived(snapshotHash: "s07_b4_known"),
            personBHash: "s07_b4_known",
            displayName: "B",
            birthDate: nil,
            dayMaster: "甲",
            fiveElements: "互补",
            dayMasterRelation: "同气",
            compatibilityHash: "s07_compat_hash",
            isInterpreted: false,
            status: .computed
        )
        let response = CompatibilityResponse(
            compatibilityHash: "s07_compat_hash",
            personAChart: nil,
            personBChart: nil,
            qualitativeAssessment: QualitativeAssessmentDTO(
                fiveElements: "互补", dayMasterRelation: "同气",
                zodiacMatch: "六合", branchHarmony: "无冲无刑"
            ),
            syncedFortune: [],
            calcRuleSnapshot: nil
        )
        vm.state = .detail(summary, response, .idle)

        let readsBefore = vm.remainingReads
        vm.generateInterpretation()

        // 阶段 2 拦截:interpretState 显式 .failed(免费亦拦,不静默吞)
        let deadline = Date().addingTimeInterval(5)
        var blocked = false
        while Date() < deadline {
            if case .detail(_, _, .failed) = vm.state { blocked = true; break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(blocked, "任一方无时辰 → 阶段 2(AI 解读)拦截态,实际:\(vm.state)")
        if case .detail(_, _, .failed(let message)) = vm.state {
            // 文案走 L10n(zh「时辰」/ en「hour」),断言按 locale 双语兼容
            XCTAssertTrue(
                message.contains("时辰") || message.lowercased().contains("hour"),
                "拦截文案须指向补时辰,实际:\(message)"
            )
        }
        XCTAssertEqual(vm.remainingReads, readsBefore, "拦截发生在次数检查之前,不得消耗每日配额")
    }

    // MARK: - S11 roster 不可合盘标记(判据 = 本地 payload,零网络;与 S07 拦截同源)

    func testToggleArchived_他人无时辰_拒绝入名单() throws {
        // S11 发起前最早层拦截:无时辰他人不可勾入名单(点击轻提示在 View 层)
        let chartA = try insertChart(hash: "s11_a_known", alias: "A", hourKnown: true)
        let chartBUnknown = try insertChart(hash: "s11_b_unknown", alias: "B无时辰", hourKnown: false)
        vm.archivedCharts = [chartA, chartBUnknown]
        vm.selectedChartAIndex = 0

        vm.toggleArchived(hash: "s11_b_unknown")
        XCTAssertTrue(vm.roster.isEmpty, "他人无时辰 → 不可入名单(VM 守卫兜住所有调用路径)")
    }

    func testToggleArchived_他人无时辰_已在名单_移除照常() throws {
        // 跨启动恢复的拦截对:hash 保留在名单(S07 语义),移除语义必须照常
        let chartA = try insertChart(hash: "s11_a2_known", alias: "A", hourKnown: true)
        let chartBUnknown = try insertChart(hash: "s11_b2_unknown", alias: "B无时辰", hourKnown: false)
        vm.archivedCharts = [chartA, chartBUnknown]
        vm.selectedChartAIndex = 0
        vm.roster = [.archived(snapshotHash: "s11_b2_unknown")]

        vm.toggleArchived(hash: "s11_b2_unknown")
        XCTAssertTrue(vm.roster.isEmpty, "已在名单的无时辰对方,移除照常(toggle 前半段不受 S11 守卫影响)")
    }

    func testIsPairHourUnknownBlocked_分支覆盖_对方无时辰_双方有时辰_临时人() throws {
        let chartA = try insertChart(hash: "s11_a3_known", alias: "A", hourKnown: true)
        let chartBKnown = try insertChart(hash: "s11_b3_known", alias: "B有时辰", hourKnown: true)
        let chartBUnknown = try insertChart(hash: "s11_b3_unknown", alias: "C无时辰", hourKnown: false)
        vm.archivedCharts = [chartA, chartBKnown, chartBUnknown]
        vm.selectedChartAIndex = 0

        let tempEntry: RosterEntry = .temp(
            input: PersonBInput(
                birthDatetime: "1992-08-08T10:00:00",
                timezone: "Asia/Shanghai",
                gender: "female",
                longitude: 116.4074
            ),
            alias: nil,
            resolvedHash: nil
        )

        XCTAssertFalse(vm.isPairHourUnknownBlocked(entry: .archived(snapshotHash: "s11_b3_known")),
                       "双方有时辰 → 不标记(行为与现状完全一致)")
        XCTAssertTrue(vm.isPairHourUnknownBlocked(entry: .archived(snapshotHash: "s11_b3_unknown")),
                      "他人无时辰 → 该对标记")
        XCTAssertFalse(vm.isPairHourUnknownBlocked(entry: tempEntry),
                       "临时人 PersonBInput 恒带完整钟面,无时辰语义不存在 → 不标记")
    }

    func testIsSelfHourUnknown_自己无时辰_全部对不可用_切换A盘翻转() throws {
        let chartAUnknown = try insertChart(hash: "s11_a4_unknown", alias: "A无时辰", hourKnown: false)
        let chartBKnown = try insertChart(hash: "s11_b4_known", alias: "B有时辰", hourKnown: true)
        let chartAKnown = try insertChart(hash: "s11_a4b_known", alias: "A2有时辰", hourKnown: true)
        vm.archivedCharts = [chartAUnknown, chartBKnown, chartAKnown]
        vm.selectedChartAIndex = 0

        XCTAssertTrue(vm.isSelfHourUnknown, "自己无时辰 → 名单整体标记数据源(解释行 + CTA 不可发起)")
        XCTAssertTrue(vm.isPairHourUnknownBlocked(entry: .archived(snapshotHash: "s11_b4_known")),
                      "自己无时辰 → 对方有时辰的该对也不可用")
        let tempEntry: RosterEntry = .temp(
            input: PersonBInput(
                birthDatetime: "1993-01-01T09:00:00",
                timezone: "Asia/Shanghai",
                gender: "male",
                longitude: 116.4074
            ),
            alias: nil,
            resolvedHash: nil
        )
        XCTAssertTrue(vm.isPairHourUnknownBlocked(entry: tempEntry), "自己无时辰 → 全部对不可用(含临时人)")

        // 切到有时辰的 A 盘 → 整体标记消失(判据随选中盘翻转)
        vm.selectedChartAIndex = 2
        XCTAssertFalse(vm.isSelfHourUnknown)
        XCTAssertFalse(vm.isPairHourUnknownBlocked(entry: .archived(snapshotHash: "s11_b4_known")))
        XCTAssertFalse(vm.isPairHourUnknownBlocked(entry: tempEntry))
    }

    func testS11_补时辰翻转_标记消失_可发起() throws {
        // S10 他人盘补时辰 → payload 替换 → 标记翻转(此处以同 hash 重 upsert 模拟;
        // 实际 S10 是新 hash 新盘,判据同为「现读 payload」,翻转行为一致)
        let chartA = try insertChart(hash: "s11_a5_known", alias: "A", hourKnown: true)
        let chartBUnknown = try insertChart(hash: "s11_b5_unknown", alias: "B", hourKnown: false)
        vm.archivedCharts = [chartA, chartBUnknown]
        vm.selectedChartAIndex = 0

        XCTAssertTrue(vm.isArchivedHourUnknown(hash: "s11_b5_unknown"), "补时辰前:该对标记")
        vm.toggleArchived(hash: "s11_b5_unknown")
        XCTAssertTrue(vm.roster.isEmpty, "补时辰前:不可入名单")

        // 模拟补时辰:同 hash 重新 upsert 带时辰 payload(upsert 按 contentHash 原地更新)
        _ = try insertChart(hash: "s11_b5_unknown", alias: "B", hourKnown: true)

        XCTAssertFalse(vm.isArchivedHourUnknown(hash: "s11_b5_unknown"), "补时辰后:标记消失")
        XCTAssertFalse(vm.isPairHourUnknownBlocked(entry: .archived(snapshotHash: "s11_b5_unknown")),
                       "补时辰后:该对可发起")
        vm.toggleArchived(hash: "s11_b5_unknown")
        XCTAssertEqual(vm.roster.count, 1, "补时辰后:可入名单(按新盘走)")
    }

    func testIsPairHourUnknownBlocked_跨启动恢复entry_不在archivedCharts_走chartStore判据() throws {
        // S06 恢复路径:临时人持久化为 .archived hash,无 link 不进 archivedCharts
        let chartA = try insertChart(hash: "s11_a6_known", alias: "A", hourKnown: true)
        _ = try insertChart(hash: "s11_b6_unknown", alias: "恢复的无时辰盘", hourKnown: false)
        vm.archivedCharts = [chartA]
        vm.selectedChartAIndex = 0

        XCTAssertTrue(vm.isPairHourUnknownBlocked(entry: .archived(snapshotHash: "s11_b6_unknown")),
                      "不在 archivedCharts 的 hash → 走 chartStore payload 判据")
        XCTAssertFalse(vm.isPairHourUnknownBlocked(entry: .archived(snapshotHash: "ghost_hash_s11")),
                       "快照缺失 → 放行不误标(真正错误由 computePair 对级隔离呈现)")
    }

    func testArchivedHourGate_payload解码失败_放行不误标() throws {
        // 直接插一个 payload 为垃圾字节的 ChartSnapshot(不经 upsert)
        let bad = ChartSnapshot(
            contentHash: "s11_bad_payload",
            birthSolarTime: Date(timeIntervalSince1970: 638_000_000),
            gender: "male",
            cityLongitude: 116.41,
            ziHourRule: "zi_next_day",
            calcRuleSnapshot: Data(),
            payload: Data("not-json".utf8)
        )
        container.mainContext.insert(bad)
        try container.mainContext.save()

        let chartA = try insertChart(hash: "s11_a7_known", alias: "A", hourKnown: true)
        vm.archivedCharts = [chartA]
        vm.selectedChartAIndex = 0

        // decode 失败显式记日志后按 .hourKnown 放行(对齐 S07 currentDetailHourUnknownGate
        // 先例:标记层不用拦截态掩盖解码故障,发起路径会再 decode 并对级传播错误)
        XCTAssertFalse(vm.isArchivedHourUnknown(hash: "s11_bad_payload"),
                       "decode 失败 → 放行(日志显式记录,不静默吞)")
    }

    // MARK: - S11 发起前拦截 = 唯一防线(2026-09-01 review:S01 已放开 ChartPayload Literal,
    // 后端不再是 422 兜底,VM 层拦截必须真正拦住)

    /// 用记录型客户端装配第二个 VM(绕过 UI 直调发起的零请求断言用)。
    private func makeRecordingVM(api: APIClient) -> CompatibilityViewModel {
        let context = container.mainContext
        let interpretStore = InterpretationCacheStore(context: context)
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: api),
            cacheStore: interpretStore
        )
        let recordingOrchestrator = CompatibilityOrchestrator(
            apiClient: api,
            compatibilityStore: compatibilityStore,
            chartStore: chartStore,
            interpretStore: interpretStore,
            counter: DailyReadCounter(),
            interpretationReader: reader
        )
        return CompatibilityViewModel(
            orchestrator: recordingOrchestrator,
            chartStore: chartStore,
            compatibilityStore: compatibilityStore,
            entitlementStore: entitlementStore,
            modelContext: context
        )
    }

    /// 轮询等待指定 VM 的 compute() Task 落到 .list(param 版,绕过 UI 用例的第二个 VM 用)。
    private func waitForListState(
        of target: CompatibilityViewModel, timeout: TimeInterval = 8
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.state == .list { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return target.state == .list
    }

    func testS11_绕过UI直调compute_无时辰对_VM层先拦_零网络请求_错误不外溢() async throws {
        // 录制双打模拟 S01 已放开 Literal 的后端:拦截失效时请求会被放行并记录,
        // 计数 > 0 即防线失守(不再有 422 兜底,2026-09-01 review 更正)
        let recording = S11RecordingAPIClient()
        let rvm = makeRecordingVM(api: recording)

        let chartA = try insertChart(hash: "s11_v_a_known", alias: "A", hourKnown: true)
        let bUnknown = try insertChart(hash: "s11_v_b_unknown", alias: "B无时辰", hourKnown: false)
        let bAmbiguous = try insertChart(hash: "s11_v_b_ambiguous", alias: "C日柱歧义", hourKnown: false, dayPresent: false)
        rvm.archivedCharts = [chartA, bUnknown, bAmbiguous]
        rvm.selectedChartAIndex = 0
        // 绕过 UI:toggleArchived 的 S11 守卫被跳过,名单直塞后发起
        rvm.roster = [
            .archived(snapshotHash: "s11_v_b_unknown"),
            .archived(snapshotHash: "s11_v_b_ambiguous"),
        ]

        rvm.compute()
        let reached = await waitForListState(of: rvm)
        XCTAssertTrue(reached, "拦截对不炸整体:compute 照常落 .list,实际:\(rvm.state)")

        XCTAssertEqual(rvm.summaries.count, 2)
        for summary in rvm.summaries {
            XCTAssertTrue(summary.isHourUnknownBlocked,
                          "VM 层先拦:无时辰对产拦截卡(免费亦拦),实际:\(summary.status)")
        }
        // 错误不外溢:无对级 .failed、无整体 .failed 态
        XCTAssertFalse(rvm.summaries.contains { summary in
            if case .failed = summary.status { return true }
            return false
        }, "拦截是设计态不是错误,不得以 .failed 外溢")
        if case .failed = rvm.state {
            XCTFail("整体状态不得因拦截对进入 .failed,实际:\(rvm.state)")
        }

        let compatCalls = await recording.compatibilityCallCount()
        let interpretCalls = await recording.interpretCallCount()
        XCTAssertEqual(compatCalls, 0, "发起前拦截 = 唯一防线:零 compatibility 请求(不依赖后端 422)")
        XCTAssertEqual(interpretCalls, 0, "拦截对连 interpret 也不发起")
        XCTAssertTrue(
            try compatibilityStore.list(personAHash: "s11_v_a_known", context: "general").isEmpty,
            "零网络请求佐证:无任何 CompatibilitySnapshot 落库"
        )
    }

    func testS11_绕过UI直调generateInterpretation_无时辰对_零interpret请求() async throws {
        let recording = S11RecordingAPIClient()
        let rvm = makeRecordingVM(api: recording)

        let chartA = try insertChart(hash: "s11_v2_a_known", alias: "A", hourKnown: true)
        let chartBUnknown = try insertChart(hash: "s11_v2_b_unknown", alias: "B无时辰", hourKnown: false)
        rvm.archivedCharts = [chartA, chartBUnknown]
        rvm.selectedChartAIndex = 0

        // 直构 detail 态:拦截对正常进不了 detail(computePair 已拦)——
        // 这正是「绕过 UI」的模拟(购买回调 / 状态机错乱同款路径)
        let summary = PairSummary(
            id: "s11_v2_compat",
            entry: .archived(snapshotHash: "s11_v2_b_unknown"),
            personBHash: "s11_v2_b_unknown",
            displayName: "B无时辰",
            birthDate: nil,
            dayMaster: "—",
            fiveElements: "",
            dayMasterRelation: "",
            compatibilityHash: "s11_v2_compat",
            isInterpreted: false,
            status: .computed
        )
        let response = CompatibilityResponse(
            compatibilityHash: "s11_v2_compat",
            personAChart: nil,
            personBChart: nil,
            qualitativeAssessment: QualitativeAssessmentDTO(
                fiveElements: "互补", dayMasterRelation: "同气",
                zodiacMatch: "六合", branchHarmony: "无冲无刑"
            ),
            syncedFortune: [],
            calcRuleSnapshot: nil
        )
        rvm.state = .detail(summary, response, .idle)

        rvm.generateInterpretation()

        // 阶段 2 拦截:interpretState 显式 .failed(不静默吞,也不外溢为 crash/整体态)
        let deadline = Date().addingTimeInterval(5)
        var blocked = false
        while Date() < deadline {
            if case .detail(_, _, .failed) = rvm.state { blocked = true; break }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(blocked, "无时辰对直调 generateInterpretation → 阶段 2 拦截态,实际:\(rvm.state)")

        let interpretCalls = await recording.interpretCallCount()
        let compatCalls = await recording.compatibilityCallCount()
        XCTAssertEqual(interpretCalls, 0, "发起前拦截 = 唯一防线:零 interpret 请求")
        XCTAssertEqual(compatCalls, 0)
    }
}

// MARK: - S11 记录型 API 双打(发起前拦截 = 唯一防线断言)

private enum S11TestError: Error {
    case unexpectedCall
}

/// compatibility / interpret 记录并返回合法夹具——模拟 S01 已放开 Literal 的
/// 后端(VM 拦截失效时请求会被放行并记录,计数 > 0 即防线失守);其余端点
/// 被调即抛错(负向哨兵,对齐 RecordingDailyAPIClient 手法)。
private actor S11RecordingAPIClient: APIClient {
    private var compatibilityRequests: [CompatibilityRequest] = []
    private var interpretRequests: [InterpretRequest] = []

    func compatibilityCallCount() -> Int { compatibilityRequests.count }
    func interpretCallCount() -> Int { interpretRequests.count }

    func health() async throws -> HealthResponse {
        HealthResponse(
            status: "ok",
            lunarPythonVersion: "1.4.8",
            model: "s11-recording-test",
            aiProvider: "anthropic",
            aiModel: "claude-test"
        )
    }

    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse {
        compatibilityRequests.append(request)
        return CompatibilityResponse(
            compatibilityHash: "s11_leaked_pair",
            personAChart: nil,
            personBChart: nil,
            qualitativeAssessment: QualitativeAssessmentDTO(
                fiveElements: "互补", dayMasterRelation: "同气",
                zodiacMatch: "六合", branchHarmony: "无冲无刑"
            ),
            syncedFortune: [],
            calcRuleSnapshot: nil
        )
    }

    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        interpretRequests.append(request)
        return InterpretResponse(
            interpretation: "拦截失效哨兵:此解读不应出现",
            promptVersion: 1,
            cached: false,
            generatedAt: .now,
            provider: "anthropic",
            model: "claude-test",
            language: AppLanguage.current
        )
    }

    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        throw S11TestError.unexpectedCall
    }
    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse {
        throw S11TestError.unexpectedCall
    }
            func redeem(request: EntitlementRedeemRequest) async throws -> EntitlementRedeemResponse {
        throw S11TestError.unexpectedCall
    }
    func entitlementList() async throws -> EntitlementListResponse {
        throw S11TestError.unexpectedCall
    }
    func signIn(request: SignInRequest) async throws -> SignInResponse {
        throw S11TestError.unexpectedCall
    }
    func syncPull() async throws -> SyncPullResponse {
        throw S11TestError.unexpectedCall
    }
    func syncPush(request: SyncPushRequest) async throws -> SyncPushResponse {
        throw S11TestError.unexpectedCall
    }
}
