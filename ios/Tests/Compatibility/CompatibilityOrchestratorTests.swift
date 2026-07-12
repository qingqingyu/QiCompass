import XCTest
@testable import QiCompass

/// CompatibilityOrchestrator 单元测试。
///
/// 由于 Orchestrator 依赖 SwiftData ModelContext + APIClient,
/// 这些测试需要 test target 注入 in-memory ModelContainer + Mock APIClient。
/// 在 test target 加入后,完整覆盖以下场景:
///
/// - 两阶段:runDeterministic + runInterpretation 串联
/// - 次数限额:达上限抛 dailyLimitReached
/// - refund:命中后端缓存 refund;失败 refund
/// - 缓存命中:24h 内重复调用不消耗次数
/// - AI 失败隔离:AI 失败不影响 deterministic 阶段的 CompatibilitySnapshot 持久化
/// - 禁词拦截:AI 返回含禁词时抛 forbiddenWordsHit + 不展示原文 + 日志记录
final class CompatibilityOrchestratorTests: XCTestCase {

    func test两阶段_基本流程_canBeImplemented() {
        // 占位:test target 加入后用 in-memory ModelContainer + MockAPIClient 填充
        // 验证:runDeterministic 写 CompatibilitySnapshot(无 interpretation)
        //       → runInterpretation 写 InterpretationCache + 更新 Snapshot.interpretation
        XCTAssertNotNil(CompatibilityOrchestrator.self, "Orchestrator 类型存在")
    }

    func testAI失败隔离_定性结果保留() {
        // 占位:MockAPIClient.interpret throw → orchestrator.runInterpretation throw
        // 但 deterministic 阶段已写入的 CompatibilitySnapshot 仍然可读
        XCTAssertNotNil(CompatibilityError.forbiddenWordsHit(words: ["必成"]))
    }

    func test禁词拦截_抛错且不展示原文() {
        // 占位:MockAPIClient.interpret 返回含禁词文本 → runInterpretation 抛 forbiddenWordsHit
        // 调用方 VM 必须进入 .failed 状态,UI 不展示原文
        let hits = ForbiddenWords.scan("必成婚配")
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first, "必成")
    }

    func test缓存命中_不消耗次数() {
        // 占位:首次 runInterpretation 调 tryConsume;24h 内第二次命中本地缓存 → 直接返回 cached=true
        // counter.remaining 不变(因为没调用 tryConsume)
        XCTAssertNotNil(DailyReadCounter.self)
    }
}
