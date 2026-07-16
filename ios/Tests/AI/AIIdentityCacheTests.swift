import SwiftData
import XCTest
@testable import QiCompass

@MainActor
final class AIIdentityCacheTests: XCTestCase {
    func testProviderAndModelArePartOfLocalCacheIdentity() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let store = InterpretationCacheStore(context: container.mainContext)
        let generatedAt = Date()

        try store.upsert(
            contentHash: "same-hash",
            module: "bazi_deep",
            promptVersion: 1,
            targetDate: nil,
            provider: "anthropic",
            model: "claude-test",
            interpretation: "anthropic text",
            generatedAt: generatedAt
        )

        let anthropic = try store.getLatest(
            contentHash: "same-hash",
            module: "bazi_deep",
            targetDate: nil,
            identity: AIIdentity(provider: "anthropic", model: "claude-test")
        )
        let openAI = try store.getLatest(
            contentHash: "same-hash",
            module: "bazi_deep",
            targetDate: nil,
            identity: AIIdentity(provider: "openai", model: "gpt-test")
        )
        let otherModel = try store.getLatest(
            contentHash: "same-hash",
            module: "bazi_deep",
            targetDate: nil,
            identity: AIIdentity(provider: "anthropic", model: "claude-other")
        )

        XCTAssertEqual(anthropic?.interpretation, "anthropic text")
        XCTAssertNil(openAI)
        XCTAssertNil(otherModel)
    }

    func testLegacyIdentityRowNeverMatchesCurrentProvider() throws {
        let container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let store = InterpretationCacheStore(context: context)
        context.insert(InterpretationCache(
            contentHash: "legacy-hash",
            module: "compatibility",
            promptVersion: 1,
            targetDate: nil,
            provider: nil,
            model: nil,
            interpretation: "legacy text"
        ))
        try context.save()

        let result = try store.getLatest(
            contentHash: "legacy-hash",
            module: "compatibility",
            targetDate: nil,
            identity: AIIdentity(provider: "anthropic", model: "claude-test")
        )
        XCTAssertNil(result)
    }

    func testInterpretResponseCarriesActualIdentity() throws {
        let json = """
        {
          "interpretation": "text",
          "prompt_version": 1,
          "cached": false,
          "generated_at": "2026-07-16T00:00:00+00:00",
          "provider": "openai",
          "model": "gpt-5.5"
        }
        """.data(using: .utf8)!

        let response = try APICoder.decoder.decode(InterpretResponse.self, from: json)
        XCTAssertEqual(response.provider, "openai")
        XCTAssertEqual(response.model, "gpt-5.5")
    }

    func testHealthFailurePreventsLocalCacheRead() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let interpretStore = InterpretationCacheStore(context: container.mainContext)
        try interpretStore.upsert(
            contentHash: "cached-hash",
            module: "bazi_deep",
            promptVersion: 1,
            targetDate: nil,
            provider: "anthropic",
            model: "claude-test",
            interpretation: "must not be used",
            generatedAt: .now
        )
        let apiClient = IdentityAPIClient(healthResults: [.failure(.healthUnavailable)])
        let orchestrator = DeepAnalysisOrchestrator(
            apiClient: apiClient,
            chartStore: ChartSnapshotStore(context: container.mainContext),
            interpretStore: interpretStore,
            counter: DailyReadCounter(),
            aiIdentityResolver: AIIdentityResolver(apiClient: apiClient)
        )

        do {
            _ = try await orchestrator.localCachedInterpretation(
                contentHash: "cached-hash",
                module: "bazi_deep"
            )
            XCTFail("health 失败时不得读取本地 AI 缓存")
        } catch let error as IdentityTestError {
            XCTAssertEqual(error, .healthUnavailable)
        }
    }

    func testProviderSwitchMakesNextLocalReadMiss() async throws {
        let container = try ModelContainerFactory.makeInMemory()
        let interpretStore = InterpretationCacheStore(context: container.mainContext)
        try interpretStore.upsert(
            contentHash: "switch-hash",
            module: "bazi_deep",
            promptVersion: 1,
            targetDate: nil,
            provider: "anthropic",
            model: "claude-test",
            interpretation: "anthropic text",
            generatedAt: .now
        )
        let apiClient = IdentityAPIClient(healthResults: [
            .success(Self.health(provider: "anthropic", model: "claude-test")),
            .success(Self.health(provider: "openai", model: "gpt-test")),
        ])
        let orchestrator = DeepAnalysisOrchestrator(
            apiClient: apiClient,
            chartStore: ChartSnapshotStore(context: container.mainContext),
            interpretStore: interpretStore,
            counter: DailyReadCounter(),
            aiIdentityResolver: AIIdentityResolver(apiClient: apiClient)
        )

        let beforeSwitch = try await orchestrator.localCachedInterpretation(
            contentHash: "switch-hash",
            module: "bazi_deep"
        )
        let afterSwitch = try await orchestrator.localCachedInterpretation(
            contentHash: "switch-hash",
            module: "bazi_deep"
        )
        let healthCallCount = await apiClient.healthCallCount

        XCTAssertEqual(beforeSwitch?.text, "anthropic text")
        XCTAssertNil(afterSwitch)
        XCTAssertEqual(healthCallCount, 2)
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

private enum IdentityTestError: Error, Equatable {
    case healthUnavailable
    case unexpectedCall
}

private actor IdentityAPIClient: APIClient {
    private var healthResults: [Result<HealthResponse, IdentityTestError>]
    private(set) var healthCallCount = 0

    init(healthResults: [Result<HealthResponse, IdentityTestError>]) {
        self.healthResults = healthResults
    }

    func health() async throws -> HealthResponse {
        healthCallCount += 1
        guard !healthResults.isEmpty else { throw IdentityTestError.unexpectedCall }
        return try healthResults.removeFirst().get()
    }

    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        throw IdentityTestError.unexpectedCall
    }

    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse {
        throw IdentityTestError.unexpectedCall
    }

    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse {
        throw IdentityTestError.unexpectedCall
    }

    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        throw IdentityTestError.unexpectedCall
    }
}
