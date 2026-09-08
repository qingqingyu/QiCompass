import SwiftData
import XCTest
@testable import QiCompass

/// 2026-08-16 深度解析直读存档改造测试:
/// - `DeepAnalysisViewModel.loadArchivedChart`:.ready + lastRequest 就绪 +
///   InterpretState 从 .idle 起步(v1 捌章链与主状态机解耦,InterpretState 不动)+
///   **不触发** onChartArchived
/// - `ChartSnapshot.archivedDisplayRequest`:城市盘 / 自定义地点盘 / 老快照(无时区)三形态映射
/// - upsert → get → decodeResponse → archivedDisplayRequest 往返一致(payload 不丢 identity)
///
/// 2026-09-08 断点续跑套件:loadArchivedChart 后本地缓存回填(.ok cached:true)、
/// v1ChainFields 重建、自动续跑守卫(dayAmbiguous / 日限 / 全完成)、同 hash 重入、
/// 换盘清链标志、hydrate 失败(health 挂)跳过续跑。
@MainActor
final class DeepAnalysisArchiveLoadTests: XCTestCase {

    private var container: ModelContainer!
    private var vm: DeepAnalysisViewModel!
    private var apiClient: MockAPIClient!
    private var chartStore: ChartSnapshotStore!
    private var interpretStore: InterpretationCacheStore!
    private var counter: DailyReadCounter!
    private var entitlementStore: EntitlementStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        apiClient = MockAPIClient()
        chartStore = ChartSnapshotStore(context: context)
        interpretStore = InterpretationCacheStore(context: context)
        let identityResolver = AIIdentityResolver(apiClient: apiClient)
        counter = DailyReadCounter.makeIsolatedForTesting()
        let reader = CachedInterpretationReader(
            identityResolver: identityResolver,
            cacheStore: interpretStore
        )
        let orchestrator = DeepAnalysisOrchestrator(
            apiClient: apiClient,
            chartStore: chartStore,
            interpretStore: interpretStore,
            counter: counter,
            interpretationReader: reader,
            userLinkStore: UserSnapshotLinkStore(context: context)
        )
        entitlementStore = EntitlementStore(modelContext: context)
        vm = DeepAnalysisViewModel(
            orchestrator: orchestrator,
            entitlementStore: entitlementStore
        )
    }

    override func tearDown() async throws {
        // 自动起链改造(2026-09-08):loadArchivedChart 会留 v1 链后台在飞
        // (含既有 testLoadArchivedChartSetsReadyAndLastRequest)。不等收尾就撤
        // container,后台 interpretStore.upsert 会 flaky crash——对齐 452d8dc
        // 「自动解读收尾等待」修法,先等链落定再撤依赖。
        // (teardown 用 async 变体:XCTest 的 tearDownWithError 无 async 版本)
        if let vm {
            _ = await waitUntil(timeout: 10) { !vm.isChainRunning && !vm.isHydrating }
        }
        vm = nil
        entitlementStore = nil
        counter = nil
        interpretStore = nil
        chartStore = nil
        apiClient = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - 测试夹具

    /// 与实现独立的钟面期望值计算(Calendar components,不走 DateFormatter;
    /// 对齐 DeepAnalysisViewModelFormTests.expectedWall 范式)。
    private static func wallString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!
        )
    }

    /// 北京城市盘请求(与 FormTests.beijing 同源字段)。
    private static func beijingRequest() -> BaziCalculateRequest {
        BaziCalculateRequest(
            birthDatetime: "2000-05-20T10:30:00",
            timezone: "Asia/Shanghai",
            gender: "male",
            longitude: 116.4074,
            latitude: 39.9042,
            placeName: "北京",
            geonameId: 1816670,
            ziHourRule: "zi_next_day"
        )
    }

    // MARK: - loadArchivedChart

    func testLoadArchivedChartSetsReadyAndLastRequest() async throws {
        var archivedFired = false
        vm.onChartArchived = { archivedFired = true }

        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)

        vm.loadArchivedChart(response: response, request: request)

        guard case .ready(let ready, let interpret) = vm.state else {
            return XCTFail("loadArchivedChart 后必须 .ready,实际 \(vm.state)")
        }
        XCTAssertEqual(ready.contentHash, response.contentHash)
        XCTAssertEqual(interpret, .idle, "AI 命书必须从 .idle 起步(β 点击触发,决策 #4)")
        XCTAssertEqual(vm.lastRequest, request, "InterpretationSection/付费墙依赖 lastRequest")
        XCTAssertFalse(
            archivedFired,
            "直读存档非新建存档,不应触发 onChartArchived(否则误消费 pendingReturnTab 切 Tab)"
        )
    }

    // MARK: - archivedDisplayRequest(城市盘)

    func testArchivedDisplayRequestCitySnapshotRoundtrip() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        _ = try chartStore.upsert(response: response, request: request)

        let snapshot = try XCTUnwrap(chartStore.get(contentHash: response.contentHash))
        let decoded = try chartStore.decodeResponse(from: snapshot)
        XCTAssertEqual(decoded.contentHash, response.contentHash, "payload 往返不得丢 identity")

        let rebuilt = snapshot.archivedDisplayRequest
        XCTAssertEqual(rebuilt.gender, "male")
        XCTAssertEqual(rebuilt.placeName, "北京")
        XCTAssertEqual(rebuilt.timezone, "Asia/Shanghai")
        XCTAssertEqual(rebuilt.longitude, 116.4074, accuracy: 1e-9)
        XCTAssertEqual(rebuilt.latitude ?? 0, 39.9042, accuracy: 1e-9)
        XCTAssertEqual(rebuilt.ziHourRule, "zi_next_day")
        XCTAssertNil(rebuilt.geonameId, "geonameId 不入存档(展示元数据,不参与计算)")
        // birthDatetime = 真太阳时在出生城市时区的钟面(派生近似值,绝不回传 /calculate)
        let bjTZ = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(rebuilt.birthDatetime, Self.wallString(snapshot.birthSolarTime, timeZone: bjTZ))
    }

    // MARK: - archivedDisplayRequest(自定义地点盘)

    func testArchivedDisplayRequestCustomPlaceSnapshot() async throws {
        // S05:BirthPlaceResolver 给自定义地点填 placeName="自定义地点"、latitude=nil
        let request = BaziCalculateRequest(
            birthDatetime: "1995-11-03T08:00:00",
            timezone: "Asia/Urumqi",
            gender: "female",
            longitude: 87.62,
            latitude: nil,
            placeName: "自定义地点",
            geonameId: nil,
            ziHourRule: "zi_next_day"
        )
        let response = try await apiClient.calculateBazi(request: request)
        _ = try chartStore.upsert(response: response, request: request)

        let snapshot = try XCTUnwrap(chartStore.get(contentHash: response.contentHash))
        let rebuilt = snapshot.archivedDisplayRequest
        XCTAssertEqual(rebuilt.placeName, "自定义地点")
        XCTAssertEqual(rebuilt.timezone, "Asia/Urumqi")
        XCTAssertEqual(rebuilt.longitude, 87.62, accuracy: 1e-9)
        XCTAssertNil(rebuilt.latitude)
        let urumqiTZ = try XCTUnwrap(TimeZone(identifier: "Asia/Urumqi"))
        XCTAssertEqual(rebuilt.birthDatetime, Self.wallString(snapshot.birthSolarTime, timeZone: urumqiTZ))
    }

    // MARK: - archivedDisplayRequest(老快照:S03 前无时区/城市元数据)

    func testArchivedDisplayRequestLegacySnapshotFallsBackToCurrentTZ() throws {
        // 直接构造 @Model 实例(不入 context):模拟 S03 前老快照三 nil 字段
        let snapshot = ChartSnapshot(
            contentHash: "legacy_snapshot_1",
            schemaVersion: 1,
            birthSolarTime: Date(timeIntervalSince1970: 580_262_400),
            gender: "female",
            cityLongitude: 116.4,
            cityTimezone: nil,
            cityName: nil,
            cityLatitude: nil,
            ziHourRule: "zi_same_day",
            calcRuleSnapshot: Data(),
            payload: Data(),
            createdAt: .now
        )
        let rebuilt = snapshot.archivedDisplayRequest
        XCTAssertEqual(rebuilt.timezone, TimeZone.current.identifier, "老快照无时区 → 兜底设备时区标识符")
        XCTAssertNil(rebuilt.placeName, "城市名缺失 → ChartHeaderView 走「自定义经度」回退展示")
        XCTAssertNil(rebuilt.latitude)
        XCTAssertEqual(rebuilt.gender, "female")
        XCTAssertEqual(rebuilt.ziHourRule, "zi_same_day")
        XCTAssertEqual(
            rebuilt.birthDatetime,
            Self.wallString(snapshot.birthSolarTime, timeZone: .current),
            "老快照钟面派生用设备时区,与 timezone 兜底同源"
        )
    }

    // MARK: - 断点续跑(2026-09-08:冷启动回填 + 自动续跑守卫)

    /// M0 缓存正文:含 structure_fingerprint 的合法 JSON(回填必须能重建链字段)。
    private static let m0CacheJSON =
        "{\"structure_fingerprint\":\"fp-restore-1\",\"main_axis\":{},\"core_loop\":{}}"

    /// 预置一章节本地缓存(身份对齐 MockAPIClient.health:anthropic / mock-anthropic-model)。
    private func seedV1Cache(hash: String, module: ModuleID, text: String) throws {
        try interpretStore.upsert(
            contentHash: hash, module: module.rawValue, promptVersion: 1, targetDate: nil,
            provider: "anthropic", model: "mock-anthropic-model",
            interpretation: text, generatedAt: .now
        )
    }

    /// 给盘插入 bazi_deep 全本 entitlement(单 SKU,对齐购买落库形态)。
    private func seedDeepEntitlement(hash: String) throws {
        try entitlementStore.upsert(
            transactionId: "tx-test-\(hash)",
            productId: AppleProductID.deepAnalysisSingle,
            contentHash: hash,
            module: EntitlementModule.baziDeep,
            userLocalId: UserIdentity.userLocalId,
            purchasedAt: .now,
            originalPurchaseDate: .now
        )
    }

    /// 轮询等待 VM 异步 Task 落定(hydrate / chain 都是 Task;
    /// 对齐 DailyFortuneHourUnknownGateTests.waitForState 范式)。
    private func waitUntil(
        timeout: TimeInterval = 8,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }

    func testLoadArchivedChartRestoresCachedModulesAsOkCachedTrue() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedV1Cache(hash: response.contentHash, module: .m0, text: Self.m0CacheJSON)
        try seedV1Cache(hash: response.contentHash, module: .m1, text: "M1 已生成正文")
        let readsBefore = vm.remainingReads

        vm.loadArchivedChart(response: response, request: request)

        let restored = await waitUntil {
            self.vm.moduleStates[.m0] == .ok(text: Self.m0CacheJSON, cached: true)
                && self.vm.moduleStates[.m1] == .ok(text: "M1 已生成正文", cached: true)
        }
        XCTAssertTrue(restored, "冷启动回填:M0/M1 缓存必须瞬时回填为 .ok(cached: true),实际:\(vm.moduleStates)")
        // 免费盘两章已全成 → 无可跑未完成章 → 不起链、不耗次
        XCTAssertFalse(vm.isChainRunning, "全成盘不得自动起链")
        XCTAssertEqual(vm.remainingReads, readsBefore, "回填零 interpret 调用,次数不得消耗")
    }

    func testRestoreRebuildsChainFieldsForDownstream() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedDeepEntitlement(hash: response.contentHash)
        // 只缓存 M0(带 fingerprint):M1 起必须靠回填重建的 v1ChainFields 续跑
        try seedV1Cache(hash: response.contentHash, module: .m0, text: Self.m0CacheJSON)

        vm.loadArchivedChart(response: response, request: request)

        // 已购盘:M0 回填跳过,M1/M2/M3/M6/M7 续跑生成,M4/M5 停在 needsInput;
        // M1 若是 .pending = 上游 fingerprint 缺失守卫触发(链字段没重建)
        let settled = await waitUntil(timeout: 12) {
            self.vm.moduleStates[.m1]?.isOk == true
                && self.vm.moduleStates[.m2]?.isOk == true
                && self.vm.moduleStates[.m3]?.isOk == true
                && self.vm.moduleStates[.m6]?.isOk == true
                && self.vm.moduleStates[.m7]?.isOk == true
                && self.vm.moduleStates[.m4] == .needsInput
                && !self.vm.isChainRunning
        }
        XCTAssertTrue(settled, """
        回填 + 续跑整链:M0 缓存跳过、M1-M7 按 entitlement 续跑、M4/M5 待输入。\
        实际:\(vm.moduleStates) isChainRunning=\(vm.isChainRunning)
        """)
        XCTAssertEqual(
            vm.moduleStates[.m0], .ok(text: Self.m0CacheJSON, cached: true),
            "M0 必须以缓存命中回填,不重跑(续跑链跳过已 ok 章)"
        )
    }

    func testRestoreWritebackSkipsModulesFlippedDuringAwait() async throws {
        // 写回重检回归锁(2026-09-08):performRestore 的 await 窗口内模块翻非可回填态
        // (模拟用户重试落定 .ok)→ 缓存写回不得覆盖其语义态;未翻转的章正常回填。
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedV1Cache(hash: response.contentHash, module: .m0, text: Self.m0CacheJSON)
        try seedV1Cache(hash: response.contentHash, module: .m1, text: "M1 缓存旧正文")

        // health 慢 600ms:撑开 performRestore 的 await 窗口供测试确定性翻转状态
        let slow = SlowHealthAPIClient(base: apiClient, delayNanos: 600_000_000)
        let context = container.mainContext
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: slow),
            cacheStore: InterpretationCacheStore(context: context)
        )
        let orchestrator = DeepAnalysisOrchestrator(
            apiClient: slow,
            chartStore: chartStore,
            interpretStore: InterpretationCacheStore(context: context),
            counter: counter,
            interpretationReader: reader,
            userLinkStore: UserSnapshotLinkStore(context: context)
        )
        let slowVM = DeepAnalysisViewModel(
            orchestrator: orchestrator,
            entitlementStore: entitlementStore
        )

        slowVM.loadArchivedChart(response: response, request: request)
        // 抓 hydrate 在飞窗口:isHydrating=true 覆盖 performRestore 全程(含写回),
        // 600ms 窗口内 30ms 轮询必然先于写回落定
        let inFlight = await waitUntil(timeout: 5) { slowVM.isHydrating }
        XCTAssertTrue(inFlight, "前置:hydrate 已起,await 窗口打开")

        // 前置:翻转时 M1 必须尚未被写回(否则窗口未撑开,用例未测到重检,
        // 显式失败优于静默假绿——极端调度停滞 >600ms 时这里会红)
        XCTAssertNil(slowVM.moduleStates[.m1], "前置失败:await 窗口未撑开(写回已发生)")

        // 模拟 await 窗口内用户动作:M1 翻 .ok(在飞重试落定,非缓存)
        slowVM.moduleStates[.m1] = .ok(text: "M1 在飞重试落定的新正文", cached: false)

        // 等回填收尾:M0 正常回填 + isHydrating 复位
        let settled = await waitUntil(timeout: 5) {
            !slowVM.isHydrating
                && slowVM.moduleStates[.m0] == .ok(text: Self.m0CacheJSON, cached: true)
        }
        XCTAssertTrue(settled, "前置:M0 缓存回填完成,实际:\(slowVM.moduleStates)")

        XCTAssertEqual(
            slowVM.moduleStates[.m1], .ok(text: "M1 在飞重试落定的新正文", cached: false),
            "写回重检:await 窗口内翻 .ok 的章不得被缓存覆盖(老正文/缓存标记都算回归)"
        )
        XCTAssertFalse(slowVM.isChainRunning, "M0/M1 皆终态、付费章无 entitlement → 无可跑,不起链")
    }

    func testHydrateFailureLogsAndSkipsResume() async throws {
        // health 挂(离线):回填整体失败 → 跳过自动续跑,不静默半填、不崩
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedV1Cache(hash: response.contentHash, module: .m0, text: Self.m0CacheJSON)

        let failing = HealthFailingAPIClient(base: apiClient)
        let context = container.mainContext
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: failing),
            cacheStore: InterpretationCacheStore(context: context)
        )
        let orchestrator = DeepAnalysisOrchestrator(
            apiClient: failing,
            chartStore: chartStore,
            interpretStore: InterpretationCacheStore(context: context),
            counter: counter,
            interpretationReader: reader,
            userLinkStore: UserSnapshotLinkStore(context: context)
        )
        let offlineVM = DeepAnalysisViewModel(
            orchestrator: orchestrator,
            entitlementStore: entitlementStore
        )

        offlineVM.loadArchivedChart(response: response, request: request)
        // 等 hydrate 失败路径落定(health 超时/失败返回的时间余量)
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(offlineVM.moduleStates.isEmpty, "health 失败 → 回填跳过,目录保持未读(不半填)")
        XCTAssertFalse(offlineVM.isChainRunning, "回填失败不得自动续跑(离线必失败,不制造满屏 failed)")
        guard case .ready = offlineVM.state else {
            return XCTFail("hydrate 失败不得打断主状态机,实际:\(offlineVM.state)")
        }
    }

    func testResumeSkippedWhenDayAmbiguous() async throws {
        // 日柱歧义盘:hydrate/resume 双守卫,零 interpret 请求
        let request = Self.beijingRequest()
        let base = try await apiClient.calculateBazi(request: request)
        let response = Self.dayAmbiguousVariant(of: base)

        vm.loadArchivedChart(response: response, request: request)
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(vm.moduleStates.isEmpty, "日柱歧义 → 回填与续跑全拦(S07 纵深防御)")
        XCTAssertFalse(vm.isChainRunning)
    }

    func testResumeSkippedWhenDailyLimitExhausted() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        // 耗尽每日池(isolated counter 从零配额起;上限与配置一致,循环到拒绝为止)
        var consumed = 0
        while counter.tryConsume(module: "bazi_deep") && consumed < 50 { consumed += 1 }
        XCTAssertEqual(vm.remainingReads, 0, "前置:次数已耗尽(实际消耗 \(consumed) 次)")

        vm.loadArchivedChart(response: response, request: request)
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertTrue(vm.moduleStates.isEmpty, "次数耗尽 → 自动续跑跳过(CTA limit ghost 承担人话解释)")
        XCTAssertFalse(vm.isChainRunning)
    }

    func testSameHashReloadKeepsExistingStates() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedV1Cache(hash: response.contentHash, module: .m0, text: Self.m0CacheJSON)
        try seedV1Cache(hash: response.contentHash, module: .m1, text: "M1 已生成正文")

        vm.loadArchivedChart(response: response, request: request)
        let restored = await waitUntil {
            self.vm.moduleStates[.m1] == .ok(text: "M1 已生成正文", cached: true)
        }
        XCTAssertTrue(restored, "前置:首载已回填")

        // 同 hash 重入(取消补时辰 / Tab 重挂):既有章节态不清洗、不闪回 pending
        vm.loadArchivedChart(response: response, request: request)
        XCTAssertEqual(vm.moduleStates[.m0], .ok(text: Self.m0CacheJSON, cached: true), "同 hash 重入不得清章节态")
        XCTAssertEqual(vm.moduleStates[.m1], .ok(text: "M1 已生成正文", cached: true))
    }

    func testChartChangeResetsChainFlag() async throws {
        let requestA = Self.beijingRequest()
        let responseA = try await apiClient.calculateBazi(request: requestA)
        // 只缓存 M0:M1 缺 → 回填后自动续跑 M1(链在跑的窗口)
        try seedV1Cache(hash: responseA.contentHash, module: .m0, text: Self.m0CacheJSON)
        let requestB = BaziCalculateRequest(
            birthDatetime: "1995-11-03T08:00:00",
            timezone: "Asia/Urumqi",
            gender: "female",
            longitude: 87.62,
            latitude: nil,
            placeName: "自定义地点",
            geonameId: nil,
            ziHourRule: "zi_next_day"
        )
        let responseB = try await apiClient.calculateBazi(request: requestB)

        vm.loadArchivedChart(response: responseA, request: requestA)
        let chainStarted = await waitUntil { self.vm.isChainRunning }
        XCTAssertTrue(chainStarted, "前置:M1 未完成 → 回填后自动续跑(链在跑)")

        // 换盘:链标志必须**同步**复位(不等取消协作落地),否则新盘 resume 被旧标志拦
        vm.loadArchivedChart(response: responseB, request: requestB)
        XCTAssertFalse(vm.isChainRunning, "换盘必须同步清链标志,防新盘续跑被旧标志误拦")
        XCTAssertTrue(vm.moduleStates.isEmpty, "换盘清洗:旧盘章节态不得残留")
    }

    /// 从既有响应构造日柱歧义变体(pillars.day = nil → hourUnknownGate = .dayAmbiguous)。
    private static func dayAmbiguousVariant(of base: BaziResponse) -> BaziResponse {
        BaziResponse(
            contentHash: base.contentHash,
            trueSolarTime: base.trueSolarTime,
            trueSolarOffsetMinutes: base.trueSolarOffsetMinutes,
            pillars: PillarsDTO(
                year: base.pillars.year, month: base.pillars.month,
                day: nil, hour: base.pillars.hour
            ),
            mingGong: base.mingGong, shenGong: base.shenGong, taiYuan: base.taiYuan,
            elementBalance: base.elementBalance,
            favorableElements: base.favorableElements,
            unfavorableElements: base.unfavorableElements,
            dayMasterStrength: base.dayMasterStrength,
            tiaoshouApplied: base.tiaoshouApplied,
            xijiMethod: base.xijiMethod, patternHint: base.patternHint,
            shensha: base.shensha, luckPillars: base.luckPillars,
            currentLuckPillar: base.currentLuckPillar,
            currentYearPillar: base.currentYearPillar,
            currentDayPillar: base.currentDayPillar,
            currentHourPillar: base.currentHourPillar,
            calcRuleSnapshot: base.calcRuleSnapshot,
            boundaryWarning: base.boundaryWarning,
            yearBranchZodiac: base.yearBranchZodiac,
            yearBranchFriends: base.yearBranchFriends,
            yearBranchClash: base.yearBranchClash,
            meta: base.meta
        )
    }
}

