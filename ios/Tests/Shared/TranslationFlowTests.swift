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
        // 目标语言 = 繁体(D6 override 直写 UserDefaults,AppLanguage.current 即时生效)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
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

    // MARK: - D10.5:先显示原文 + 提示条

    func testCrossLanguageRestoreShowsSourceTextAndOffer() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: response.contentHash, module: .m1, text: Self.m1ZH)
        let readsBefore = vm.remainingReads

        vm.loadArchivedChart(response: response, request: request)

        let restored = await waitUntil {
            self.vm.moduleStates[.m0] == .ok(text: Self.m0ZH, cached: true)
                && self.vm.moduleStates[.m1] == .ok(text: Self.m1ZH, cached: true)
        }
        XCTAssertTrue(restored, "跨语言命中必须先显示简体原文,实际:\(vm.moduleStates)")
        // 提示条数据源:原文语言 + 可译模块集
        XCTAssertEqual(vm.translationOffer?.sourceLanguage, "zh")
        XCTAssertEqual(vm.translationOffer?.modules, [.m0, .m1])
        // 不自动翻译、不自动起链生成(translationOffer 挂着压制 resume)
        XCTAssertTrue(apiClient.recordedTranslateRequests.isEmpty, "不得自动翻译(点按钮才翻)")
        XCTAssertTrue(
            apiClient.recordedInterpretRequests.filter { ModuleID(rawValue: $0.module) != nil }.isEmpty,
            "翻译提议挂着时不得自动生成(会用原文 fingerprint 造成键错位)"
        )
        XCTAssertEqual(vm.remainingReads, readsBefore, "回填 + 提议零消耗")
    }

    // MARK: - D10.4 #2:译后 M0 字段驱动 M1 请求(核心用例)

    func testAcceptTranslationUsesTranslatedM0FieldsForM1Request() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: response.contentHash, module: .m1, text: Self.m1ZH)
        vm.loadArchivedChart(response: response, request: request)
        let offered = await waitUntil { self.vm.translationOffer != nil }
        XCTAssertTrue(offered, "必须探测到跨语言原文")
        let readsBefore = vm.remainingReads
        installDefaultTranslateResponder()

        vm.acceptTranslation()

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

    // MARK: - D10.4 #4:失败保留已成功,可重试剩余

    func testTranslationFailureKeepsSuccessesAndRetryTranslatesRemaining() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: response.contentHash, module: .m1, text: Self.m1ZH)
        vm.loadArchivedChart(response: response, request: request)
        _ = await waitUntil { self.vm.translationOffer != nil }

        // 第一轮:M0 译成,M1 翻译失败(503 类)
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
        vm.acceptTranslation()
        let firstRound = await waitUntil(timeout: 10) {
            if case .failed = self.vm.moduleStates[.m1] { return true }
            return false
        }
        XCTAssertTrue(firstRound, "M1 必须标 .failed,实际:\(vm.moduleStates)")
        // 已成功的保留(不回滚)
        XCTAssertEqual(vm.moduleStates[.m0], .ok(text: Self.m0Hant, cached: false))
        // 提议保留(可重试剩余)——offer.modules 是初值,重试消费 crossLanguageRows
        XCTAssertNotNil(vm.translationOffer)

        // 第二轮:修复应答,重试只译 M1
        apiClient.translateResponder = { request in
            InterpretResponse(
                interpretation: request.sourceInterpretation,
                promptVersion: 1, cached: false, generatedAt: .now,
                provider: "anthropic", model: "mock-anthropic-model",
                language: "zh-hant", translatedFrom: request.sourceLanguage
            )
        }
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

    // MARK: - STALE_SOURCE 人话(重试语义 = 重新生成)

    func testStaleSourceShowsRegenerateMessage() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        vm.loadArchivedChart(response: response, request: request)
        _ = await waitUntil { self.vm.translationOffer != nil }
        apiClient.translateResponder = { _ in
            throw APIError.backendError(code: "STALE_SOURCE", message: "原文 prompt_version 已过期", requestId: nil)
        }

        vm.acceptTranslation()

        let failed = await waitUntil(timeout: 10) {
            if case .failed(let message) = self.vm.moduleStates[.m0] {
                return message.contains("重新生成")
            }
            return false
        }
        XCTAssertTrue(failed, "STALE_SOURCE 必须显示重新生成人话,实际:\(vm.moduleStates)")
        XCTAssertNotNil(vm.translationOffer, "失败后提议保留(原文还在屏上)")
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
        defer { UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey) }

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
        defer { UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey) }

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
