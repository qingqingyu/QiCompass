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
    private var orchestrator: DeepAnalysisOrchestrator!
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
        // F5(2026-10-06 持久化):降级标记落 UserDefaults,防上个用例残留
        // 污染本用例的自动翻译路由(下游误走重生成)
        DeepStaleM0MarkerPersistence.clearAll()
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
        self.orchestrator = orchestrator
        entitlementStore = EntitlementStore(modelContext: context)
        vm = DeepAnalysisViewModel(
            orchestrator: orchestrator,
            entitlementStore: entitlementStore
        )
    }

    override func tearDown() async throws {
        if let vm {
            // Bug6(2026-10-06):isHydrating 会被换盘/reset 同步复位,旧 hydrate
            // 仍挂在 await 中——加 inflightHydrateCount 才是「无在飞 hydrate」
            _ = await waitUntil(timeout: 10) {
                !vm.isChainRunning && !vm.isHydrating && !vm.isTranslatingChain
                    && vm.inflightHydrateCount == 0
            }
        }
        vm = nil
        orchestrator = nil
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
        // R2(2026-10-02 review):失败章必须保留原文显示——不得标 .failed
        // (那会让这一章只剩错误文案,原文从屏幕消失)
        XCTAssertEqual(
            vm.moduleStates[.m1], .ok(text: Self.m1ZH, cached: true),
            "翻译失败必须恢复 .ok 原文显示"
        )
        XCTAssertTrue(vm.isChapterTranslationFailed(.m1), "失败事实由「翻译失败 · 重试」小注标记驱动")
        XCTAssertTrue(vm.hasCrossLanguageOriginal(for: .m1), "失败章原文行保留(章节级重试应分流到翻译)")
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
        // R2:译成后失败标记清除(章首小注消失)
        XCTAssertFalse(vm.isChapterTranslationFailed(.m1))
        // R2:翻译失败/重试全程不触发生成(章节级「重试」分流的前提:
        // 原文行存在时走翻译,不烧每日次数)
        XCTAssertTrue(
            apiClient.recordedInterpretRequests.filter { ModuleID(rawValue: $0.module) != nil }.isEmpty,
            "翻译失败与重试都不得触发 /api/interpret 生成"
        )
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

    /// Bug1(2026-10-06 review 核实):M0 STALE 降级重生成成功、下游重生成失败
    /// 中断后「重启」(新 VM,同 UserDefaults/双层缓存)——重建的自动翻译链
    /// 必须仍把下游导向豁免重生成;修复前标记仅存内存,重启丢失后 M0 命中
    /// 当语言缓存、提议只剩下游,会被拿去翻译(旧 M0 叙事 × 新 M0 指纹混拼,
    /// 毒化共享缓存键)。
    func test重启后_M0降级标记驱动下游重生成_不翻译() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: response.contentHash, module: .m1, text: Self.m1ZH)
        let readsBefore = vm.remainingReads

        // 第一轮:M0 翻译 409 → 豁免重生成成功(落 zh-hant 键);M1 豁免重生成
        // 失败(网络)→ 断链落 .failed
        apiClient.translateResponder = { _ in
            throw APIError.backendError(code: "STALE_SOURCE", message: "原文 prompt_version 已过期", requestId: nil)
        }
        apiClient.interpretResponder = { req in
            if req.module == "m0_structure" {
                return InterpretResponse(
                    interpretation: Self.m0Hant,
                    promptVersion: 1, cached: false, generatedAt: .now,
                    provider: "anthropic", model: "mock-anthropic-model",
                    language: "zh-hant"
                )
            }
            throw APIError.networkError(URLError(.notConnectedToInternet))
        }
        vm.loadArchivedChart(response: response, request: request)
        let round1 = await waitUntil(timeout: 10) {
            self.vm.autoTranslationState == .failed && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(round1, "M1 降级重生成失败必须断链落 .failed,实际:\(String(describing: vm.autoTranslationState))")
        XCTAssertTrue(
            DeepStaleM0MarkerPersistence.load().contains(response.contentHash + "|zh-hant"),
            "M0 降级标记必须落 UserDefaults(重启前置事实)"
        )

        // 「重启」:新 VM(内存 outcome/rows/markers 全空)同 orchestrator/缓存;
        // M1 重生成改成功
        let vm2 = DeepAnalysisViewModel(orchestrator: orchestrator, entitlementStore: entitlementStore)
        apiClient.interpretResponder = { _ in
            InterpretResponse(
                interpretation: Self.m1ZH,
                promptVersion: 1, cached: false, generatedAt: .now,
                provider: "anthropic", model: "mock-anthropic-model",
                language: "zh-hant"
            )
        }
        vm2.loadArchivedChart(response: response, request: request)
        let round2 = await waitUntil(timeout: 10) {
            vm2.translationOffer == nil && !vm2.isTranslatingChain && vm2.moduleStates[.m1]?.isOk == true
        }
        XCTAssertTrue(round2, "重启后自动链必须经持久化标记把 M1 导向重生成,实际:\(vm2.moduleStates) offer=\(String(describing: vm2.translationOffer))")

        // 核心断言:M1 全程零翻译请求(修复前:提议只剩 M1,会被当原文翻译)
        XCTAssertTrue(
            apiClient.recordedTranslateRequests.filter { $0.base.module == "m1_talent" }.isEmpty,
            "重启后 M1 不得走翻译(旧 M0 叙事 × 新 M0 指纹混拼毒化共享键)"
        )
        XCTAssertEqual(vm2.remainingReads, readsBefore, "两轮降级重生成全程不得消耗每日次数")
        XCTAssertFalse(
            DeepStaleM0MarkerPersistence.load().contains(response.contentHash + "|zh-hant"),
            "全部落定后标记随提议收空清除"
        )
    }

    /// Bug2(2026-10-06 review 核实):自动翻译被换盘中断(未落定)后切回——
    /// 不得谎报「翻译失败」,hydrate 重建提议后必须再自动续译;真失败恢复
    /// 提示条的语义由 F2 用例(testAutoTranslationFailureStateSurvivesChartSwitchAndBack)钉住。
    func test中断的自动翻译_切回后续译_不谎报失败() async throws {
        let requestA = Self.beijingRequest()
        let responseA = try await apiClient.calculateBazi(request: requestA)
        try seedZHCache(hash: responseA.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: responseA.contentHash, module: .m1, text: Self.m1ZH)
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

        // 离线类失败 → .offlinePending(等待联网续译),不是 .failed
        apiClient.translateResponder = { _ in
            throw APIError.networkError(URLError(.notConnectedToInternet))
        }
        vm.loadArchivedChart(response: responseA, request: requestA)
        let offline = await waitUntil(timeout: 10) {
            self.vm.autoTranslationState == .offlinePending && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(offline, "离线失败必须落 .offlinePending(不是 .failed)")

        // 切 B → 等 hydrate 落定 → 切回 A:提议重建,自动翻译必须**再起**,
        // 不得恢复 .failed(修复前 attempted 命中一律恢复失败提示条)
        vm.loadArchivedChart(response: responseB, request: requestB)
        _ = await waitUntil(timeout: 10) { self.vm.inflightHydrateCount == 0 && !self.vm.isHydrating }
        vm.loadArchivedChart(response: responseA, request: requestA)
        let resumed = await waitUntil(timeout: 10) {
            self.vm.autoTranslationState == .offlinePending && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(resumed, "切回后必须自动续译(再次离线落 .offlinePending),不得谎报 .failed,实际:\(String(describing: vm.autoTranslationState))")
        XCTAssertEqual(
            apiClient.recordedTranslateRequests.filter { $0.base.contentHash == responseA.contentHash }.count, 2,
            "切回后的续译必须再发翻译请求(两轮各一次)"
        )
    }

    // MARK: - F1(2026-10-02):豁免配额的重生成命中缓存不得 refund

    /// L4 降级重生成(quotaExempt)全程不动 counter:没扣不退——修复前
    /// 后端缓存命中(cached=true)分支不看豁免标志直接 refund,每章白送
    /// 1 次配额(一张盘最多 +8)。非豁免路径的「扣后即退」行为不回归。
    func testQuotaExemptRegenerationNeverTouchesCounterEvenOnCacheHit() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        let readsBefore = counter.remaining()
        let chainFields = ["main_axis": "{}", "core_loop": "{}"]
        let module = "m1_talent"

        func resp(cached: Bool) -> InterpretResponse {
            InterpretResponse(
                interpretation: "{\"innate\":{},\"one_leverage\":\"x\"}",
                promptVersion: 1, cached: cached, generatedAt: .now,
                provider: "anthropic", model: "mock-anthropic-model",
                language: AppLanguage.currentWire
            )
        }

        // 豁免 × cached 命中:不扣不退(修复前这里白退 +1)
        apiClient.interpretResponder = { _ in resp(cached: true) }
        _ = try await orchestrator.runV1Module(
            response: response, module: module, parentFingerprint: "fp",
            chainFields: chainFields, quotaExempt: true
        )
        XCTAssertEqual(counter.remaining(), readsBefore, "豁免路径 cached 命中不得 refund(没扣不退)")

        // 豁免 × 未命中:同样不动 counter
        apiClient.interpretResponder = { _ in resp(cached: false) }
        _ = try await orchestrator.runV1Module(
            response: response, module: module, parentFingerprint: "fp",
            chainFields: chainFields, quotaExempt: true
        )
        XCTAssertEqual(counter.remaining(), readsBefore, "豁免路径不消耗配额")

        // 非豁免 × cached 命中:扣后即退,净 0(原行为不回归)
        apiClient.interpretResponder = { _ in resp(cached: true) }
        _ = try await orchestrator.runV1Module(
            response: response, module: module, parentFingerprint: "fp",
            chainFields: chainFields
        )
        XCTAssertEqual(counter.remaining(), readsBefore, "非豁免 cached 命中:tryConsume 后 refund,净消耗 0")

        // 非豁免 × 未命中:净 -1(真生成消耗)
        apiClient.interpretResponder = { _ in resp(cached: false) }
        _ = try await orchestrator.runV1Module(
            response: response, module: module, parentFingerprint: "fp",
            chainFields: chainFields
        )
        XCTAssertEqual(counter.remaining(), readsBefore - 1, "非豁免真实生成消耗 1 次")
    }

    // MARK: - F2(2026-10-02):自动翻译失败后换盘再切回不得死路

    /// A 盘自动翻译失败 → 切 B(清洗)→ 切回 A:hydrate 重建提议但会话去重
    /// 不让自动翻译再起——必须恢复 .failed 让提示条以手动重试形态出现
    /// (修复前 autoTranslationState 停 nil:提示条不渲染 + offer 拦死续跑,
    /// 既不翻译也不生成)。修复后不得新增翻译请求(自动不重试语义不变)。
    func testAutoTranslationFailureStateSurvivesChartSwitchAndBack() async throws {
        let requestA = Self.beijingRequest()
        let responseA = try await apiClient.calculateBazi(request: requestA)
        let requestB = BaziCalculateRequest(
            birthDatetime: "1993-07-07T14:00:00", timezone: "Asia/Shanghai",
            gender: "female", longitude: 116.4074, latitude: 39.9042,
            placeName: "北京", geonameId: 1816670, ziHourRule: "zi_next_day"
        )
        let responseB = try await apiClient.calculateBazi(request: requestB)
        XCTAssertNotEqual(responseA.contentHash, responseB.contentHash, "前置:A/B 必须是两张盘")
        try seedZHCache(hash: responseA.contentHash, module: .m0, text: Self.m0ZH)
        apiClient.translateResponder = { _ in
            throw APIError.backendError(code: "AI_PROVIDER_ERROR", message: "同构校验失败", requestId: nil)
        }
        // 耗尽配额:B 盘 hydrate 后不自动起链(本用例聚焦翻译态,不测生成)
        for _ in 0..<DailyReadCounter.ReadLimit.globalDaily {
            _ = counter.tryConsume(module: "bazi_deep")
        }

        // A:自动翻译失败 → .failed
        vm.loadArchivedChart(response: responseA, request: requestA)
        let firstFailed = await waitUntil(timeout: 10) {
            self.vm.autoTranslationState == .failed && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(firstFailed, "A 盘自动翻译第一轮必须失败,实际:\(String(describing: vm.autoTranslationState))")
        let translateCountAfterFirst = apiClient.recordedTranslateRequests.count

        // 切 B:换盘清洗把 autoTranslationState 清 nil
        vm.loadArchivedChart(response: responseB, request: requestB)
        _ = await waitUntil(timeout: 10) { !self.vm.isHydrating }
        XCTAssertNil(vm.autoTranslationState, "换盘清洗后展示态应归 nil")

        // 切回 A:提议重建 + 去重命中 → 恢复 .failed(死路修复的断言点)
        vm.loadArchivedChart(response: responseA, request: requestA)
        let restored = await waitUntil(timeout: 10) {
            self.vm.translationOffer != nil
                && self.vm.autoTranslationState == .failed
                && !self.vm.isHydrating
                && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(restored, "切回 A 后必须有 offer + .failed(提示条手动重试形态),实际 offer=\(String(describing: vm.translationOffer)) auto=\(String(describing: vm.autoTranslationState))")
        XCTAssertEqual(
            apiClient.recordedTranslateRequests.count, translateCountAfterFirst,
            "去重命中不得新增翻译请求(自动不重试语义不变)"
        )

        // 手动重试仍可用(修复应答 → 译完)
        installDefaultTranslateResponder()
        vm.acceptTranslation()
        let retried = await waitUntil(timeout: 10) {
            self.vm.translationOffer == nil && self.vm.autoTranslationState == nil
        }
        XCTAssertTrue(retried, "手动重试必须译完")
    }

    // MARK: - F5 + #6(2026-10-02):M0 降级标记跨重试 + 降级失败断链

    /// M1 原文(含 defensive——M2 的 requiredChainFields 需要;不含会被
    /// missing_parent 兜底截断链,干扰 F5/#6 的复现路径)。
    private static let m1FullZH =
        "{\"innate\":{\"behavior\":\"天生对结构敏感\"},\"defensive\":[\"旧防御\"],\"one_leverage\":\"旧杠杆\"}"
    private static let m2ZH =
        "{\"threshold\":{\"t\":\"旧阈值\"},\"switch_actions\":[\"旧动作\"]}"

    /// 给盘插入 bazi_deep 全本 entitlement(M2+ 付费章解锁;镜像
    /// DeepAnalysisArchiveLoadTests.seedDeepEntitlement 落库形态)。
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

    /// F5:M0 STALE 降级成功 → 下游(M1)降级重生成失败 → 重试进链时
    /// M0 已不在 crossLanguageRows——标记必须跨重试存活,让 M1/M2 继续走
    /// interpret 重生成而非拿旧 M0 时代的原文去翻译(混叙事 + 缓存键错位)。
    func testStaleM0DowngradeFlagSurvivesRetryAfterDownstreamRegenFailure() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedDeepEntitlement(hash: response.contentHash)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: response.contentHash, module: .m1, text: Self.m1FullZH)
        try seedZHCache(hash: response.contentHash, module: .m2, text: Self.m2ZH)
        let readsBefore = vm.remainingReads
        apiClient.translateResponder = { req in
            if req.base.module == "m0_structure" {
                throw APIError.backendError(code: "STALE_SOURCE", message: "原文 prompt_version 已过期", requestId: nil)
            }
            return InterpretResponse(
                interpretation: req.sourceInterpretation,
                promptVersion: 1, cached: false, generatedAt: .now,
                provider: "anthropic", model: "mock-anthropic-model",
                language: "zh-hant", translatedFrom: req.sourceLanguage
            )
        }
        // M1 重生成只失败第一次(重试起放行);M0 恒成功。翻译/生成链严格
        // 串行,flag 无并发访问。
        let m1RegenFailedOnce = FailedOnceFlag()
        apiClient.interpretResponder = { req in
            switch req.module {
            case "m0_structure":
                return InterpretResponse(
                    interpretation: "{\"structure_fingerprint\":\"fp-regen\",\"main_axis\":{},\"core_loop\":{}}",
                    promptVersion: 1, cached: false, generatedAt: .now,
                    provider: "anthropic", model: "mock-anthropic-model",
                    language: "zh-hant"
                )
            case "m1_talent":
                if m1RegenFailedOnce.tryFail() {
                    throw APIError.networkError(URLError(.timedOut))
                }
                return InterpretResponse(
                    interpretation: "{\"innate\":{\"b\":\"重生成\"},\"defensive\":[\"d\"],\"one_leverage\":\"l\"}",
                    promptVersion: 1, cached: false, generatedAt: .now,
                    provider: "anthropic", model: "mock-anthropic-model",
                    language: "zh-hant"
                )
            default:
                return InterpretResponse(
                    interpretation: "{\"one_line\":\"重生成占位\"}",
                    promptVersion: 1, cached: false, generatedAt: .now,
                    provider: "anthropic", model: "mock-anthropic-model",
                    language: "zh-hant"
                )
            }
        }

        vm.loadArchivedChart(response: response, request: request)
        // 第一轮:M0 降级重生成成功,M1 降级重生成失败 → 断链 → .failed
        let firstFailed = await waitUntil(timeout: 10) {
            self.vm.autoTranslationState == .failed && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(firstFailed, "M1 降级重生成失败必须落 .failed,实际:\(String(describing: vm.autoTranslationState))")
        XCTAssertEqual(vm.remainingReads, readsBefore, "降级重生成豁免配额(M0+M1 各一次尝试)")
        XCTAssertEqual(
            apiClient.recordedTranslateRequests.count, 1,
            "只有 M0 发过翻译尝试(收 409 后转降级)"
        )
        // #6(标志位分支):断链后 M2 不动(修复前 continue 会让 M2 用 M1
        // 源语言链字段继续重生成,混合键)
        XCTAssertFalse(
            apiClient.recordedInterpretRequests.map(\.module).contains("m2_high_low"),
            "M1 降级失败断链后 M2 不得被处理(等重试)"
        )

        // 重试(手动提示条路径):M1/M2 必须走 interpret 重生成,不得再发 translate
        vm.acceptTranslation()
        let settled = await waitUntil(timeout: 10) {
            self.vm.translationOffer == nil
                && self.vm.autoTranslationState == nil
                && !self.vm.isTranslatingChain
                && self.vm.moduleStates[.m1]?.isOk == true
                && self.vm.moduleStates[.m2]?.isOk == true
        }
        XCTAssertTrue(settled, "重试后 M1/M2 必须以重生成落 ok,实际:\(vm.moduleStates)")
        XCTAssertEqual(
            apiClient.recordedTranslateRequests.count, 1,
            "F5:重试不得再发翻译请求(M0 降级标记跨重试存活)"
        )
        let generatedModules = Set(
            apiClient.recordedInterpretRequests.map(\.module)
                .filter { ModuleID(rawValue: $0) != nil }
        )
        XCTAssertTrue(generatedModules.contains("m1_talent"), "M1 重试必须走重生成,实际:\(generatedModules)")
        XCTAssertTrue(generatedModules.contains("m2_high_low"), "M2 必须跟进重生成,实际:\(generatedModules)")
    }

    /// #6:中段章节(M1)自身 STALE → 降级重生成失败 → 必须断链(原为
    /// continue):继续翻译 M2 会用 M1 源语言链字段造出正常生成永远不会用的
    /// 混合缓存键,白烧 LLM。失败章保留原文行,提示条可重试。
    func testMidChainStaleRegenFailureStopsDownstreamTranslation() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        try seedDeepEntitlement(hash: response.contentHash)
        try seedZHCache(hash: response.contentHash, module: .m0, text: Self.m0ZH)
        try seedZHCache(hash: response.contentHash, module: .m1, text: Self.m1FullZH)
        try seedZHCache(hash: response.contentHash, module: .m2, text: Self.m2ZH)
        let readsBefore = vm.remainingReads
        apiClient.translateResponder = { req in
            if req.base.module == "m1_talent" {
                throw APIError.backendError(code: "STALE_SOURCE", message: "原文 prompt_version 已过期", requestId: nil)
            }
            return InterpretResponse(
                interpretation: Self.m0Hant,
                promptVersion: 1, cached: false, generatedAt: .now,
                provider: "anthropic", model: "mock-anthropic-model",
                language: "zh-hant", translatedFrom: req.sourceLanguage
            )
        }
        apiClient.interpretResponder = { req in
            if req.module == "m1_talent" {
                throw APIError.networkError(URLError(.timedOut))
            }
            return InterpretResponse(
                interpretation: "{\"one_line\":\"占位\"}",
                promptVersion: 1, cached: false, generatedAt: .now,
                provider: "anthropic", model: "mock-anthropic-model",
                language: "zh-hant"
            )
        }

        vm.loadArchivedChart(response: response, request: request)
        let failed = await waitUntil(timeout: 10) {
            self.vm.autoTranslationState == .failed && !self.vm.isTranslatingChain
        }
        XCTAssertTrue(failed, "M1 降级重生成失败必须落 .failed,实际:\(String(describing: vm.autoTranslationState))")

        // M0 已译成保留;M1 走了生成尝试(降级)且失败
        XCTAssertEqual(vm.moduleStates[.m0], .ok(text: Self.m0Hant, cached: false))
        let generatedModules = Set(
            apiClient.recordedInterpretRequests.map(\.module)
                .filter { ModuleID(rawValue: $0) != nil }
        )
        XCTAssertTrue(generatedModules.contains("m1_talent"), "M1 应已尝试降级重生成")
        // #6 核心断言:M2 既不翻译也不生成(断链,不是 continue)
        XCTAssertTrue(
            apiClient.recordedTranslateRequests.filter { $0.base.module == "m2_high_low" }.isEmpty,
            "降级失败后下游不得继续翻译(混合键白烧 LLM)"
        )
        XCTAssertFalse(generatedModules.contains("m2_high_low"), "断链后下游不得被生成(重试时再降级)")
        // 提议保留(重试入口活着)且豁免全程未扣次数
        XCTAssertNotNil(vm.translationOffer, "失败态必须保留提议供重试")
        XCTAssertEqual(vm.remainingReads, readsBefore, "降级重生成豁免配额")
    }
}

