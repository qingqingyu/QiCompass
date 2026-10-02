import SwiftData
import XCTest
@testable import QiCompass

/// 跨语言翻译链路测试(S7,D10.4/D10.5;i18n-zh-hant-plan.md)。
///
/// 场景基底:用户在简体下生成过完整命书(zh 缓存行),切换到繁体
/// (AppLanguage.overrideDefaultsKey = "zh-hant")后打开报告:
/// - 先显示简体原文 + translationOffer(D10.5,不自动批量翻译)
/// - 点 acceptTranslation:先译 M0,**译后 M0 的 structure_fingerprint 驱动
///   M1 的翻译请求**(D10.4 #2——缓存键对齐的链式前提)
/// - 失败保留已成功、可重试剩余(D10.4 #4);STALE_SOURCE 显式人话
/// - 翻译不消耗每日次数(D10.1)
@MainActor
final class TranslationFlowTests: XCTestCase {

    private var container: ModelContainer!
    private var vm: DeepAnalysisViewModel!
    private var apiClient: MockAPIClient!
    private var chartStore: ChartSnapshotStore!
    private var interpretStore: InterpretationCacheStore!
    private var counter: DailyReadCounter!
    private var entitlementStore: EntitlementStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 目标语言 = 繁体(D6 override 直写 UserDefaults)。L1/F2 起生效语言读
        // **启动快照**——同步注入快照 = 模拟「重启后 zh-hant 生效」的进程
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
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
        if let vm {
            _ = await waitUntil(timeout: 10) { !vm.isChainRunning && !vm.isHydrating && !vm.isTranslatingChain }
        }
        vm = nil
        entitlementStore = nil
        counter = nil
        interpretStore = nil
        chartStore = nil
        apiClient = nil
        container = nil
        UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        try await super.tearDown()
    }

    // MARK: - 夹具

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

    /// 简体 M0 原文(fingerprint = fp-zh,与译后 fp-hant 区分——断言依赖此差异)
    private static let m0ZH =
        "{\"structure_fingerprint\":\"fp-zh\",\"main_axis\":{},\"core_loop\":{}}"
    /// 译后 M0(繁体,fingerprint = fp-hant):translateResponder 注入
    private static let m0Hant =
        "{\"structure_fingerprint\":\"fp-hant\",\"main_axis\":{},\"core_loop\":{}}"
    /// 简体 M1 原文(v1 JSON 契约,自愈/链字段提取可解析)
    private static let m1ZH =
        "{\"innate\":{\"behavior\":\"天生对结构敏感\"},\"one_leverage\":\"把敏感变成产出\"}"

    private func seedZHCache(hash: String, module: ModuleID, text: String) throws {
        try interpretStore.upsert(
            contentHash: hash, module: module.rawValue, promptVersion: 1, targetDate: nil,
            language: "zh",
            provider: "anthropic", model: "mock-anthropic-model",
            interpretation: text, generatedAt: .now
        )
    }

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

    /// 默认 translate 应答:m0 返回繁体 M0(带译后 fingerprint),其余原文透传。
    private func installDefaultTranslateResponder() {
        apiClient.translateResponder = { request in
            if request.base.module == "m0_structure" {
                return InterpretResponse(
                    interpretation: Self.m0Hant,
                    promptVersion: 1, cached: false, generatedAt: .now,
                    provider: "anthropic", model: "mock-anthropic-model",
                    language: "zh-hant", translatedFrom: request.sourceLanguage
                )
            }
            return InterpretResponse(
                interpretation: request.sourceInterpretation,
                promptVersion: 1, cached: false, generatedAt: .now,
                provider: "anthropic", model: "mock-anthropic-model",
                language: "zh-hant", translatedFrom: request.sourceLanguage
            )
        }
    }

    // MARK: - L3/F1:打开即自动翻译(修订 D10.5)

    func testCrossLanguageRestoreAutoTranslatesWithoutUserTap() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: response.contentHash, module: .m1, text: Self.m1ZH)
        let readsBefore = vm.remainingReads
        installDefaultTranslateResponder()

        vm.loadArchivedChart(response: response, request: request)

        // 先等 hydrate 实际产出(offer 或译文任一)——防「三个条件初始即空真」
        // 的假通过(loadArchivedChart 的 hydrate Task 尚未启动时 offer/状态全 nil)
        let produced = await waitUntil(timeout: 10) {
            self.vm.translationOffer != nil || self.vm.moduleStates[.m0] != nil
        }
        XCTAssertTrue(produced, "必须探测到跨语言原文,实际:\(vm.moduleStates)")
        let done = await waitUntil(timeout: 10) {
            self.vm.translationOffer == nil
                && !self.vm.isTranslatingChain
                && self.vm.autoTranslationState == nil
        }
        XCTAssertTrue(done, "hydrate 后必须自动译完(无需用户点按),实际 offer=\(String(describing: vm.translationOffer)) translating=\(vm.isTranslatingChain) auto=\(String(describing: vm.autoTranslationState))")

        // 自动发起(全程无手动 acceptTranslation)
        XCTAssertFalse(apiClient.recordedTranslateRequests.isEmpty, "必须自动发出翻译请求")
        // 译文落态:M0 = 繁体译文
        XCTAssertEqual(vm.moduleStates[.m0], .ok(text: Self.m0Hant, cached: false))
        // 翻译不消耗每日次数(D10.1)
        XCTAssertEqual(vm.remainingReads, readsBefore)
        // 不触发生成(翻译路径全程无 /api/interpret v1 调用)
        XCTAssertTrue(
            apiClient.recordedInterpretRequests.filter { ModuleID(rawValue: $0.module) != nil }.isEmpty
        )
    }

    /// 会话去重:自动翻译失败后,同 (hash, target) 重进页面不再自动起
    /// (防循环烧 LLM);手动重试仍可用。
    func testAutoTranslationDedupedPerSessionAfterFailure() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        apiClient.translateResponder = { _ in
            throw APIError.backendError(code: "AI_PROVIDER_ERROR", message: "同构校验失败", requestId: nil)
        }

        vm.loadArchivedChart(response: response, request: request)
        let firstFailed = await waitUntil(timeout: 10) {
            self.vm.autoTranslationState == .failed && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(firstFailed, "自动翻译第一轮必须失败落 .failed,实际:\(String(describing: vm.autoTranslationState))")
        let requestsAfterFirst = apiClient.recordedTranslateRequests.count
        XCTAssertGreaterThan(requestsAfterFirst, 0)

        // 同 hash 重进(loadArchivedChart 重入):不得再自动起翻
        vm.loadArchivedChart(response: response, request: request)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(
            apiClient.recordedTranslateRequests.count, requestsAfterFirst,
            "会话内自动翻译只起一次(失败走手动重试)"
        )
        XCTAssertEqual(vm.autoTranslationState, .failed, "失败态保持(提示条重试入口)")

        // 手动重试仍可用(提示条按钮路径;先等第二次 hydrate 落定——
        // acceptTranslation 的 isHydrating 守卫会吞掉 hydrate 在飞期的调用)
        installDefaultTranslateResponder()
        _ = await waitUntil(timeout: 10) {
            !self.vm.isHydrating && self.vm.translationOffer != nil
        }
        vm.acceptTranslation()
        let retried = await waitUntil(timeout: 10) {
            self.vm.translationOffer == nil && self.vm.autoTranslationState == nil
        }
        XCTAssertTrue(retried, "手动重试必须译完")
    }

    /// 离线类失败:提示「联网后自动译」,回前台自动重试**至多一次**——
    /// 二次仍离线则不再自动(额度一次性)。
    func testOfflineAutoTranslationRetriesOnceViaForeground() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        let offline = APIError.networkError(URLError(.notConnectedToInternet))
        apiClient.translateResponder = { _ in throw offline }

        vm.loadArchivedChart(response: response, request: request)
        let offlinePending = await waitUntil(timeout: 10) {
            self.vm.autoTranslationState == .offlinePending && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(offlinePending, "离线失败必须落 .offlinePending,实际:\(String(describing: vm.autoTranslationState))")
        let requestsAfterFirst = apiClient.recordedTranslateRequests.count

        // 回前台重试一次(scenePhase 路径),仍离线 → 二次失败转 .failed
        // (额度一次性:offlineRetryUsed 已置位)
        vm.retryOfflineTranslationIfNeeded()
        let secondFailed = await waitUntil(timeout: 10) {
            self.vm.autoTranslationState == .failed && !self.vm.isTranslatingChain
                && apiClient.recordedTranslateRequests.count > requestsAfterFirst
        }
        XCTAssertTrue(secondFailed, "回前台必须自动重试一次,且二次失败转 .failed,实际:\(String(describing: vm.autoTranslationState))")
        let countAfterSecond = apiClient.recordedTranslateRequests.count

        // 额度已用:再次回前台不再自动
        vm.retryOfflineTranslationIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(
            apiClient.recordedTranslateRequests.count, countAfterSecond,
            "离线自动重试额度一次性,用尽不再自动(手动重试仍可用)"
        )
    }

    // MARK: - D10.4 #2:译后 M0 字段驱动 M1 请求(核心用例,自动翻译触发)

    func testAcceptTranslationUsesTranslatedM0FieldsForM1Request() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: response.contentHash, module: .m1, text: Self.m1ZH)
        let readsBefore = vm.remainingReads
        installDefaultTranslateResponder()

        // L3/F1:hydrate 收尾自动起翻(不再手动 acceptTranslation)
        vm.loadArchivedChart(response: response, request: request)

        let produced = await waitUntil(timeout: 10) {
            self.vm.translationOffer != nil || self.vm.moduleStates[.m0] != nil
        }
        XCTAssertTrue(produced, "必须探测到跨语言原文,实际:\(vm.moduleStates)")
        let done = await waitUntil(timeout: 10) {
            self.vm.translationOffer == nil && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(done, "翻译链必须落定,实际 offer=\(String(describing: vm.translationOffer)) translating=\(vm.isTranslatingChain)")

        // 翻译顺序:M0 先于 M1(D10.4 #1)
        let modules = apiClient.recordedTranslateRequests.map(\.base.module)
        guard let m0Idx = modules.firstIndex(of: "m0_structure"),
              let m1Idx = modules.firstIndex(of: "m1_talent") else {
            return XCTFail("必须发出 m0 + m1 翻译请求,实际:\(modules)")
        }
        XCTAssertLessThan(m0Idx, m1Idx, "必须先译 M0 再译 M1")

        // 核心断言(镜像 testV1ChainSendsRequiredChainFieldsInRequest 范式):
        // M1 的翻译请求用**译后 M0** 的 fingerprint/链字段(fp-hant,非 fp-zh)
        let m1Request = apiClient.recordedTranslateRequests[m1Idx]
        XCTAssertEqual(m1Request.base.parentFingerprint, "fp-hant",
                       "M1 翻译请求的 parent_fingerprint 必须来自译后 M0(D10.4 #2)")
        XCTAssertEqual(m1Request.base.context["structure_fingerprint"]?.value as? String, "fp-hant")
        XCTAssertEqual(m1Request.sourceLanguage, "zh")
        XCTAssertEqual(m1Request.sourcePromptVersion, 1)

        // 译文落态:M0 显示繁体译文(译后缓存键已由 orchestrator 写入)
        XCTAssertEqual(vm.moduleStates[.m0], .ok(text: Self.m0Hant, cached: false))
        // 翻译不消耗每日次数(D10.1)
        XCTAssertEqual(vm.remainingReads, readsBefore)
        // 不触发生成(翻译路径全程无 /api/interpret v1 调用)
        XCTAssertTrue(
            apiClient.recordedInterpretRequests.filter { ModuleID(rawValue: $0.module) != nil }.isEmpty
        )
    }

    // MARK: - D10.4 #4:失败保留已成功,可重试剩余(自动触发 + 手动重试)

    func testTranslationFailureKeepsSuccessesAndRetryTranslatesRemaining() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: response.contentHash, module: .m1, text: Self.m1ZH)

        // 第一轮(自动触发):M0 译成,M1 翻译失败(503 类)
        apiClient.translateResponder = { request in
            if request.base.module == "m0_structure" {
                return InterpretResponse(
                    interpretation: Self.m0Hant,
                    promptVersion: 1, cached: false, generatedAt: .now,
                    provider: "anthropic", model: "mock-anthropic-model",
                    language: "zh-hant", translatedFrom: "zh"
                )
            }
            throw APIError.backendError(code: "AI_PROVIDER_ERROR", message: "同构校验失败", requestId: nil)
        }
        vm.loadArchivedChart(response: response, request: request)
        let firstRound = await waitUntil(timeout: 10) {
            self.vm.autoTranslationState == .failed && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(firstRound, "自动翻译失败必须落 .failed,实际:\(String(describing: vm.autoTranslationState))")
        // 已成功的保留(不回滚)
        XCTAssertEqual(vm.moduleStates[.m0], .ok(text: Self.m0Hant, cached: false))
        // 提议保留(可重试剩余)——offer.modules 是初值,重试消费 crossLanguageRows
        XCTAssertNotNil(vm.translationOffer)

        // 第二轮(手动重试):修复应答,重试只译 M1
        installDefaultTranslateResponder()
        vm.acceptTranslation()
        let secondRound = await waitUntil(timeout: 10) {
            self.vm.translationOffer == nil && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(secondRound, "重试后必须全部译完")
        XCTAssertEqual(
            apiClient.recordedTranslateRequests.filter { $0.base.module == "m0_structure" }.count, 1,
            "已译成的 M0 不得重复翻译(重试只译剩余)"
        )
        XCTAssertEqual(vm.moduleStates[.m1], .ok(text: Self.m1ZH, cached: false))
    }

    // MARK: - L4/F5:STALE_SOURCE 自动降级重生成(豁免配额,不断链)

    /// M0 原文过期:翻译 STALE → M0 转目标语言重生成(exempt);下游原文基于
    /// 旧 M0,一并转重生成(不再发翻译请求);全程零配额消耗。
    func testStaleM0DowngradesWholeChainToRegenerationExempt() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: response.contentHash, module: .m1, text: Self.m1ZH)
        let readsBefore = vm.remainingReads
        apiClient.translateResponder = { _ in
            throw APIError.backendError(code: "STALE_SOURCE", message: "原文 prompt_version 已过期", requestId: nil)
        }

        vm.loadArchivedChart(response: response, request: request)

        let settled = await waitUntil(timeout: 10) {
            self.vm.translationOffer == nil
                && self.vm.autoTranslationState == nil
                && !self.vm.isTranslatingChain
                && self.vm.moduleStates[.m0]?.isOk == true
                && self.vm.moduleStates[.m1]?.isOk == true
        }
        XCTAssertTrue(settled, "M0 STALE 必须降级重生成且下游跟进,实际:\(vm.moduleStates) auto=\(String(describing: vm.autoTranslationState))")

        // M0 走了翻译尝试(收到 409),M1 完全没翻译(降级转生成)
        XCTAssertEqual(
            apiClient.recordedTranslateRequests.filter { $0.base.module == "m0_structure" }.count, 1
        )
        XCTAssertTrue(
            apiClient.recordedTranslateRequests.filter { $0.base.module == "m1_talent" }.isEmpty,
            "M0 过期后下游不得再翻译(原文基于旧 M0,翻译会混叙事)"
        )
        // 两章都走 /api/interpret 重生成(mock 应答 JSON 契约)
        let generatedModules = apiClient.recordedInterpretRequests
            .map(\.module)
            .filter { ModuleID(rawValue: $0) != nil }
        XCTAssertTrue(generatedModules.contains("m0_structure"), "M0 必须重生成,实际:\(generatedModules)")
        XCTAssertTrue(generatedModules.contains("m1_talent"), "M1 必须跟进重生成,实际:\(generatedModules)")
        // 豁免配额(L4/F5:语言切换引发,用户无过错)
        XCTAssertEqual(vm.remainingReads, readsBefore, "降级重生成不得消耗每日次数")
    }

    /// 中段章节(M1)过期:仅该章降级重生成,M0 已译成保留,后续章继续翻译。
    func testStaleMidChainRegeneratesOnlyThatModule() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: response.contentHash, module: .m1, text: Self.m1ZH)
        let readsBefore = vm.remainingReads
        apiClient.translateResponder = { req in
            if req.base.module == "m1_talent" {
                throw APIError.backendError(code: "STALE_SOURCE", message: "原文 prompt_version 已过期", requestId: nil)
            }
            return InterpretResponse(
                interpretation: Self.m0Hant,
                promptVersion: 1, cached: false, generatedAt: .now,
                provider: "anthropic", model: "mock-anthropic-model",
                language: "zh-hant", translatedFrom: "zh"
            )
        }

        vm.loadArchivedChart(response: response, request: request)

        let settled = await waitUntil(timeout: 10) {
            self.vm.translationOffer == nil
                && self.vm.autoTranslationState == nil
                && !self.vm.isTranslatingChain
                && self.vm.moduleStates[.m0]?.isOk == true
                && self.vm.moduleStates[.m1]?.isOk == true
        }
        XCTAssertTrue(settled, "M1 STALE 必须单章降级,其余照译,实际:\(vm.moduleStates)")

        // M0 译成(译文落态),M1 走生成,链未断
        XCTAssertEqual(vm.moduleStates[.m0], .ok(text: Self.m0Hant, cached: false))
        let generatedModules = apiClient.recordedInterpretRequests
            .map(\.module)
            .filter { ModuleID(rawValue: $0) != nil }
        XCTAssertEqual(generatedModules, ["m1_talent"], "只有 M1 重生成,实际:\(generatedModules)")
        XCTAssertEqual(vm.remainingReads, readsBefore, "降级重生成不得消耗每日次数")
    }

}

