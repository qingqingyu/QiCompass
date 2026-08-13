import SwiftData
import XCTest
@testable import QiCompass

/// InterpretationCacheStore 的身份过滤单元测试(纯 SwiftData,不依赖网络 mock)。
///
/// reader pipeline(resolve → getLatest → maxAge)的测试见
/// `CachedInterpretationReaderTests`。这里只覆盖 cache store 本身的身份语义。
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
          "model": "gpt-5.5",
          "language": "zh"
        }
        """.data(using: .utf8)!

        let response = try APICoder.decoder.decode(InterpretResponse.self, from: json)
        XCTAssertEqual(response.provider, "openai")
        XCTAssertEqual(response.model, "gpt-5.5")
        // i18n:language 字段正确解码
        XCTAssertEqual(response.language, "zh")
    }
}