/// 一次性失败标记(翻译/生成链串行执行,无并发访问;class 语义让闭包可翻转)。
private final class FailedOnceFlag {
    private var failed = false
    /// 首次调用返回 true(该次应失败),之后恒 false。
    func tryFail() -> Bool {
        if failed { return false }
        failed = true
        return true
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
        // F5(2026-10-06 持久化):降级标记落 UserDefaults,防上个用例残留
        // 污染本用例的自动翻译路由(下游误走重生成)
        DeepStaleM0MarkerPersistence.clearAll()
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
        // L6/F7:快照同步携带语言列(离线兜底小注的数据源)
        let snapshot = try dailyStore.get(chartHash: "l5-daily", targetDate: date)
        XCTAssertEqual(snapshot?.interpretation, Self.hantJSON)
        XCTAssertEqual(snapshot?.interpretationLanguage, "zh-hant")
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

    /// L6/F7:快照语言列随 updateInterpretation 落库,离线兜底小注数据源。
    func testDailySnapshotLanguageColumnRoundtrip() async throws {
        let payload = ChartPayloadDTO(
            dayMaster: "己", dayMasterElement: "土", dayMasterStrength: "weak",
            favorableElements: ["火", "土"], unfavorableElements: ["水", "金"],
            fourPillars: [:]
        )
        let date = Calendar.current.startOfDay(for: Date())
        let dailyResponse = try await apiClient.dailyFortune(
            request: DailyFortuneRequest(chartHash: "l6-snap", targetDate: date, chartPayload: payload)
        )
        try dailyStore.upsert(
            chartHash: "l6-snap", targetDate: date, response: dailyResponse,
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: date)
        )
        XCTAssertNil(try dailyStore.get(chartHash: "l6-snap", targetDate: date)?.interpretationLanguage,
                     "新快照未写解读前列为 nil(老快照同形;R6 后 VM 对 nil 不显示离线语言小注,不断言语言)")

        try dailyStore.updateInterpretation(
            Self.zhJSON, forChartHash: "l6-snap", targetDate: date,
            provider: "anthropic", model: "mock-anthropic-model", language: "zh"
        )
        XCTAssertEqual(
            try dailyStore.get(chartHash: "l6-snap", targetDate: date)?.interpretationLanguage,
            "zh"
        )
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

    // MARK: - F4(2026-10-02):STALE_SOURCE 降级生成(豁免配额,对齐深度 L4)

    /// 跨语言源 STALE(prompt bump / 后端清库后不可核验)→ 落穿目标语言
    /// 正常生成,豁免配额;不降级的话 24h 窗口内每次进入都命中同一条必败
    /// 翻译,当天新语言永远拿不到解读。
    func testDailyStaleSourceDowngradesToGenerationExempt() async throws {
        let payload = ChartPayloadDTO(
            dayMaster: "己", dayMasterElement: "土", dayMasterStrength: "weak",
            favorableElements: ["火", "土"], unfavorableElements: ["水", "金"],
            fourPillars: [:]
        )
        let date = Calendar.current.startOfDay(for: Date())
        let dailyResponse = try await apiClient.dailyFortune(
            request: DailyFortuneRequest(chartHash: "f4-stale", targetDate: date, chartPayload: payload)
        )
        // 既有 zh 解读(当天,当前语言 zh-hant miss → 跨语言命中)
        try interpretStore.upsert(
            contentHash: "f4-stale", module: "daily_fortune", promptVersion: 4,
            targetDate: date, language: "zh",
            provider: "anthropic", model: "mock-anthropic-model",
            interpretation: Self.zhJSON, generatedAt: .now
        )
        try dailyStore.upsert(
            chartHash: "f4-stale", targetDate: date, response: dailyResponse,
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: date)
        )
        apiClient.translateResponder = { _ in
            throw APIError.backendError(code: "STALE_SOURCE", message: "原文 prompt_version 已过期", requestId: nil)
        }
        let readsBefore = counter.remaining()

        let resp = try await orchestrator.runInterpretation(
            chartHash: "f4-stale", chartPayload: payload,
            dailyResponse: dailyResponse, businessDate: date
        )

        // 降级生成成功:目标语言 + 合法 v4 五段
        XCTAssertEqual(resp.language, "zh-hant", "降级生成跟随生效语言")
        XCTAssertNotNil(DailyInsight.parse(resp.interpretation), "生成结果必须是合法 v4 五段")
        // 走了 /api/interpret 生成
        XCTAssertTrue(
            apiClient.recordedInterpretRequests.contains { $0.module == "daily_fortune" },
            "STALE 必须落穿生成(不得停在必败翻译)"
        )
        // 豁免配额(用户拍板,对齐深度解析 L4)
        XCTAssertEqual(counter.remaining(), readsBefore, "STALE 降级生成不得消耗每日次数")
    }

