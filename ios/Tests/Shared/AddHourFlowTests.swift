import SwiftData
import SwiftUI
import XCTest
@testable import QiCompass

/// S10 补时辰升级闭环测试(docs/时辰未知-slices/S10)。
///
/// 覆盖 slice 验收:
/// - **hash 重建**:submit → 新 content_hash ≠ 老盘;老盘归档保留(不删);
///   请求 = 「原出生日期 + 新时辰 + 原 gender/place」,`hour_known=true` + `late_night` 清空
/// - **补后判据翻转**:新 payload `hour_known=true` → `hourUnknownGate == .hourKnown`,
///   付费墙拦截判据 `isPurchaseIntercepted` 翻回 false(价格与购买恢复)
/// - **静默态开关**:`hour_unknown_accepted` 写穿 payload(decodeIfPresent 老盘兼容);
///   开 → 三触点判据翻静默;关 → 恢复提示
/// - **触点路由**:合盘拦截卡目标盘路由(`addHourTargetHash(forBlockedPair:)`)/
///   每日运势静默判据(`refreshHourFlags`)/ roster hash remap / 渲染冒烟
@MainActor
final class AddHourFlowTests: XCTestCase {

    private var container: ModelContainer!
    private var apiClient: MockAPIClient!
    private var chartStore: ChartSnapshotStore!
    private var linkStore: UserSnapshotLinkStore!
    private var orchestrator: DeepAnalysisOrchestrator!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        apiClient = MockAPIClient()
        chartStore = ChartSnapshotStore(context: context)
        linkStore = UserSnapshotLinkStore(context: context)
        let interpretStore = InterpretationCacheStore(context: context)
        let identityResolver = AIIdentityResolver(apiClient: apiClient)
        let counter = DailyReadCounter.makeIsolatedForTesting()
        let reader = CachedInterpretationReader(
            identityResolver: identityResolver,
            cacheStore: interpretStore
        )
        orchestrator = DeepAnalysisOrchestrator(
            apiClient: apiClient,
            chartStore: chartStore,
            interpretStore: interpretStore,
            counter: counter,
            interpretationReader: reader,
            userLinkStore: linkStore
        )
        // roster 持久化走 UserDefaults.standard(进程级),测试间清干净防串扰
        CompatibilityRosterPersistence.clear()
    }

    override func tearDownWithError() throws {
        CompatibilityRosterPersistence.clear()
        orchestrator = nil
        linkStore = nil
        chartStore = nil
        apiClient = nil
        container = nil
        try super.tearDown()
    }

    // MARK: - 测试夹具

    private static let pillar = PillarDTO(
        ganZhi: "甲子", gan: "甲", zhi: "子",
        ganElement: "wood", zhiElement: "water",
        hideGan: ["癸"], shishenGan: "比肩", shishenZhi: ["正印"],
        nayin: "海中金", dishi: "沐浴", xunkong: "戌亥"
    )

    /// 时辰未知老盘请求(S04 契约:12:00 占位 + late_night=true)。
    private static func oldRequest() -> BaziCalculateRequest {
        BaziCalculateRequest(
            birthDatetime: "1988-05-15T12:00:00",
            timezone: "Asia/Shanghai",
            gender: "female",
            longitude: 116.4,
            latitude: 39.9,
            placeName: "北京",
            geonameId: nil,
            ziHourRule: "zi_next_day",
            hourKnown: false,
            lateNight: true
        )
    }

    /// 时辰未知老盘响应(手构,不走 mock:mock trueSolarTime 恒非 null 会把
    /// birthSolarTime 挂到设备时区,污染「原出生日期」锚点;真实后端对
    /// hour_known=false 恒回 true_solar_time=null → 走 S05 存档回退路径)。
    private static func oldResponse(contentHash: String) -> BaziResponse {
        makeResponse(contentHash: contentHash, hourKnown: false, hourPillar: nil, trueSolarTime: nil)
    }

    /// 四柱全盘响应(判据 .hourKnown,路由测试的 A 盘夹具)。
    private static func knownResponse(contentHash: String) -> BaziResponse {
        makeResponse(
            contentHash: contentHash,
            hourKnown: true,
            hourPillar: pillar,
            trueSolarTime: Date(timeIntervalSince1970: 580_262_400)
        )
    }

    private static func makeResponse(
        contentHash: String,
        hourKnown: Bool,
        hourPillar: PillarDTO?,
        trueSolarTime: Date?
    ) -> BaziResponse {
        let ganzhi = GanZhiNaYinDTO(ganZhi: "甲子", nayin: "海中金")
        return BaziResponse(
            contentHash: contentHash,
            trueSolarTime: trueSolarTime,
            trueSolarOffsetMinutes: -14.4,
            pillars: PillarsDTO(year: pillar, month: pillar, day: pillar, hour: hourPillar),
            mingGong: ganzhi, shenGong: ganzhi, taiYuan: ganzhi,
            elementBalance: ElementBalanceDTO(wood: 2, fire: 1, earth: 1, metal: 1, water: 3),
            favorableElements: [], unfavorableElements: [],
            dayMasterStrength: hourKnown ? "balanced" : "unknown_hour",
            tiaoshouApplied: false,
            xijiMethod: nil, patternHint: nil,
            shensha: [],
            luckPillars: [],
            currentLuckPillar: nil, currentYearPillar: nil,
            currentDayPillar: nil, currentHourPillar: nil,
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: -14.4,
                schemaVersion: 1, birthTimezone: "Asia/Shanghai", hourKnown: hourKnown
            ),
            boundaryWarning: nil,
            yearBranchZodiac: "Rat",
            yearBranchFriends: ["Ox"], yearBranchClash: "Horse"
        )
    }

    /// 存档一张时辰未知老盘(可选建 link);返回存档后的 snapshot。
    @discardableResult
    private func archiveOldChart(
        contentHash: String = "s10_old_three_pillar",
        alias: String? = "我自己"
    ) throws -> ChartSnapshot {
        let request = Self.oldRequest()
        let response = Self.oldResponse(contentHash: contentHash)
        _ = try chartStore.upsert(response: response, request: request)
        if let alias {
            _ = try linkStore.upsert(
                userId: UserIdentity.userLocalId,
                snapshotHash: response.contentHash,
                alias: alias
            )
        }
        return try XCTUnwrap(chartStore.get(contentHash: contentHash))
    }

    private func makeVM(hash: String) throws -> AddHourViewModel {
        try AddHourViewModel.make(
            snapshotHash: hash,
            orchestrator: orchestrator,
            chartStore: chartStore,
            linkStore: linkStore
        )
    }

    // MARK: - hash 重建 + 编辑场景隔离

    func testSubmit_RebuildsRequestFromArchive_HourKnownTrueLateNightCleared() async throws {
        let old = try archiveOldChart()
        let vm = try makeVM(hash: old.contentHash)
        vm.setShichenHour(10) // 巳时中点 10:00

        let newResponse = try await XCTUnwrapAsync(await vm.submit())

        // 新 hash ≠ 老 hash(2h 时辰桶参与计算;mock hash 内嵌钟面串,
        // 可反查请求 = 原出生日期 1988-05-15 + 新时辰 10:00,即编辑场景隔离)
        XCTAssertNotEqual(newResponse.contentHash, old.contentHash)
        XCTAssertTrue(newResponse.contentHash.contains("1988-05-15T10:00:00"),
                      "请求必须是「原出生日期+新时辰」的出生地裸钟面: \(newResponse.contentHash)")
        XCTAssertTrue(newResponse.contentHash.contains("Asia/Shanghai"))
        // 新 payload:hour_known=true(mock 回显请求 flag)+ late_night 作废清空
        let newSnapshot = try XCTUnwrap(chartStore.get(contentHash: newResponse.contentHash))
        let decoded = try chartStore.decodeResponse(from: newSnapshot)
        XCTAssertTrue(decoded.isHourKnown, "补后 hour_known 必须翻 true")
        XCTAssertNil(decoded.lateNight, "补的是确定时辰 → late_night 作废清空")
        XCTAssertEqual(decoded.calcRuleSnapshot.hourKnown, true)
    }

    func testSubmit_OldChartArchivedAndKept() async throws {
        // 老三柱盘归档保留:内容寻址 + 不删 = 可回溯(hash 仍可查,link 不迁)
        let old = try archiveOldChart()
        let vm = try makeVM(hash: old.contentHash)
        vm.setShichenHour(10)

        let newResponse = try await XCTUnwrapAsync(await vm.submit())

        XCTAssertNotNil(try chartStore.get(contentHash: old.contentHash), "老盘必须保留(归档可查)")
        XCTAssertNotNil(try chartStore.get(contentHash: newResponse.contentHash))
        XCTAssertEqual(try linkStore.findAlias(snapshotHash: old.contentHash), "我自己",
                       "老盘 link 不动(归档语义)")
    }

    func testSubmit_InheritsAliasToNewLink() async throws {
        let old = try archiveOldChart(alias: "妈妈")
        let vm = try makeVM(hash: old.contentHash)
        vm.setShichenHour(10)

        let newResponse = try await XCTUnwrapAsync(await vm.submit())

        XCTAssertEqual(try linkStore.findAlias(snapshotHash: newResponse.contentHash), "妈妈",
                       "新盘 link 继承原 alias(编辑场景隔离,名字不丢)")
    }

    func testSubmit_TempChartWithoutLink_CreatesNoLink() async throws {
        // 合盘临时人盘(无 link,D6 红线):重算后同样不建 link
        let old = try archiveOldChart(alias: nil)
        let vm = try makeVM(hash: old.contentHash)
        vm.setShichenHour(10)

        let newResponse = try await XCTUnwrapAsync(await vm.submit())

        XCTAssertNil(try linkStore.findAlias(snapshotHash: newResponse.contentHash),
                     "老盘无 link → 新盘不得建 link(临时人不洗成正式命盘)")
    }

    func testSubmit_HashNotChanged_GuardsExplicitly() async throws {
        // 闭环守卫:老盘 hash 恰与重算响应同值(此处令老盘 hash = mock 会产出的
        // 同钟面 hash)→ 显式报错,不静默接受「假闭环」(判据不会翻转)
        let oldHash = "mock_1988-05-15T12:00:00_Asia/Shanghai_116.4"
        let old = try archiveOldChart(contentHash: oldHash)
        let vm = try makeVM(hash: old.contentHash)
        vm.setShichenHour(12) // 午时 → 12:00,与老盘占位钟面同串

        let result = await vm.submit()

        XCTAssertNil(result, "hash 未变 → submit 必须失败返回 nil")
        guard case .failed(let message) = vm.phase else {
            return XCTFail("hash 未变必须显式 failed,实际: \(vm.phase)")
        }
        XCTAssertFalse(message.isEmpty, "失败文案必须是人话(非空)")
    }

    // MARK: - 补后判据翻转(付费墙恢复)

    func testSubmit_GateFlipsToHourKnown_AndPaywallUnlocks() async throws {
        let old = try archiveOldChart()
        // 前置:老盘判据 = 时辰未知·日柱确定(付费墙拦截态)
        let oldDecoded = try chartStore.decodeResponse(from: old)
        XCTAssertEqual(oldDecoded.hourUnknownGate, .hourUnknownDayDetermined)

        let vm = try makeVM(hash: old.contentHash)
        vm.setShichenHour(10)
        let newResponse = try await XCTUnwrapAsync(await vm.submit())

        // S07 判据单一事实源 = payload:新盘翻 .hourKnown → 付费墙自然恢复
        XCTAssertEqual(newResponse.hourUnknownGate, .hourKnown)
        let entitlementStore = EntitlementStore(modelContext: container.mainContext)
        let purchaseManager = PurchaseManager(
            entitlementStore: entitlementStore, apiClient: apiClient
        )
        let paywallVM = PaywallViewModel(
            module: .deepAnalysis,
            contentHash: newResponse.contentHash,
            purchaseManager: purchaseManager
        )
        XCTAssertFalse(paywallVM.isPurchaseIntercepted,
                       "补后付费墙拦截判据必须翻 false(价格与购买恢复)")
    }

    // MARK: - 静默态开关(D7「我确实不知道」)

    func testSilenceToggle_WritesThroughAndRoundTrips() throws {
        let old = try archiveOldChart()
        let vm = try makeVM(hash: old.contentHash)
        XCTAssertFalse(vm.hourUnknownAccepted, "初始 = 老盘 payload(未静默)")

        // 开启 → 写穿 payload
        vm.setHourUnknownAccepted(true)
        let silenced = try chartStore.decodeResponse(from: old)
        XCTAssertTrue(silenced.isHourSilenced, "开启必须落档 hour_unknown_accepted=true")

        // 关闭 → 提示恢复(false 写 nil,回到老盘 payload 形状)
        vm.setHourUnknownAccepted(false)
        let restored = try chartStore.decodeResponse(from: old)
        XCTAssertFalse(restored.isHourSilenced)
        XCTAssertNil(restored.hourUnknownAccepted, "关闭写 nil(encodeIfPresent 省 key)")
        XCTAssertEqual(vm.phase, .idle, "开关写档成功不留错误态")
    }

    func testLegacyPayloadWithoutAcceptedKey_DecodesAsNotSilenced() throws {
        // 2026-08-15 教训回归:S10 之前的老盘缺 key → 不 crash、不静默
        let old = try archiveOldChart()
        let decoded = try chartStore.decodeResponse(from: old)
        XCTAssertNil(decoded.hourUnknownAccepted)
        XCTAssertFalse(decoded.isHourSilenced, "缺 key → 未静默(decodeIfPresent)")
    }

    // MARK: - 触点路由

    func testMake_ThrowsWhenTargetSnapshotMissing() {
        XCTAssertThrowsError(try makeVM(hash: "no_such_hash")) { error in
            XCTAssertTrue(error is AddHourError, "目标盘缺失必须显式抛错,实际: \(error)")
        }
    }

    func testRosterPersistence_RemapsHashAfterRecalc() async throws {
        let old = try archiveOldChart()
        CompatibilityRosterPersistence.save(
            personAHash: "a_hash", context: "general", rosterHashes: ["other_hash", old.contentHash]
        )
        let vm = try makeVM(hash: old.contentHash)
        vm.setShichenHour(10)
        let newResponse = try await XCTUnwrapAsync(await vm.submit())

        let persisted = CompatibilityRosterPersistence.load()
        XCTAssertEqual(persisted.rosterHashes, ["other_hash", newResponse.contentHash],
                       "他人盘补时辰换新盘 → 名单 hash 原地换新(该人留在名单,对级关系自然重算)")
        XCTAssertEqual(persisted.personAHash, "a_hash", "无关 A 盘不动")

        // 自己盘:A hash 同样 remap
        CompatibilityRosterPersistence.save(
            personAHash: old.contentHash, context: "general", rosterHashes: []
        )
        CompatibilityRosterPersistence.remapHash(from: old.contentHash, to: newResponse.contentHash)
        XCTAssertEqual(CompatibilityRosterPersistence.load().personAHash, newResponse.contentHash)
    }

    func testCompatibilityRouting_BlockedPairTargetHash() throws {
        // 合盘拦截卡 CTA 路由:自己无时辰 → 自己盘;他人无时辰 → 对方盘;临时人 → nil
        let context = container.mainContext
        let interpretStore = InterpretationCacheStore(context: context)
        let identityResolver = AIIdentityResolver(apiClient: apiClient)
        let reader = CachedInterpretationReader(identityResolver: identityResolver, cacheStore: interpretStore)
        let compatOrchestrator = CompatibilityOrchestrator(
            apiClient: apiClient,
            compatibilityStore: CompatibilitySnapshotStore(context: context),
            chartStore: chartStore,
            interpretStore: interpretStore,
            counter: DailyReadCounter.makeIsolatedForTesting(),
            interpretationReader: reader
        )
        let compatVM = CompatibilityViewModel(
            orchestrator: compatOrchestrator,
            chartStore: chartStore,
            compatibilityStore: CompatibilitySnapshotStore(context: context),
            entitlementStore: EntitlementStore(modelContext: context),
            modelContext: context
        )

        // 夹具:自己盘无时辰 + 他人盘四柱全
        let selfOld = try archiveOldChart(contentHash: "s10_self_unknown", alias: "我自己")
        let otherSnapshot = try archiveOldChart(contentHash: "s10_other_full", alias: "朋友")
        compatVM.archivedCharts = [
            ArchivedChart(snapshotHash: selfOld.contentHash, alias: "我自己",
                          birthDate: selfOld.birthSolarTime, gender: "female",
                          dayMaster: "甲", snapshot: selfOld),
            ArchivedChart(snapshotHash: otherSnapshot.contentHash, alias: "朋友",
                          birthDate: otherSnapshot.birthSolarTime, gender: "male",
                          dayMaster: "甲", snapshot: otherSnapshot),
        ]
        compatVM.selectedChartAIndex = 0

        func blockedSummary(entry: RosterEntry, personBHash: String) -> PairSummary {
            PairSummary(
                id: "hour_unknown:\(entry.id)", entry: entry, personBHash: personBHash,
                displayName: "对方", birthDate: nil, dayMaster: "—", fiveElements: "",
                dayMasterRelation: "", compatibilityHash: "", isInterpreted: false,
                status: .hourUnknownBlocked
            )
        }

        // ① 自己无时辰 → 全部对的路由都指向自己盘(根因在 A)
        XCTAssertTrue(compatVM.isSelfHourUnknown, "前置:A 盘判据 = 无时辰")
        let pairOther = blockedSummary(entry: .archived(snapshotHash: otherSnapshot.contentHash),
                                       personBHash: otherSnapshot.contentHash)
        XCTAssertEqual(compatVM.addHourTargetHash(forBlockedPair: pairOther), selfOld.contentHash)

        // ② A 盘正常 → 他人存档盘无时辰 → 路由到对方盘(personBHash)
        let knownUpset = try chartStore.upsert(
            response: Self.knownResponse(contentHash: "s10_self_known"),
            request: BaziCalculateRequest(
                birthDatetime: "1985-01-01T08:00:00", timezone: "Asia/Shanghai",
                gender: "male", longitude: 116.4, latitude: 39.9, placeName: "北京",
                geonameId: nil, ziHourRule: "zi_next_day"
            )
        )
        let knownSnapshot = knownUpset.snapshot
        compatVM.archivedCharts[0] = ArchivedChart(
            snapshotHash: knownSnapshot.contentHash, alias: "我自己",
            birthDate: knownSnapshot.birthSolarTime, gender: "male",
            dayMaster: "甲", snapshot: knownSnapshot
        )
        XCTAssertFalse(compatVM.isSelfHourUnknown)
        XCTAssertEqual(compatVM.addHourTargetHash(forBlockedPair: pairOther),
                       otherSnapshot.contentHash, "他人盘无时辰 → 该对路由到对方盘")

        // ③ 临时对方(personBHash 空串)→ nil(CTA 不渲染)
        let tempEntry: RosterEntry = .temp(
            input: PersonBInput(
                birthDatetime: "1990-01-01T10:00:00", timezone: "Asia/Shanghai",
                gender: "male", longitude: 116.4
            ),
            alias: nil, resolvedHash: nil
        )
        let pairTemp = blockedSummary(entry: tempEntry, personBHash: "")
        XCTAssertNil(compatVM.addHourTargetHash(forBlockedPair: pairTemp),
                     "临时对方无存档 hash → 无路由(CTA 不渲染)")
    }

    func testDailyFortune_RefreshHourFlags_ReadsSilenceFlag() throws {
        // 运势末尾行判据:静默态写穿后轻量刷新(hash 不变,不重跑排盘管线)
        let old = try archiveOldChart()
        let context = container.mainContext
        let interpretStore = InterpretationCacheStore(context: context)
        let identityResolver = AIIdentityResolver(apiClient: apiClient)
        let reader = CachedInterpretationReader(identityResolver: identityResolver, cacheStore: interpretStore)
        let vm = DailyFortuneViewModel(
            orchestrator: DailyFortuneOrchestrator(
                apiClient: apiClient,
                dailyStore: DailyFortuneSnapshotStore(context: context),
                interpretStore: interpretStore,
                chartStore: chartStore,
                counter: DailyReadCounter.makeIsolatedForTesting(),
                interpretationReader: reader
            ),
            chartStore: chartStore,
            dailyStore: DailyFortuneSnapshotStore(context: context)
        )

        vm.refreshHourFlags(chartHash: old.contentHash)
        XCTAssertEqual(vm.hourGate, .hourUnknownDayDetermined, "判据 = 老盘 payload")
        XCTAssertFalse(vm.isHourUnknownAccepted, "初始未静默 → 末尾行用主动提示文案")

        try chartStore.setHourUnknownAccepted(contentHash: old.contentHash, accepted: true)
        vm.refreshHourFlags(chartHash: old.contentHash)
        XCTAssertTrue(vm.isHourUnknownAccepted, "静默写穿后轻量刷新即可见面(文案降中性)")

        vm.refreshHourFlags(chartHash: nil)
        // nil → no-op,不 crash(防御路径)
    }

    // MARK: - 渲染冒烟(测试 target 无 ViewInspector,对齐 S08 范式)

    func testAddHourSheetRendersWithoutCrash() throws {
        let old = try archiveOldChart()
        let vm = try makeVM(hash: old.contentHash)
        let vc = UIHostingController(rootView: AddHourSheet(
            vm: vm, onCancel: {}, onRecalculated: { _ in }
        ))
        let size = vc.view.sizeThatFits(CGSize(width: 390, height: 844))
        XCTAssertGreaterThan(size.height, 0, "sheet body 求值须产出可布局内容(不 crash)")

        // 静默态分支也须可渲染(toggle 后时辰输入收起)
        vm.setHourUnknownAccepted(true)
        let vc2 = UIHostingController(rootView: AddHourSheet(
            vm: vm, onCancel: {}, onRecalculated: { _ in }
        ))
        XCTAssertGreaterThan(vc2.view.sizeThatFits(CGSize(width: 390, height: 844)).height, 0)
    }

    func testGateNoticeRendersWithWiredCTA() {
        let vc = UIHostingController(rootView: HourUnknownGateNotice(
            title: L10n.PaywallGate.title,
            reason: L10n.PaywallGate.paywallReason,
            silenced: true,
            onAddHour: {}
        ))
        XCTAssertGreaterThan(
            vc.view.sizeThatFits(CGSize(width: 390, height: 400)).height, 0,
            "静默态 + 已接线 CTA 分支须可渲染(不 crash)"
        )
    }

    /// async 版 XCTUnwrap(项目无该 helper,本地定义)。
    private func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?,
                                   _ message: String = "") async throws -> T {
        let value = try await expression()
        return try XCTUnwrap(value, message)
    }
}