// MARK: - 合盘跨语言探测(orchestrator 层)

@MainActor
final class CompatibilityCrossLanguageCacheTests: XCTestCase {

    func testCrossLanguageProbeFindsFreeModuleRow() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let apiClient = MockAPIClient()
        let interpretStore = InterpretationCacheStore(context: context)
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: apiClient),
            cacheStore: interpretStore
        )
        let orchestrator = CompatibilityOrchestrator(
            apiClient: apiClient,
            compatibilityStore: CompatibilitySnapshotStore(context: context),
            chartStore: ChartSnapshotStore(context: context),
            interpretStore: interpretStore,
            counter: DailyReadCounter.makeIsolatedForTesting(),
            interpretationReader: reader
        )
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        // L1/F2:生效语言读启动快照,注入快照模拟「重启后 zh-hant 生效」
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
            UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        }

        // zh 的 compatibility_free 行(当前语言 zh-hant miss → 跨语言命中)
        try interpretStore.upsert(
            contentHash: "compat-hash-1", module: "compatibility_free",
            promptVersion: 4, targetDate: nil, language: "zh",
            provider: "anthropic", model: "mock-anthropic-model",
            interpretation: "第一章 基础相处模式\n\n两人节奏。", generatedAt: .now
        )

        let hit = try await orchestrator.cachedCrossLanguageInterpretationIfFresh(
            compatibilityHash: "compat-hash-1"
        )
        XCTAssertEqual(hit?.language, "zh")
        XCTAssertEqual(hit?.module, "compatibility_free")
        XCTAssertTrue(hit?.text.contains("基础相处") == true)

        // 无行 hash → nil(不误报)
        let miss = try await orchestrator.cachedCrossLanguageInterpretationIfFresh(
            compatibilityHash: "compat-hash-none"
        )
        XCTAssertNil(miss)
    }

    /// 目标语言 free/paid 已有行时不跨语言(防「已生成过译文还展示旧原文+提议」:
    /// VM 当前语言检查只读 legacy alias 键,看不到现役写键——守卫在本函数拦)。
    func testCurrentLanguageRowSuppressesCrossLanguageProbe() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let apiClient = MockAPIClient()
        let interpretStore = InterpretationCacheStore(context: context)
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: apiClient),
            cacheStore: interpretStore
        )
        let orchestrator = CompatibilityOrchestrator(
            apiClient: apiClient,
            compatibilityStore: CompatibilitySnapshotStore(context: context),
            chartStore: ChartSnapshotStore(context: context),
            interpretStore: interpretStore,
            counter: DailyReadCounter.makeIsolatedForTesting(),
            interpretationReader: reader
        )
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        // L1/F2:生效语言读启动快照,注入快照模拟「重启后 zh-hant 生效」
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
            UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        }

        // 旧 zh 行 + 当前语言(zh-hant)行并存:后者存在 → 不跨语言
        try interpretStore.upsert(
            contentHash: "compat-hash-2", module: "compatibility_free",
            promptVersion: 4, targetDate: nil, language: "zh",
            provider: "anthropic", model: "mock-anthropic-model",
            interpretation: "第一章 基础相处模式\n\n两人节奏。", generatedAt: .now
        )
        try interpretStore.upsert(
            contentHash: "compat-hash-2", module: "compatibility_free",
            promptVersion: 4, targetDate: nil, language: "zh-hant",
            provider: "anthropic", model: "mock-anthropic-model",
            interpretation: "第一章 基礎相處模式\n\n兩人節奏。", generatedAt: .now
        )

        let hit = try await orchestrator.cachedCrossLanguageInterpretationIfFresh(
            compatibilityHash: "compat-hash-2"
        )
        XCTAssertNil(hit, "目标语言已有行时不得跨语言(译文已在缓存,不应展示旧原文+提议)")
    }
}