    /// 非_STALE 翻译失败(离线等)不降级:显式上抛,不偷偷改走生成
    /// (避免离线时误生成/误扣次数;可重试语义保留)。
    func testDailyTranslateNetworkErrorPropagatesWithoutGeneration() async throws {
        let payload = ChartPayloadDTO(
            dayMaster: "己", dayMasterElement: "土", dayMasterStrength: "weak",
            favorableElements: ["火", "土"], unfavorableElements: ["水", "金"],
            fourPillars: [:]
        )
        let date = Calendar.current.startOfDay(for: Date())
        let dailyResponse = try await apiClient.dailyFortune(
            request: DailyFortuneRequest(chartHash: "f4-offline", targetDate: date, chartPayload: payload)
        )
        try interpretStore.upsert(
            contentHash: "f4-offline", module: "daily_fortune", promptVersion: 4,
            targetDate: date, language: "zh",
            provider: "anthropic", model: "mock-anthropic-model",
            interpretation: Self.zhJSON, generatedAt: .now
        )
        try dailyStore.upsert(
            chartHash: "f4-offline", targetDate: date, response: dailyResponse,
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: date)
        )
        apiClient.translateResponder = { _ in
            throw APIError.networkError(URLError(.notConnectedToInternet))
        }
        let readsBefore = counter.remaining()

        do {
            _ = try await orchestrator.runInterpretation(
                chartHash: "f4-offline", chartPayload: payload,
                dailyResponse: dailyResponse, businessDate: date
            )
            XCTFail("离线类翻译失败必须上抛,不得假成功")
        } catch {
            // 期望:网络错误原样上抛(可重试)
        }
        XCTAssertFalse(
            apiClient.recordedInterpretRequests.contains { $0.module == "daily_fortune" },
            "非 STALE 失败不得偷偷改走生成"
        )
        XCTAssertEqual(counter.remaining(), readsBefore, "翻译路径不动配额")
    }
}
