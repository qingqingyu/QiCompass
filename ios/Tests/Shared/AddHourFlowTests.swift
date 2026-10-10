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
        CompatibilityRosterPersistence.saveV2(
            personAHash: "a_hash", context: "general",
            roster: .init(
                entries: [
                    .archived(snapshotHash: "other_hash"),
                    .archived(snapshotHash: old.contentHash),
                ],
                selectedEntryID: "archived:\(old.contentHash)"
            )
        )
        let vm = try makeVM(hash: old.contentHash)
        vm.setShichenHour(10)
        let newResponse = try await XCTUnwrapAsync(await vm.submit())

        let persisted = CompatibilityRosterPersistence.loadV2()
        XCTAssertEqual(persisted?.entries,
                       [.archived(snapshotHash: "other_hash"),
                        .archived(snapshotHash: newResponse.contentHash)],
                       "他人盘补时辰换新盘 → 名单 hash 原地换新(该人留在名单,对级关系自然重算)")
        XCTAssertEqual(persisted?.selectedEntryID, "archived:\(newResponse.contentHash)",
                       "选中 id 内嵌的 archived:<hash> 同步换新")
        XCTAssertEqual(CompatibilityRosterPersistence.loadPersonAHash(), "a_hash", "无关 A 盘不动")

        // 自己盘:A hash 同样 remap
        CompatibilityRosterPersistence.saveV2(
            personAHash: old.contentHash, context: "general",
            roster: .init(entries: [], selectedEntryID: nil)
        )
        CompatibilityRosterPersistence.remapHash(from: old.contentHash, to: newResponse.contentHash)
        XCTAssertEqual(CompatibilityRosterPersistence.loadPersonAHash(), newResponse.contentHash)
    }

    /// R4 修订配套(2026-10-06 review 核实):loadArchivedChart 的「三柱一致
    /// 即同人」兜底 remap 已拔除(同日生两人会串隐私输入),同人补时辰的
    /// M4/M5 输入沿用收敛到 submit 的显式 remap 单点——此处钉住该接线。
    func testSubmit_RemapsDeepUserInputToNewHash() async throws {
        let old = try archiveOldChart()
        DeepUserInputPersistence.saveM4(.init(age: 41, concern: "体力"), contentHash: old.contentHash)
        DeepUserInputPersistence.saveM5(.init(assets: "存款稳定", preference: "保守"), contentHash: old.contentHash)
        var newHashForCleanup: String?
        defer {
            [old.contentHash, newHashForCleanup].compactMap { $0 }.forEach {
                UserDefaults.standard.removeObject(forKey: DeepUserInputPersistence.m4KeyPrefix + $0)
                UserDefaults.standard.removeObject(forKey: DeepUserInputPersistence.m5KeyPrefix + $0)
            }
        }

        let vm = try makeVM(hash: old.contentHash)
        vm.setShichenHour(10)
        let newResponse = try await XCTUnwrapAsync(await vm.submit())
        newHashForCleanup = newResponse.contentHash

        XCTAssertEqual(
            DeepUserInputPersistence.loadM4(contentHash: newResponse.contentHash),
            .init(age: 41, concern: "体力"),
            "补时辰换新 hash:M4 输入必须随 submit 迁移(兜底 remap 拔除后的唯一沿用路径)"
        )
        XCTAssertEqual(
            DeepUserInputPersistence.loadM5(contentHash: newResponse.contentHash)?.preference,
            "保守",
            "M5 输入同样迁移"
        )
        XCTAssertNotNil(
            DeepUserInputPersistence.loadM4(contentHash: old.contentHash),
            "老 key 保留(可回溯语义,与 remapHash 契约一致)"
        )
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
            alias: nil, resolvedHash: nil,
            place: .custom(longitude: 116.4, timezone: "Asia/Shanghai")
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
    // MARK: - 排盘入参存档(G 条 2026-10-08 拍板:只补存字段,行为不变)

    func testUpsert_排盘入参存档字段随Payload往返_老形状缺key不崩() throws {
        // 带全字段的请求:钟面 birth_datetime + geoname_id 必须落 payload 并可解回
        let request = BaziCalculateRequest(
            birthDatetime: "1990-03-15T14:30:00",
            timezone: "Asia/Shanghai",
            gender: "male",
            longitude: 116.4,
            latitude: 39.9,
            placeName: "北京",
            geonameId: 1816670,
            ziHourRule: "zi_next_day",
            hourKnown: true,
            lateNight: nil
        )
        let response = Self.knownResponse(contentHash: "g_archive_roundtrip")
        _ = try chartStore.upsert(response: response, request: request)
        let snapshot = try XCTUnwrap(chartStore.get(contentHash: "g_archive_roundtrip"))
        let decoded = try chartStore.decodeResponse(from: snapshot)
        XCTAssertEqual(
            decoded.archivedBirthDatetime, "1990-03-15T14:30:00",
            "钟面 birth_datetime 必须原样存档(未来自动重签的原料)")
        XCTAssertEqual(decoded.archivedGeonameId, 1816670)

        // 老快照形状(payload 无 archived_* key)必须照常解码为 nil
        // (2026-08-15 keyNotFound 教训:payload 加字段必须 decodeIfPresent)
        let json = try JSONSerialization.jsonObject(with: snapshot.payload)
        guard var dict = json as? [String: Any] else {
            return XCTFail("payload 应为 JSON 对象")
        }
        XCTAssertNotNil(dict.removeValue(forKey: "archived_birth_datetime"),
                        "前置:新存档 payload 应含 archived_birth_datetime")
        XCTAssertNotNil(dict.removeValue(forKey: "archived_geoname_id"))
        let strippedData = try JSONSerialization.data(withJSONObject: dict)
        let legacy = try APICoder.decoder.decode(BaziResponse.self, from: strippedData)
        XCTAssertNil(legacy.archivedBirthDatetime, "老 payload 缺 key → nil(不得 keyNotFound)")
        XCTAssertNil(legacy.archivedGeonameId)
    }

    // MARK: - 老盘自动重签(附八拍板②:静默重排 + hash 断言)

    /// 重签测试共用:入参齐全的存档请求(与 G 条存档测试同款)。
    private static func reSignArchiveRequest(
        birthDatetime: String = "1990-03-15T14:30:00"
    ) -> BaziCalculateRequest {
        BaziCalculateRequest(
            birthDatetime: birthDatetime,
            timezone: "Asia/Shanghai",
            gender: "male",
            longitude: 116.4,
            latitude: 39.9,
            placeName: "北京",
            geonameId: 1816670,
            ziHourRule: "zi_next_day",
            hourKnown: true,
            lateNight: nil
        )
    }

    /// 无原料(更老快照,archived_* 缺失)→ refresh 返回 nil,零网络
    /// (该人群维持既有「重新排盘」出口,静默重签帮不了)。
    /// 注:加载期 ensure 入口已删(2026-10-10:「有入参却缺 token」的快照
    /// 不存在,token 上线早于补存入参),本组用例改钉失效期 refresh 语义。
    func testRefreshContextTokens_无原料_返回nil零网络() async throws {
        let request = Self.reSignArchiveRequest()
        let response = Self.knownResponse(contentHash: "resign_no_materials")
        _ = try chartStore.upsert(response: response, request: request)
        guard let snapshot = try chartStore.get(contentHash: "resign_no_materials") else {
            return XCTFail("快照应已存档")
        }
        // 剥掉 archived_*(模拟 3695b6a 之前的老快照形状)
        let json = try JSONSerialization.jsonObject(with: snapshot.payload)
        guard var dict = json as? [String: Any] else {
            return XCTFail("payload 应为 JSON 对象")
        }
        dict.removeValue(forKey: "archived_birth_datetime")
        dict.removeValue(forKey: "archived_geoname_id")
        snapshot.payload = try JSONSerialization.data(withJSONObject: dict)
        try container.mainContext.save()

        apiClient.calculateResponder = { _ in
            XCTFail("无原料不得触发排盘")
            throw UserFacingError.generic(message: "unreachable")
        }
        let refreshed = try await chartStore.refreshContextTokens(
            snapshot: snapshot, apiClient: apiClient)
        XCTAssertNil(refreshed, "无原料 → nil(调用方维持既有 403 出口)")
        XCTAssertTrue(apiClient.recordedCalculateRequests.isEmpty)
    }

    /// 重排同 hash 带新 token → 接受并落档:返回值/存档 payload 都有
    /// token;后端不回显的存档侧字段(lateNight / hourUnknownAccepted)
    /// 在覆盖后不丢。
    func testRefreshContextTokens_重签成功_落档且存档侧字段不丢() async throws {
        let request = Self.reSignArchiveRequest()
        var old = Self.knownResponse(contentHash: "resign_ok")
        old.hourUnknownAccepted = true  // S10 静默偏好(仅 payload,后端不回显)
        _ = try chartStore.upsert(response: old, request: request)
        guard let snapshot = try chartStore.get(contentHash: "resign_ok") else {
            return XCTFail("快照应已存档")
        }

        var fresh = Self.knownResponse(contentHash: "resign_ok")  // 同 hash
        fresh.contextTokens = ["deep": "nd", "v1": "nv", "payload": "np"]
        apiClient.calculateResponder = { req in
            // 重签请求必须用存档的原钟面,不是真太阳时近似
            XCTAssertEqual(req.birthDatetime, "1990-03-15T14:30:00")
            XCTAssertEqual(req.geonameId, 1816670)
            return fresh
        }
        let refreshed = try await chartStore.refreshContextTokens(
            snapshot: snapshot, apiClient: apiClient)
        XCTAssertEqual(refreshed?.contextTokens?["v1"], "nv")
        XCTAssertEqual(apiClient.recordedCalculateRequests.count, 1)

        // 落档断言:重 decode 快照(引用已被 upsert 原位覆盖)
        let persisted = try chartStore.decodeResponse(from: snapshot)
        XCTAssertEqual(persisted.contextTokens?["payload"], "np")
        XCTAssertEqual(persisted.hourUnknownAccepted, true,
                       "S10 静默偏好随重签覆盖保留(后端不回显,须显式带)")
        XCTAssertEqual(persisted.archivedBirthDatetime, "1990-03-15T14:30:00",
                       "重签落档后原料自续(后续失效期重签仍可用)")
    }

    /// G 条断言保险:重排 hash 不一致(后端规则演化/原料损坏)→ 不接受
    /// 新 token、不落档,返回 nil(调用方维持既有 403 出口)。
    func testRefreshContextTokens_hash不一致_不接受不落档() async throws {
        let request = Self.reSignArchiveRequest()
        let old = Self.knownResponse(contentHash: "resign_mismatch")
        _ = try chartStore.upsert(response: old, request: request)
        guard let snapshot = try chartStore.get(contentHash: "resign_mismatch") else {
            return XCTFail("快照应已存档")
        }

        var stranger = Self.knownResponse(contentHash: "resign_mismatch_NEW")
        stranger.contextTokens = ["deep": "x"]
        apiClient.calculateResponder = { _ in stranger }
        let refreshed = try await chartStore.refreshContextTokens(
            snapshot: snapshot, apiClient: apiClient)
        XCTAssertNil(refreshed, "hash 不一致 → nil,不张冠李戴")
        let persisted = try chartStore.decodeResponse(from: snapshot)
        XCTAssertNil(persisted.contextTokens, "存档不得被「另一张盘」的 token 覆盖")
        XCTAssertEqual(apiClient.recordedCalculateRequests.count, 1)
    }

    /// 失效期入口(refresh):排盘失败(离线等)→ nil(调用方维持既有
    /// 403 出口);成功 → 带 token 的新 response。
    func testRefreshContextTokens_排盘失败返回nil_成功返回新token() async throws {
        let request = Self.reSignArchiveRequest()
        let old = Self.knownResponse(contentHash: "resign_refresh")
        _ = try chartStore.upsert(response: old, request: request)
        guard let snapshot = try chartStore.get(contentHash: "resign_refresh") else {
            return XCTFail("快照应已存档")
        }

        apiClient.calculateResponder = { _ in
            throw APIError.httpError(statusCode: 503, body: nil)  // 任意网络/后端失败
        }
        let failed = try await chartStore.refreshContextTokens(
            snapshot: snapshot, apiClient: apiClient)
        XCTAssertNil(failed, "排盘失败 → nil,不是旧 response(调用方判 nil 走既有出口)")

        var fresh = Self.knownResponse(contentHash: "resign_refresh")
        fresh.contextTokens = ["v1": "again"]
        apiClient.calculateResponder = { _ in fresh }
        let ok = try await chartStore.refreshContextTokens(
            snapshot: snapshot, apiClient: apiClient)
        XCTAssertEqual(ok?.contextTokens?["v1"], "again")
    }

    /// 同 hash 并发重签去重(2026-10-10 接线补强):深度 403 摄入点与每日
    /// 403 重试对同一张盘并发触发 refresh 时只发一次 /calculate,后到者搭车
    /// 等同一结果(mock calculateBazi 内建 300ms 挂起,去重缺位时必 2 次)。
    func testRefreshContextTokens_并发同hash_去重只发一次排盘() async throws {
        let request = Self.reSignArchiveRequest()
        let old = Self.knownResponse(contentHash: "resign_dedup")
        _ = try chartStore.upsert(response: old, request: request)
        let snapshot = try XCTUnwrap(chartStore.get(contentHash: "resign_dedup"))

        var fresh = Self.knownResponse(contentHash: "resign_dedup")
        fresh.contextTokens = ["v1": "dedup-v1"]
        apiClient.calculateResponder = { _ in fresh }

        async let a = chartStore.refreshContextTokens(
            snapshot: snapshot, apiClient: apiClient)
        async let b = chartStore.refreshContextTokens(
            snapshot: snapshot, apiClient: apiClient)
        let (first, second) = try await (a, b)

        XCTAssertEqual(first?.contextTokens?["v1"], "dedup-v1")
        XCTAssertEqual(second?.contextTokens?["v1"], "dedup-v1")
        XCTAssertEqual(
            apiClient.recordedCalculateRequests.count, 1,
            "同 hash 在飞重签必须合并为一次 /calculate"
        )
    }

    /// 会话级注定失败记忆(2026-10-10):hash 不一致一次判负后,本会话内
    /// 再次 refresh 不再重发注定失败的重签(每日 403 重试路径无 VM 层
    /// 「一次/盘/会话」预算,不记忆则每次进今日页白发一次);网络类失败
    /// 不记忆(由 testRefreshContextTokens_排盘失败返回nil_成功返回新token 锁定)。
    func testRefreshContextTokens_hash不一致_本会话不再重发() async throws {
        let request = Self.reSignArchiveRequest()
        let old = Self.knownResponse(contentHash: "resign_hopeless")
        _ = try chartStore.upsert(response: old, request: request)
        let snapshot = try XCTUnwrap(chartStore.get(contentHash: "resign_hopeless"))

        var stranger = Self.knownResponse(contentHash: "resign_hopeless_NEW")
        stranger.contextTokens = ["v1": "x"]
        apiClient.calculateResponder = { _ in stranger }

        _ = try await chartStore.refreshContextTokens(
            snapshot: snapshot, apiClient: apiClient)
        XCTAssertEqual(apiClient.recordedCalculateRequests.count, 1)

        _ = try await chartStore.refreshContextTokens(
            snapshot: snapshot, apiClient: apiClient)
        XCTAssertEqual(
            apiClient.recordedCalculateRequests.count, 1,
            "注定失败(hash 不一致)本会话记忆,不重发"
        )
    }

    private func XCTUnwrapAsync<T>(_ expression: @autoclosure () async throws -> T?,
                                   _ message: String = "") async throws -> T {
        let value = try await expression()
        return try XCTUnwrap(value, message)
    }
}
