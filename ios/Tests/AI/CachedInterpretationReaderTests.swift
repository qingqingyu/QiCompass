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