// MARK: - Test Doubles

/// health 延迟后转发、其余透传 Mock(测 performRestore 写回重检:撑开 await 窗口)。
private final class SlowHealthAPIClient: APIClient {
    private let base: MockAPIClient
    private let delayNanos: UInt64
    init(base: MockAPIClient, delayNanos: UInt64) {
        self.base = base
        self.delayNanos = delayNanos
    }

    func health() async throws -> HealthResponse {
        try await Task.sleep(nanoseconds: delayNanos)
        return try await base.health()
    }
    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        try await base.calculateBazi(request: request)
    }
    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse {
        try await base.compatibility(request: request)
    }
    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse {
        try await base.dailyFortune(request: request)
    }
    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        try await base.interpret(request: request)
    }
    func redeem(request: EntitlementRedeemRequest) async throws -> EntitlementRedeemResponse {
        try await base.redeem(request: request)
    }
    func entitlementList() async throws -> EntitlementListResponse {
        try await base.entitlementList()
    }
    func signIn(request: SignInRequest) async throws -> SignInResponse {
        try await base.signIn(request: request)
    }
    func syncPull() async throws -> SyncPullResponse { try await base.syncPull() }
    func syncPush(request: SyncPushRequest) async throws -> SyncPushResponse {
        try await base.syncPush(request: request)
    }
}

/// health 恒失败、其余转发 Mock(测 hydrate 失败路径:回填跳过 + 自动续跑不发起)。
private final class HealthFailingAPIClient: APIClient {
    private enum HealthFailError: Error {
        case offline
    }

    private let base: MockAPIClient
    init(base: MockAPIClient) { self.base = base }

    func health() async throws -> HealthResponse { throw HealthFailError.offline }
    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        try await base.calculateBazi(request: request)
    }
    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse {
        try await base.compatibility(request: request)
    }
    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse {
        try await base.dailyFortune(request: request)
    }
    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        try await base.interpret(request: request)
    }
    func redeem(request: EntitlementRedeemRequest) async throws -> EntitlementRedeemResponse {
        try await base.redeem(request: request)
    }
    func entitlementList() async throws -> EntitlementListResponse {
        try await base.entitlementList()
    }
    func signIn(request: SignInRequest) async throws -> SignInResponse {
        try await base.signIn(request: request)
    }
    func syncPull() async throws -> SyncPullResponse { try await base.syncPull() }
    func syncPush(request: SyncPushRequest) async throws -> SyncPushResponse {
        try await base.syncPush(request: request)
    }
}
