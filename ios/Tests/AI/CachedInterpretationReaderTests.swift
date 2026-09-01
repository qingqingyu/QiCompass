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
