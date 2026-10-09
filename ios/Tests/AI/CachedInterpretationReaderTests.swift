import SwiftData
import XCTest
@testable import QiCompass

/// CachedInterpretationReader 单元测试 — 覆盖 7 条路径:
/// 命中(fresh + identity 匹配)/ miss / 过期(maxAge)/ maxAge=nil 不过期 / health 失败 throw / provider 切换 miss / targetDate 维度。
///
/// 注意:每个测试都内联创建 `container + store + reader`,不能用 helper 让 container 出 scope
/// (ModelContext 失效会让 reader.read 在 context.fetch 时 crash)。
@MainActor
final class CachedInterpretationReaderTests: XCTestCase {

    // 1. identity 匹配 + maxAge 内 → 返回 cache
    func testReadReturnsCacheWhenFreshAndIdentityMatches() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        try store.upsert(
            contentHash: "h", module: "bazi_deep", promptVersion: 1, targetDate: nil,
            provider: "anthropic", model: "claude-test",
            interpretation: "anthropic text", generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: Self.healthOnlyClient(provider: "anthropic", model: "claude-test")),
            cacheStore: store
        )
        let cache = try await reader.read(contentHash: "h", module: "bazi_deep", maxAge: 24 * 3600)
        XCTAssertEqual(cache?.interpretation, "anthropic text")
        XCTAssertEqual(cache?.provider, "anthropic")
        XCTAssertEqual(cache?.model, "claude-test")
    }

    // 2. cache 不存在 → nil
    func testReadReturnsNilWhenCacheMiss() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: Self.healthOnlyClient()),
            cacheStore: store
        )
        let cache = try await reader.read(contentHash: "missing", module: "bazi_deep")
        XCTAssertNil(cache)
    }

    // 3. cache 存在但超过 maxAge → nil
    func testReadReturnsNilWhenExpired() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        try store.upsert(
            contentHash: "h", module: "bazi_deep", promptVersion: 1, targetDate: nil,
            provider: "anthropic", model: "claude-test",
            interpretation: "stale text",
            generatedAt: Date().addingTimeInterval(-25 * 3600)  // 25h 前
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: Self.healthOnlyClient()),
            cacheStore: store
        )
        let cache = try await reader.read(contentHash: "h", module: "bazi_deep", maxAge: 24 * 3600)
        XCTAssertNil(cache)
    }

    // 4. maxAge=nil(默认)→ 不过期,即使 100h 老也返回
    func testReadReturnsCacheWhenMaxAgeIsNil() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        try store.upsert(
            contentHash: "h", module: "bazi_deep", promptVersion: 1, targetDate: nil,
            provider: "anthropic", model: "claude-test",
            interpretation: "old but visible",
            generatedAt: Date().addingTimeInterval(-100 * 3600)
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: Self.healthOnlyClient()),
            cacheStore: store
        )
        let cache = try await reader.read(contentHash: "h", module: "bazi_deep")
        XCTAssertEqual(cache?.interpretation, "old but visible")
    }

    // 5. health 失败 → throw(identity 解析失败不静默吞)
    func testReadThrowsWhenHealthFails() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: ReaderTestAPIClient(healthResults: [.failure(.healthUnavailable)])),
            cacheStore: store
        )
        do {
            _ = try await reader.read(contentHash: "h", module: "bazi_deep")
            XCTFail("health 失败应向上抛")
        } catch let error as ReaderTestError {
            XCTAssertEqual(error, .healthUnavailable)
        }
    }

    // 6. provider 切换 → 第二次读 nil(身份不匹配)
    func testReadReturnsNilWhenIdentitySwitches() async throws {
        let apiClient = ReaderTestAPIClient(healthResults: [
            .success(Self.health(provider: "anthropic", model: "claude-test")),
            .success(Self.health(provider: "openai", model: "gpt-test")),
        ])
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        try store.upsert(
            contentHash: "h", module: "bazi_deep", promptVersion: 1, targetDate: nil,
            provider: "anthropic", model: "claude-test",
            interpretation: "anthropic text", generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: apiClient),
            cacheStore: store
        )
        let first = try await reader.read(contentHash: "h", module: "bazi_deep")
        let second = try await reader.read(contentHash: "h", module: "bazi_deep")
        XCTAssertEqual(first?.interpretation, "anthropic text")
        XCTAssertNil(second)
    }

    // 7. daily_fortune 路径,targetDate 正确传入
    func testReadPassesTargetDateForDailyFortune() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsert(
            contentHash: "h", module: "daily_fortune", promptVersion: 1,
            targetDate: date,
            provider: "anthropic", model: "claude-test",
            interpretation: "daily text", generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: Self.healthOnlyClient()),
            cacheStore: store
        )
        let cache = try await reader.read(
            contentHash: "h", module: "daily_fortune",
            targetDate: date, maxAge: 24 * 3600
        )
        XCTAssertEqual(cache?.interpretation, "daily text")
    }

    // MARK: - readAll 批量读(2026-09-08 断点续跑:冷启动回填捌章)

    private static let v1Modules = [
        "m0_structure", "m1_talent", "m2_high_low", "m3_system",
        "m4_health", "m5_wealth", "m6_dynamics", "m7_manual",
    ]

    /// V1 模块(M0-M7)缓存契约 = 完整 JSON 对象(2026-10-01 起读取层自愈按此校验,
    /// 散文 fixture 会被当中毒行清除,故测试一律用合法 JSON)。
    private static func v1JSON(_ text: String) -> String {
        "{\"structure_fingerprint\": \"\(text)\"}"
    }

    // 8. readAll:identity 只 resolve 一次(healthResults 只给 1 个,
    //    第 2 次 health 即抛 unexpectedCall——health 成功本身就是断言)
    func testReadAllResolvesIdentityOnceForAllModules() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        for module in Self.v1Modules {
            try store.upsert(
                contentHash: "h", module: module, promptVersion: 1, targetDate: nil,
                provider: "anthropic", model: "claude-test",
                interpretation: Self.v1JSON("text-\(module)"), generatedAt: .now
            )
        }
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: Self.healthOnlyClient()),
            cacheStore: store
        )
        let hits = try await reader.readAll(
            contentHash: "h", modules: Self.v1Modules, language: "zh"
        )
        XCTAssertEqual(hits.count, 8, "捌章全命中;若 identity resolve 了第二次会先抛 unexpectedCall")
        XCTAssertEqual(hits["m0_structure"]?.interpretation, Self.v1JSON("text-m0_structure"))
        XCTAssertEqual(hits["m7_manual"]?.promptVersion, 1)
    }

    // 9. readAll:miss 不进结果字典(调用方以缺键判 miss)
    func testReadAllReturnsOnlyHitModules() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        try store.upsert(
            contentHash: "h", module: "m0_structure", promptVersion: 1, targetDate: nil,
            provider: "anthropic", model: "claude-test",
            interpretation: Self.v1JSON("m0 text"), generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: Self.healthOnlyClient()),
            cacheStore: store
        )
        let hits = try await reader.readAll(
            contentHash: "h", modules: Self.v1Modules, language: "zh"
        )
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits["m0_structure"]?.interpretation, Self.v1JSON("m0 text"))
        XCTAssertNil(hits["m1_talent"], "miss 章不得以 nil 值占字典键")
    }

    // 10. readAll:health 失败 → 整体 throw(不静默半填)
    func testReadAllThrowsWhenHealthFails() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: ReaderTestAPIClient(healthResults: [.failure(.healthUnavailable)])),
            cacheStore: store
        )
        do {
            _ = try await reader.readAll(contentHash: "h", modules: Self.v1Modules, language: "zh")
            XCTFail("health 失败应整体向上抛,不静默返回空字典")
        } catch let error as ReaderTestError {
            XCTAssertEqual(error, .healthUnavailable)
        }
    }

    // MARK: - V1 模块中毒缓存自愈(2026-10-01,镜像后端坏 JSON 自愈)

    /// 09-27 真机事故形态:LLM 输出在 max_tokens 截断的半截 JSON
    /// (原行结尾停在 `"looks_like": "To outsiders`)
    private static let truncatedV1JSON = """
    {
      "innate": {
        "behavior": "快速建立对外界的判断",
        "trained_by": "长期复盘",
        "looks_like": "To outsiders
    """

    private static let testIdentity = AIIdentity(provider: "anthropic", model: "claude-test")

    // 11. readAll:中毒 m1 行(截断半截 JSON)→ 不进 hits 且行被删
    func testReadAllPurgesPoisonedV1Row() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        try store.upsert(
            contentHash: "h", module: "m1_talent", promptVersion: 1, targetDate: nil,
            provider: "anthropic", model: "claude-test",
            interpretation: Self.truncatedV1JSON, generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: Self.healthOnlyClient()),
            cacheStore: store
        )
        let hits = try await reader.readAll(contentHash: "h", modules: ["m1_talent"], language: "zh")
        XCTAssertNil(hits["m1_talent"], "中毒行不得命中(应删行当 miss,触发上层重新生成)")
        // 行确实被删(不是仅当次跳过):绕过 reader 直查 store 应 miss
        let after = try store.getLatest(
            contentHash: "h", module: "m1_talent", targetDate: nil,
            language: "zh", identity: Self.testIdentity
        )
        XCTAssertNil(after, "中毒行应已从 SwiftData 删除")
    }

    // 12. readAll:顶层无可渲染值(全 null)同样清除——镜像后端 _is_renderable_top_level
    func testReadAllPurgesUnrenderableTopLevelV1Row() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        try store.upsert(
            contentHash: "h", module: "m2_high_low", promptVersion: 1, targetDate: nil,
            provider: "anthropic", model: "claude-test",
            interpretation: "{ \"high_config\": null }", generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: Self.healthOnlyClient()),
            cacheStore: store
        )
        let hits = try await reader.readAll(contentHash: "h", modules: ["m2_high_low"], language: "zh")
        XCTAssertNil(hits["m2_high_low"], "全 null 顶层在渲染层 nodes.isEmpty → nil,同属中毒行")
        let after = try store.getLatest(
            contentHash: "h", module: "m2_high_low", targetDate: nil,
            language: "zh", identity: Self.testIdentity
        )
        XCTAssertNil(after)
    }

    // 13. read(单读路径)同样自愈:V1 中毒行 → nil + 删行
    func testReadPurgesPoisonedV1Row() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        try store.upsert(
            contentHash: "h", module: "m1_talent", promptVersion: 1, targetDate: nil,
            provider: "anthropic", model: "claude-test",
            interpretation: Self.truncatedV1JSON, generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: Self.healthOnlyClient()),
            cacheStore: store
        )
        let cache = try await reader.read(contentHash: "h", module: "m1_talent")
        XCTAssertNil(cache, "单读路径对 V1 中毒行同样返回 nil")
        let after = try store.getLatest(
            contentHash: "h", module: "m1_talent", targetDate: nil,
            language: "zh", identity: Self.testIdentity
        )
        XCTAssertNil(after)
    }

    // 14. 护栏:合盘/每日的散文契约行不受自愈波及(module ∉ ModuleID 不校验)
    func testProseRowsForNonV1ModulesAreNotPurged() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        try store.upsert(
            contentHash: "h", module: "compatibility", promptVersion: 1, targetDate: nil,
            provider: "anthropic", model: "claude-test",
            interpretation: "两人整体节奏:一段散文解读,不是 JSON。", generatedAt: .now
        )
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsert(
            contentHash: "h", module: "daily_fortune", promptVersion: 1, targetDate: date,
            provider: "anthropic", model: "claude-test",
            interpretation: "今日运势:宜沉稳。", generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: ReaderTestAPIClient(healthResults: [
                .success(Self.health(provider: "anthropic", model: "claude-test")),
                .success(Self.health(provider: "anthropic", model: "claude-test")),
            ])),
            cacheStore: store
        )
        let compat = try await reader.read(contentHash: "h", module: "compatibility", maxAge: 24 * 3600)
        XCTAssertEqual(compat?.interpretation, "两人整体节奏:一段散文解读,不是 JSON。")
        let daily = try await reader.read(contentHash: "h", module: "daily_fortune", targetDate: date, maxAge: 24 * 3600)
        XCTAssertEqual(daily?.interpretation, "今日运势:宜沉稳。")
        // 两行仍在库(散文对非 V1 module 是合法内容,不得误删)
        let compatAfter = try store.getLatest(
            contentHash: "h", module: "compatibility", targetDate: nil,
            language: "zh", identity: Self.testIdentity
        )
        let dailyAfter = try store.getLatest(
            contentHash: "h", module: "daily_fortune", targetDate: date,
            language: "zh", identity: Self.testIdentity
        )
        XCTAssertNotNil(compatAfter, "合盘散文行不得被自愈误删")
        XCTAssertNotNil(dailyAfter, "每日散文行不得被自愈误删")
    }

    // 15. #8(2026-10-02):readAllCrossLanguage 的 identity 只 resolve 一次。
    // ReaderTestAPIClient 的 healthResults 用尽即抛 unexpectedCall——只备
    // 1 次应答,多 resolve 一次本测试直接失败(修复前逐语言调 readAll,
    // zh + en 两次 resolve)。
    func testReadAllCrossLanguageResolvesIdentityOnce() async throws {
        // 生效语言锁定 zh-hant(注入启动快照,L1/F2 口径),zh 行才能当「其它语言」
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
            UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        }
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        try store.upsert(
            contentHash: "h8", module: "compatibility_free", promptVersion: 1,
            targetDate: nil, language: "zh",
            provider: "anthropic", model: "claude-test",
            interpretation: "第一章 基础相处模式", generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            // 只备 1 次 health:第二次 resolve → unexpectedCall 抛错 → 测试失败
            identityResolver: AIIdentityResolver(apiClient: ReaderTestAPIClient(healthResults: [
                .success(Self.health(provider: "anthropic", model: "claude-test")),
            ])),
            cacheStore: store
        )
        let result = try await reader.readAllCrossLanguage(
            contentHash: "h8", modules: ["compatibility_free"]
        )
        XCTAssertEqual(result?.language, "zh", "zh 行命中(en 无行,不额外 resolve)")
        XCTAssertEqual(result?.hits["compatibility_free"]?.interpretation, "第一章 基础相处模式")
    }

    // 16. #8:rowIsValid 过滤——坏行不参与候选,继续尝试其它语言。
    // zh 行是 daily v3 散文(不过五段契约),en 行合法;修复前只看「最优
    // 语言」(zh 与 en 各 1 行并列,allCases 序 zh 在前)→ 返回 zh 坏行,
    // 调用方判无源;修复后 zh 被过滤,en 胜出。
    func testReadAllCrossLanguageRowIsValidSkipsBadRowAndTriesNextLanguage() async throws {
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
            UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        }
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        let date = Date(timeIntervalSince1970: 1_783_000_000)
        try store.upsert(
            contentHash: "h9", module: "daily_fortune", promptVersion: 3,
            targetDate: date, language: "zh",
            provider: "anthropic", model: "claude-test",
            interpretation: "流日与你的日主同根同气,是自立自守的一天。", generatedAt: .now
        )
        try store.upsert(
            contentHash: "h9", module: "daily_fortune", promptVersion: 4,
            targetDate: date, language: "en",
            provider: "anthropic", model: "claude-test",
            interpretation: "{\"headline\":\"Calm start\",\"work\":\"Do the essential.\",\"relationships\":\"Hold back words.\",\"energy\":\"Your own pace.\",\"reminder\":\"Stay measured.\"}",
            generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: ReaderTestAPIClient(healthResults: [
                .success(Self.health(provider: "anthropic", model: "claude-test")),
            ])),
            cacheStore: store
        )
        let result = try await reader.readAllCrossLanguage(
            contentHash: "h9", modules: ["daily_fortune"], targetDate: date,
            maxAge: 24 * 3600,
            rowIsValid: { DailyInsight.parse($0.interpretation) != nil }
        )
        XCTAssertEqual(result?.language, "en", "zh 坏行被过滤后必须落到 en(而非返回坏行/nil)")
        // zh 坏行保留在库(过滤只影响候选,不删行——同语言读路径有自己的嗅探)
        let zhRow = try store.getLatest(
            contentHash: "h9", module: "daily_fortune", targetDate: date,
            language: "zh", identity: Self.testIdentity
        )
        XCTAssertNotNil(zhRow, "rowIsValid 过滤不得删行")
    }

    // 17. Bug4(2026-10-06 review 核实):命中数平手时按行内 promptVersion 高者
    // 胜出。daily 单模块下两语言命中数恒 1,修复前 allCases 序让 zh(v1 旧版源)
    // 压过 en(v4 有效源)→ 旧版源翻译必 409 STALE_SOURCE 落穿重生成,本可翻译
    // (保「换语言结论不变」)的有效源被掩蔽,切语言内容漂移。
    func testReadAllCrossLanguageTieBreaksByHigherPromptVersion() async throws {
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
            UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        }
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        let date = Date(timeIntervalSince1970: 1_783_000_000)
        // 两行都过 v4 五段契约(rowIsValid 双真),只有版本差:zh 旧版 / en 新版
        try store.upsert(
            contentHash: "h10", module: "daily_fortune", promptVersion: 1,
            targetDate: date, language: "zh",
            provider: "anthropic", model: "claude-test",
            interpretation: "{\"headline\":\"稳开场\",\"work\":\"做要事\",\"relationships\":\"少言\",\"energy\":\"按自己的节奏\",\"reminder\":\"保持克制\"}",
            generatedAt: .now
        )
        try store.upsert(
            contentHash: "h10", module: "daily_fortune", promptVersion: 4,
            targetDate: date, language: "en",
            provider: "anthropic", model: "claude-test",
            interpretation: "{\"headline\":\"Calm start\",\"work\":\"Do the essential.\",\"relationships\":\"Hold back words.\",\"energy\":\"Your own pace.\",\"reminder\":\"Stay measured.\"}",
            generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: ReaderTestAPIClient(healthResults: [
                .success(Self.health(provider: "anthropic", model: "claude-test")),
            ])),
            cacheStore: store
        )
        let result = try await reader.readAllCrossLanguage(
            contentHash: "h10", modules: ["daily_fortune"], targetDate: date,
            maxAge: 24 * 3600,
            rowIsValid: { DailyInsight.parse($0.interpretation) != nil }
        )
        XCTAssertEqual(
            result?.language, "en",
            "命中数平手时高 promptVersion 源必须胜出(修复前按 allCases 序取 zh 旧版源,翻译必 409)"
        )
        XCTAssertEqual(result?.hits["daily_fortune"]?.promptVersion, 4)
    }

    // 18. Bug4 同款·模块优先版(2026-10-07 第五轮 review 补):合盘选源走
    // readCrossLanguageByModulePriority,修复前同 module 多语言命中时先命中
    // 先返回(allCases 序 zh 在前),zh 旧版源(v1)压过 en 有效源(v4)→
    // 翻译必 409 STALE_SOURCE 落穿重生成,切语言内容漂移——与 test 17 同根,
    // 但路径独立,须分别锁。
    func testReadCrossLanguageByModulePriorityPrefersHigherPromptVersion() async throws {
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
            UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        }
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        // 合盘双键场景:zh 旧版 / en 新版,同 module 命中数平手
        try store.upsert(
            contentHash: "h11", module: "compatibility_paid", promptVersion: 1,
            targetDate: nil, language: "zh",
            provider: "anthropic", model: "claude-test",
            interpretation: "整体合拍(旧版源)。", generatedAt: .now
        )
        try store.upsert(
            contentHash: "h11", module: "compatibility_paid", promptVersion: 4,
            targetDate: nil, language: "en",
            provider: "anthropic", model: "claude-test",
            interpretation: "Solid match overall (valid source).", generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: ReaderTestAPIClient(healthResults: [
                .success(Self.health(provider: "anthropic", model: "claude-test")),
            ])),
            cacheStore: store
        )
        let result = try await reader.readCrossLanguageByModulePriority(
            contentHash: "h11",
            modules: ["compatibility_paid", "compatibility_free"],
            maxAge: 24 * 3600
        )
        XCTAssertEqual(result?.module, "compatibility_paid")
        XCTAssertEqual(
            result?.language, "en",
            "同 module 多语言命中时高 promptVersion 源必须胜出(修复前先命中先返回取 zh 旧版源)"
        )
        XCTAssertEqual(result?.row.promptVersion, 4)
    }

    // 19. 版本平手时保语言序(allCases 确定性):zh 与 en 同版本 → 取先到的
    // zh,不因遍历顺序漂移。
    func testReadCrossLanguageByModulePriorityTieKeepsLanguageOrder() async throws {
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
            UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        }
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        try store.upsert(
            contentHash: "h12", module: "compatibility_paid", promptVersion: 4,
            targetDate: nil, language: "zh",
            provider: "anthropic", model: "claude-test",
            interpretation: "整体合拍(平手 zh)。", generatedAt: .now
        )
        try store.upsert(
            contentHash: "h12", module: "compatibility_paid", promptVersion: 4,
            targetDate: nil, language: "en",
            provider: "anthropic", model: "claude-test",
            interpretation: "Solid match (tie en).", generatedAt: .now
        )
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: ReaderTestAPIClient(healthResults: [
                .success(Self.health(provider: "anthropic", model: "claude-test")),
            ])),
            cacheStore: store
        )
        let result = try await reader.readCrossLanguageByModulePriority(
            contentHash: "h12",
            modules: ["compatibility_paid"],
            maxAge: 24 * 3600
        )
        XCTAssertEqual(result?.language, "zh", "版本平手时保 allCases 语言序(确定性)")
    }

    // MARK: - 服务端 prompt 版本过滤(2026-10-08 外评 #4)

    /// health 携带各模块服务端当前 prompt 版本 → 本地行**只认该版本**:
    /// prompt bump 后 24h 内的旧版行不再命中(否则旧解读照常展示并被写进
    /// 新合盘快照,bump 在客户端失防);版本未知(老后端无字段)维持旧行为。
    func testReadOnlyTrustsServerPromptVersion() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        // 同盘同模块:v4(旧)+ v5(服务端当前)两行
        try store.upsert(
            contentHash: "h-pv", module: "compatibility_paid", promptVersion: 4,
            targetDate: nil, provider: "anthropic", model: "claude-test",
            interpretation: "v4 旧解读", generatedAt: .now
        )
        try store.upsert(
            contentHash: "h-pv", module: "compatibility_paid", promptVersion: 5,
            targetDate: nil, provider: "anthropic", model: "claude-test",
            interpretation: "v5 新解读", generatedAt: .now
        )

        func readerWith(versions: [String: Int]?) -> CachedInterpretationReader {
            var health = Self.health(provider: "anthropic", model: "claude-test")
            health.promptVersions = versions
            return CachedInterpretationReader(
                identityResolver: AIIdentityResolver(apiClient:
                    ReaderTestAPIClient(healthResults: [.success(health)])),
                cacheStore: store
            )
        }

        // 服务端声明当前 v5:只命中 v5 行(v4 旧版行被版本过滤排除)
        let hitCurrent = try await readerWith(versions: ["compatibility_paid": 5])
            .read(contentHash: "h-pv", module: "compatibility_paid")
        XCTAssertEqual(hitCurrent?.interpretation, "v5 新解读")

        // 服务端声明 v5 而本地只有更旧 v4 时也应 miss(用独立 store 验证,
        // 避免与上行 v5 行同盘):此处直接复用同盘——v5 行在,miss 断言用
        // 声明 v6(本地无 v6 行,最高版 v5 也不得放行「取本地最高」旧行为)
        let missBelowServer = try await readerWith(versions: ["compatibility_paid": 6])
            .read(contentHash: "h-pv", module: "compatibility_paid")
        XCTAssertNil(missBelowServer, "本地最高版本低于服务端当前版本时必须 miss(不得回落取本地最高)")

        // 版本未知(老后端无 prompt_versions)→ 维持旧行为:取本地最高版行
        let legacyHit = try await readerWith(versions: nil)
            .read(contentHash: "h-pv", module: "compatibility_paid")
        XCTAssertEqual(legacyHit?.interpretation, "v5 新解读")
    }

    // MARK: - v1 链一致守卫(2026-10-08 第十五轮 #7;第十六轮外评 #2 依赖判据)

    /// 上游(如 M0)单侧 bump 后,本地缓存键不含上游指纹、getLatest 只按
    /// **本模块**版本过滤——下游旧版本行照常命中会拼出「新旧混合链」
    /// (命书混拼 + 这些章翻译恒 409,服务端链走查按新上游重建键)。
    /// 守卫(依赖判据):v1 链中任一模块「服务端版本已知且本地无当前版本
    /// 行」→ 仅**依赖它的下游**(`ModuleID.dependencies`)跳过回填;
    /// 版本未知(老后端)守卫关闭。`migrationRegenModules` = 被跳过/缺行
    /// 且本地有任意版本行的章(版本迁移重生成,调用方豁免本地次数)。
    func testReadAllCutsV1ChainWhenUpstreamVersionMissing() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        // m0 本地只有 v1 行(服务端已 bump 到 v2);m1/m2 本地 v1 = 服务端当前
        // ——下游行是旧 M0 驱动的,版本过滤单独看每章都「有效」
        try store.upsert(
            contentHash: "h-cut", module: "m0_structure", promptVersion: 1,
            targetDate: nil, provider: "anthropic", model: "claude-test",
            interpretation: Self.v1JSON("m0 旧版"), generatedAt: .now
        )
        try store.upsert(
            contentHash: "h-cut", module: "m1_talent", promptVersion: 1,
            targetDate: nil, provider: "anthropic", model: "claude-test",
            interpretation: Self.v1JSON("m1 旧 M0 驱动"), generatedAt: .now
        )
        try store.upsert(
            contentHash: "h-cut", module: "m2_high_low", promptVersion: 1,
            targetDate: nil, provider: "anthropic", model: "claude-test",
            interpretation: Self.v1JSON("m2 旧 M0 驱动"), generatedAt: .now
        )

        func readerWith(versions: [String: Int]?) -> CachedInterpretationReader {
            var health = Self.health(provider: "anthropic", model: "claude-test")
            health.promptVersions = versions
            return CachedInterpretationReader(
                identityResolver: AIIdentityResolver(apiClient:
                    ReaderTestAPIClient(healthResults: [.success(health)])),
                cacheStore: store
            )
        }
        let chain = Array(Self.v1Modules.prefix(3))  // m0 → m1 → m2

        // 1. m0 服务端 v2 已知、本地无 v2 行 → m0 缺行(m1/m2 依赖它)全部
        //    跳过回填(修复前:m1/m2 命中 → 新旧混拼 + 这些章翻译恒 409);
        //    三章本地都有任意版本行 → 全进版本迁移重生成集(重算豁免本地次数)
        let cut = try await readerWith(versions: [
            "m0_structure": 2, "m1_talent": 1, "m2_high_low": 1,
        ]).readAllForRestore(contentHash: "h-cut", modules: chain, language: "zh")
        XCTAssertTrue(cut.hits.isEmpty, "上游版本缺行须切断依赖它的回填(实际:\(cut.hits.keys.sorted()))")
        XCTAssertEqual(
            cut.migrationRegenModules,
            ["m0_structure", "m1_talent", "m2_high_low"],
            "三章均为版本迁移重生成(本地有旧版行),重算须豁免本地次数"
        )

        // 2. 版本未知(老后端无 prompt_versions)→ 守卫与迁移集都关闭,
        //    维持旧行为:全部行照常命中(m0 旧行按旧语义取本地最高,不触发切断)
        let legacy = try await readerWith(versions: nil)
            .readAllForRestore(contentHash: "h-cut", modules: chain, language: "zh")
        XCTAssertEqual(legacy.hits.count, 3)
        XCTAssertNotNil(legacy.hits["m0_structure"])
        XCTAssertNotNil(legacy.hits["m1_talent"])
        XCTAssertNotNil(legacy.hits["m2_high_low"])
        XCTAssertTrue(legacy.migrationRegenModules.isEmpty, "老后端版本未知,不判迁移")

        // 3. 对照:全模块版本对齐(服务端 v1 = 本地 v1)→ 全命中,守卫不误伤,
        //    迁移集为空(重算才计费)
        let allCurrent = try await readerWith(versions: [
            "m0_structure": 1, "m1_talent": 1, "m2_high_low": 1,
        ]).readAllForRestore(contentHash: "h-cut", modules: chain, language: "zh")
        XCTAssertEqual(allCurrent.hits.count, 3)
        XCTAssertTrue(allCurrent.migrationRegenModules.isEmpty)

        // 4. 部分清单(同会话重挂:M0 已 .ok 不进回填清单,modules 从 m1
        //    起头)守卫仍须生效:m1 服务端已 bump v2、本地无 v2 行 → m1
        //    缺行、m2(依赖 m1)跳过(修复前 first != m0 → 守卫关闭 → m2
        //    旧行照常回填 = #7 混拼的同会话残余面,重启全量清单才自愈)
        let partial = try await readerWith(versions: [
            "m0_structure": 1, "m1_talent": 2, "m2_high_low": 1,
        ]).readAllForRestore(
            contentHash: "h-cut", modules: Array(chain.dropFirst()), language: "zh"
        )
        XCTAssertTrue(partial.hits.isEmpty, "部分清单守卫:上游版本缺行须切断依赖它的回填(实际:\(partial.hits.keys.sorted()))")
        XCTAssertEqual(partial.migrationRegenModules, ["m1_talent", "m2_high_low"])

        // 5. 首次生成(本地无任何行)不进迁移集:照常计费——迁移豁免只盖
        //    「有旧行被版本 bump 作废」的章,不白送新章
        let fresh = try await readerWith(versions: [
            "m0_structure": 2, "m1_talent": 1, "m2_high_low": 1,
        ]).readAllForRestore(
            contentHash: "h-fresh-cut", modules: chain, language: "zh"
        )
        XCTAssertTrue(fresh.hits.isEmpty)
        XCTAssertTrue(fresh.migrationRegenModules.isEmpty, "无任何本地行 = 首次生成,不豁免")
    }

    /// 依赖判据精度(第十六轮外评 #2):缺行章只切断**真正依赖它**的下游,
    /// 不再按列表序一刀切。M4 不在任何模块的 dependencies 里 → M4 缺行时
    /// M5/M6/M7 照常回填(旧「前缀切断」会误伤三章:离线不可读/跨语言不可译);
    /// M2 缺行只断 M6/M7(依赖 M2),M3/M4/M5 不受影响。
    func testReadAllDepsGuardOnlyCutsDependents() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        for module in Self.v1Modules {
            try store.upsert(
                contentHash: "h-deps", module: module, promptVersion: 1,
                targetDate: nil, provider: "anthropic", model: "claude-test",
                interpretation: Self.v1JSON("text-\(module)"), generatedAt: .now
            )
        }

        var healthM4Bumped = Self.health(provider: "anthropic", model: "claude-test")
        healthM4Bumped.promptVersions = [
            "m0_structure": 1, "m1_talent": 1, "m2_high_low": 1, "m3_system": 1,
            "m4_health": 2, "m5_wealth": 1, "m6_dynamics": 1, "m7_manual": 1,
        ]
        let m4Bumped = try await CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient:
                ReaderTestAPIClient(healthResults: [.success(healthM4Bumped)])),
            cacheStore: store
        ).readAllForRestore(contentHash: "h-deps", modules: Self.v1Modules, language: "zh")
        // M4 缺行,但 M5(deps m0/m1/m3)/M6(m0/m1/m2)/M7(m1/m2/m3/m6)都不依赖 M4
        XCTAssertEqual(
            Set(m4Bumped.hits.keys), Set(Self.v1Modules.filter { $0 != "m4_health" }),
            "M4 缺行只影响 M4 自己;M5/M6/M7 不依赖 M4,照常回填(旧前缀切断会误伤)"
        )
        XCTAssertEqual(m4Bumped.migrationRegenModules, ["m4_health"])

        var healthM2Bumped = Self.health(provider: "anthropic", model: "claude-test")
        healthM2Bumped.promptVersions = [
            "m0_structure": 1, "m1_talent": 1, "m2_high_low": 2, "m3_system": 1,
            "m4_health": 1, "m5_wealth": 1, "m6_dynamics": 1, "m7_manual": 1,
        ]
        let m2Bumped = try await CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient:
                ReaderTestAPIClient(healthResults: [.success(healthM2Bumped)])),
            cacheStore: store
        ).readAllForRestore(contentHash: "h-deps", modules: Self.v1Modules, language: "zh")
        // M2 缺行:依赖 M2 的 M6、依赖 M6/M2 的 M7 被切断;M3(deps m0)/
        // M4(deps m0)/M5(deps m0/m1/m3)不受影响
        XCTAssertEqual(
            Set(m2Bumped.hits.keys),
            ["m0_structure", "m1_talent", "m3_system", "m4_health", "m5_wealth"],
            "M2 缺行只切断依赖它的 M6/M7;M3/M4/M5 照常回填"
        )
        XCTAssertEqual(
            m2Bumped.migrationRegenModules,
            ["m2_high_low", "m6_dynamics", "m7_manual"],
            "缺行的 M2 与血统过期的 M6/M7 均为版本迁移重生成"
        )

        // M0 bump(版本迁移旗舰场景,附七 #1):M7 的声明依赖不含 M0
        //    (m7 模板不读 chart),但其 parent_fingerprint 恒取自 M0(后端
        //    `_V1_SOURCE_WALK_DEPS["m7_manual"]` 含 m0)——守卫按**血统依赖**
        //    判定时 M7 必须一并切断,否则旧血统 m7 行回填 = 命书混拼在 m7
        //    单点复活(且 m7 不进迁移集,重算不豁免)
        var healthM0Bumped = Self.health(provider: "anthropic", model: "claude-test")
        healthM0Bumped.promptVersions = [
            "m0_structure": 2, "m1_talent": 1, "m2_high_low": 1, "m3_system": 1,
            "m4_health": 1, "m5_wealth": 1, "m6_dynamics": 1, "m7_manual": 1,
        ]
        let m0Bumped = try await CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient:
                ReaderTestAPIClient(healthResults: [.success(healthM0Bumped)])),
            cacheStore: store
        ).readAllForRestore(contentHash: "h-deps", modules: Self.v1Modules, language: "zh")
        XCTAssertTrue(m0Bumped.hits.isEmpty, "M0 缺行切断全链(含声明依赖不含 M0 的 M7)")
        XCTAssertEqual(
            m0Bumped.migrationRegenModules,
            Set(Self.v1Modules),
            "八章本地都有旧版行,全部为版本迁移重生成(M7 含在内,重算豁免本地次数)"
        )
    }

    /// 依赖图切断·十六轮 houduan #1 场景(撞车消解移植,断言经
    /// transitiveDependents 机制复核等价):①M4 从未生成(无行)不得切断
    /// 任何章(修复前前缀切断:M5-M7 被误跳过)→ 也不进迁移集(无行);
    /// ②M1 版本落后只切断传递依赖方 m2/m5/m6/m7,m3/m4 独立于 M1 照常回填。
    func testReadAllCutIsDependencyScopedNotPrefix() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)

        func reader(versions: [String: Int]) -> CachedInterpretationReader {
            var health = Self.health(provider: "anthropic", model: "claude-test")
            health.promptVersions = versions
            return CachedInterpretationReader(
                identityResolver: AIIdentityResolver(apiClient:
                    ReaderTestAPIClient(healthResults: [.success(health)])),
                cacheStore: store
            )
        }
        func seed(_ hash: String, _ module: String) throws {
            try store.upsert(
                contentHash: hash, module: module, promptVersion: 1,
                targetDate: nil, provider: "anthropic", model: "claude-test",
                interpretation: Self.v1JSON("\(module) 原文"), generatedAt: .now
            )
        }

        // 场景 1:M4 从未生成(无行,服务端版本已知),其余七章 v1 行在、
        // 版本对齐 → m4 miss 不切断任何章(无模块依赖 M4),M5-M7 照常回填;
        // m4 无任何版本行 → 不进版本迁移重生成集(首次生成照常计费)
        let h1 = "h-dep-cut-m4"
        for module in Self.v1Modules where module != "m4_health" {
            try seed(h1, module)
        }
        let m4Missing = try await reader(versions: [
            "m0_structure": 1, "m1_talent": 1, "m2_high_low": 1, "m3_system": 1,
            "m4_health": 1, "m5_wealth": 1, "m6_dynamics": 1, "m7_manual": 1,
        ]).readAllForRestore(contentHash: h1, modules: Self.v1Modules, language: "zh")
        XCTAssertEqual(
            Set(m4Missing.hits.keys),
            Set(Self.v1Modules).subtracting(["m4_health"]),
            "M4 从未生成不得切断任何章(修复前前缀切断:M5-M7 被误跳过),实际命中:\(m4Missing.hits.keys.sorted())"
        )
        XCTAssertTrue(
            m4Missing.migrationRegenModules.isEmpty,
            "M4 无任何版本行 = 首次生成,不豁免;其余章版本对齐不迁移"
        )

        // 场景 2:M1 版本落后(服务端 v2,本地 v1 行被版本过滤)→ 只切断
        // 传递依赖方 m2/m5/m6/m7;不依赖 M1 的 m0/m3/m4 照常回填。
        // m2/m5/m6/m7 本地有行 → 全进迁移集;m1 有 v1 行也在集内
        let h2 = "h-dep-cut-m1"
        for module in Self.v1Modules {
            try seed(h2, module)
        }
        let m1Stale = try await reader(versions: [
            "m0_structure": 1, "m1_talent": 2, "m2_high_low": 1, "m3_system": 1,
            "m4_health": 1, "m5_wealth": 1, "m6_dynamics": 1, "m7_manual": 1,
        ]).readAllForRestore(contentHash: h2, modules: Self.v1Modules, language: "zh")
        XCTAssertEqual(
            Set(m1Stale.hits.keys),
            ["m0_structure", "m3_system", "m4_health"],
            "M1 miss 只切断依赖方(m2/m5/m6/m7),m3/m4 独立于 M1 须回填(实际:\(m1Stale.hits.keys.sorted()))"
        )
        XCTAssertEqual(
            m1Stale.migrationRegenModules,
            ["m1_talent", "m2_high_low", "m5_wealth", "m6_dynamics", "m7_manual"],
            "缺行的 M1 与血统过期的四个依赖方均为版本迁移重生成"
        )
    }

    /// 清单外血统上游缺行(十七轮 #3):M0 处于不可回填态(.dailyLimitReached
    /// 等)不进恢复清单,但「不在清单」≠「有当前版本行」——守卫只看清单内
    /// 模块时,M0 升版重生成 429 达限后重进页面,M1-M7 旧行会被恢复成旧链
    /// (混拼 + 翻译 409)。修复:对「清单内模块的依赖 ∪ {m0} − 清单」逐一
    /// 查行,缺行则其传递依赖方同款切断;缺行的清单外上游自身(M0)有任意
    /// 版本行也进迁移集(同会话跨 UTC 零点恢复时其重跑免计费)。
    /// 跨语言探测模式下该检查放行旧版行(旧版源正是可翻译的探测源,
    /// 附三 #5 口径)——不因 M0 无当前版本行而切断探测。
    func testReadAllForRestoreCutsWhenUpstreamOutsideListMissesCurrentRow() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        // M0 本地只有 v1 行(服务端 v2);M1-M7 本地 v1 = 服务端当前
        try store.upsert(
            contentHash: "h-ext", module: "m0_structure", promptVersion: 1,
            targetDate: nil, provider: "anthropic", model: "claude-test",
            interpretation: Self.v1JSON("m0 旧版"), generatedAt: .now
        )
        for module in Self.v1Modules.dropFirst() {
            try store.upsert(
                contentHash: "h-ext", module: module, promptVersion: 1,
                targetDate: nil, provider: "anthropic", model: "claude-test",
                interpretation: Self.v1JSON("text-\(module)"), generatedAt: .now
            )
        }

        var health = Self.health(provider: "anthropic", model: "claude-test")
        health.promptVersions = [
            "m0_structure": 2, "m1_talent": 1, "m2_high_low": 1, "m3_system": 1,
            "m4_health": 1, "m5_wealth": 1, "m6_dynamics": 1, "m7_manual": 1,
        ]
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient:
                ReaderTestAPIClient(healthResults: [.success(health)])),
            cacheStore: store
        )

        // 1. 回填模式:清单 = [m1..m7](M0 不在——如处于 .dailyLimitReached)。
        //    M0 无当前版本行 → 全链切断,hits 空;八章全进迁移集
        //    (M0 经清单外检查补入,M1-M7 经切断路径)
        let partial = try await reader.readAllForRestore(
            contentHash: "h-ext",
            modules: Array(Self.v1Modules.dropFirst()), language: "zh"
        )
        XCTAssertTrue(partial.hits.isEmpty, "清单外 M0 缺当前版本行须切断全链(实际:\(partial.hits.keys.sorted()))")
        XCTAssertEqual(
            partial.migrationRegenModules, Set(Self.v1Modules),
            "M0(清单外检查补入)与 M1-M7(切断路径)均为版本迁移重生成"
        )

        // 2. 跨语言探测模式:M0 有任意版本行(旧版源可翻译)→ 不切断,
        //    zh 行照常作为探测源命中(不因外部检查误伤翻译降级路径)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
            UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        }
        let reader2 = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient:
                ReaderTestAPIClient(healthResults: [.success(health)])),
            cacheStore: store
        )
        let crossLang = try await reader2.readAllCrossLanguage(
            contentHash: "h-ext", modules: Array(Self.v1Modules.dropFirst())
        )
        XCTAssertEqual(crossLang?.language, "zh", "跨语言探测:M0 旧版行放行,zh 源照常可探测(切断仅回填模式)")
        XCTAssertEqual(crossLang?.hits.count, 7)
    }

    // MARK: - Helpers

    private static func healthOnlyClient(
        provider: String = "anthropic",
        model: String = "claude-test"
    ) -> ReaderTestAPIClient {
        ReaderTestAPIClient(healthResults: [.success(health(provider: provider, model: model))])
    }

    private static func health(provider: String, model: String) -> HealthResponse {
        HealthResponse(
            status: "ok",
            lunarPythonVersion: "1.4.8",
            model: "bazi-calculate-v1",
            aiProvider: provider,
            aiModel: model
        )
    }
}