// MARK: - 每日运势跨语言翻译(L5/F3,2026-10-01 修订 D10 模块表)

@MainActor
final class DailyFortuneTranslateTests: XCTestCase {

    private var container: ModelContainer!
    private var apiClient: MockAPIClient!
    private var interpretStore: InterpretationCacheStore!
    private var dailyStore: DailyFortuneSnapshotStore!
    private var counter: DailyReadCounter!
    private var reader: CachedInterpretationReader!
    private var orchestrator: DailyFortuneOrchestrator!

    private static let zhJSON =
        "{\"headline\":\"静心开局\",\"work\":\"先做要紧的事。\",\"relationships\":\"话留三分。\",\"energy\":\"按自己的节奏来。\",\"reminder\":\"量力而行。\"}"
    private static let hantJSON =
        "{\"headline\":\"靜心開局\",\"work\":\"先做要緊的事。\",\"relationships\":\"話留三分。\",\"energy\":\"按自己的節奏來。\",\"reminder\":\"量力而行。\"}"

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 生效语言 = zh-hant(L1/F2:注入启动快照模拟重启后生效)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        apiClient = MockAPIClient()
        interpretStore = InterpretationCacheStore(context: context)
        dailyStore = DailyFortuneSnapshotStore(context: context)
        counter = DailyReadCounter.makeIsolatedForTesting()
        reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: apiClient),
            cacheStore: interpretStore
        )
        orchestrator = DailyFortuneOrchestrator(
            apiClient: apiClient,
            dailyStore: dailyStore,
            interpretStore: interpretStore,
            chartStore: ChartSnapshotStore(context: context),
            counter: counter,
            interpretationReader: reader
        )
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        orchestrator = nil
        reader = nil
        counter = nil
        dailyStore = nil
        interpretStore = nil
        apiClient = nil
        container = nil
        try await super.tearDown()
    }

    /// 次数耗尽 + 当天已有 zh 解读 → 翻译而来,不扣次数、不触发生成。
    func testDailyCrossLanguageTranslateSkipsQuota() async throws {
        let payload = ChartPayloadDTO(
            dayMaster: "己", dayMasterElement: "土", dayMasterStrength: "weak",
            favorableElements: ["火", "土"], unfavorableElements: ["水", "金"],
            fourPillars: [:]
        )
        let date = Calendar.current.startOfDay(for: Date())
        let dailyResponse = try await apiClient.dailyFortune(
            request: DailyFortuneRequest(chartHash: "l5-daily", targetDate: date, chartPayload: payload)
        )
        // 快照先行(生产链路 runDeterministic 落档;updateInterpretation 依赖行存在)
        try dailyStore.upsert(
            chartHash: "l5-daily", targetDate: date, response: dailyResponse,
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: date)
        )
        // 既有 zh 解读(当天)
        try interpretStore.upsert(
            contentHash: "l5-daily", module: "daily_fortune", promptVersion: 4,
            targetDate: date, language: "zh",
            provider: "anthropic", model: "mock-anthropic-model",
            interpretation: Self.zhJSON, generatedAt: .now
        )
        // 次数耗尽(P3 场景:切语言当天一段都看不到 → L5 后翻译不受限)
        for _ in 0..<DailyReadCounter.ReadLimit.globalDaily {
            _ = counter.tryConsume(module: "daily_fortune")
        }
        XCTAssertEqual(counter.remaining(), 0)
        apiClient.translateResponder = { _ in
            InterpretResponse(
                interpretation: Self.hantJSON,
                promptVersion: 4, cached: false, generatedAt: .now,
                provider: "anthropic", model: "mock-anthropic-model",
                language: "zh-hant", translatedFrom: "zh"
            )
        }

        let resp = try await orchestrator.runInterpretation(
            chartHash: "l5-daily", chartPayload: payload,
            dailyResponse: dailyResponse, businessDate: date
        )

        XCTAssertEqual(resp.interpretation, Self.hantJSON, "次数耗尽仍须拿到译文(翻译不受配额限制)")
        XCTAssertEqual(resp.language, "zh-hant")
        XCTAssertEqual(counter.remaining(), 0, "翻译不得消耗每日次数")
        XCTAssertTrue(
            apiClient.recordedInterpretRequests.filter { $0.module == "daily_fortune" }.isEmpty,
            "有源时不得触发生成(生成会扣次数/结论会变)"
        )
        // 译文已落目标语言缓存键:再读直接命中(客户端侧键对齐)
        let cached = try await reader.read(
            contentHash: "l5-daily", module: "daily_fortune",
            targetDate: date, maxAge: 24 * 3600
        )
        XCTAssertEqual(cached?.interpretation, Self.hantJSON)
        XCTAssertEqual(cached?.language, "zh-hant")
    }

    /// 无源(其它语言也没有)→ 照旧生成路径(扣次数)。
    func testDailyNoSourceFallsBackToGeneration() async throws {
        let payload = ChartPayloadDTO(
            dayMaster: "己", dayMasterElement: "土", dayMasterStrength: "weak",
            favorableElements: ["火", "土"], unfavorableElements: ["水", "金"],
            fourPillars: [:]
        )
        let date = Calendar.current.startOfDay(for: Date())
        let dailyResponse = try await apiClient.dailyFortune(
            request: DailyFortuneRequest(chartHash: "l5-daily-2", targetDate: date, chartPayload: payload)
        )

        try dailyStore.upsert(
            chartHash: "l5-daily-2", targetDate: date, response: dailyResponse,
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: date)
        )
        let resp = try await orchestrator.runInterpretation(
            chartHash: "l5-daily-2", chartPayload: payload,
            dailyResponse: dailyResponse, businessDate: date
        )

        XCTAssertEqual(counter.remaining(), DailyReadCounter.ReadLimit.globalDaily - 1, "无源生成照旧扣次数")
        XCTAssertFalse(
            apiClient.recordedInterpretRequests.filter { $0.module == "daily_fortune" }.isEmpty,
            "无源必须走 /api/interpret 生成"
        )
        XCTAssertEqual(resp.language, "zh-hant", "mock interpret 跟随生效语言")
    }

    /// 译文未过 v4 五段契约 → 显式抛错,毒化不落缓存(镜像 S6 自愈判据)。
    func testDailyMalformedTranslationRejected() async throws {
        let payload = ChartPayloadDTO(
            dayMaster: "己", dayMasterElement: "土", dayMasterStrength: "weak",
            favorableElements: ["火", "土"], unfavorableElements: ["水", "金"],
            fourPillars: [:]
        )
        let date = Calendar.current.startOfDay(for: Date())
        let dailyResponse = try await apiClient.dailyFortune(
            request: DailyFortuneRequest(chartHash: "l5-daily-3", targetDate: date, chartPayload: payload)
        )
        try interpretStore.upsert(
            contentHash: "l5-daily-3", module: "daily_fortune", promptVersion: 4,
            targetDate: date, language: "zh",
            provider: "anthropic", model: "mock-anthropic-model",
            interpretation: Self.zhJSON, generatedAt: .now
        )
        try dailyStore.upsert(
            chartHash: "l5-daily-3", targetDate: date, response: dailyResponse,
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: date)
        )
        apiClient.translateResponder = { _ in
            InterpretResponse(
                interpretation: "半截散文,不是五键 JSON",
                promptVersion: 4, cached: false, generatedAt: .now,
                provider: "anthropic", model: "mock-anthropic-model",
                language: "zh-hant", translatedFrom: "zh"
            )
        }

        do {
            _ = try await orchestrator.runInterpretation(
                chartHash: "l5-daily-3", chartPayload: payload,
                dailyResponse: dailyResponse, businessDate: date
            )
            XCTFail("坏译文必须抛错,不得 200")
        } catch {
            guard case DeepAnalysisError.translatedContentInvalid = error else {
                return XCTFail("应抛 translatedContentInvalid,实际:\(error)")
            }
        }
        let cached = try await reader.read(
            contentHash: "l5-daily-3", module: "daily_fortune",
            targetDate: date, maxAge: 24 * 3600
        )
        XCTAssertNil(cached, "坏译文不得入缓存(毒化会静默卡到次日)")
    }
}