// MARK: - Test Doubles

private enum ReaderTestError: Error, Equatable {
    case healthUnavailable
    case unexpectedCall
}

private actor ReaderTestAPIClient: APIClient {
    private var healthResults: [Result<HealthResponse, ReaderTestError>]

    init(healthResults: [Result<HealthResponse, ReaderTestError>]) {
        self.healthResults = healthResults
    }

    func health() async throws -> HealthResponse {
        guard !healthResults.isEmpty else { throw ReaderTestError.unexpectedCall }
        return try healthResults.removeFirst().get()
    }

    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        throw ReaderTestError.unexpectedCall
    }
    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse {
        throw ReaderTestError.unexpectedCall
    }
    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse {
        throw ReaderTestError.unexpectedCall
    }
    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        throw ReaderTestError.unexpectedCall
    }
    func redeem(request: EntitlementRedeemRequest) async throws -> EntitlementRedeemResponse {
        throw ReaderTestError.unexpectedCall
    }
    func entitlementList() async throws -> EntitlementListResponse {
        throw ReaderTestError.unexpectedCall
    }
    func signIn(request: SignInRequest) async throws -> SignInResponse {
        throw ReaderTestError.unexpectedCall
    }
    func syncPull() async throws -> SyncPullResponse {
        throw ReaderTestError.unexpectedCall
    }
    func syncPush(request: SyncPushRequest) async throws -> SyncPushResponse {
        throw ReaderTestError.unexpectedCall
    }
}
