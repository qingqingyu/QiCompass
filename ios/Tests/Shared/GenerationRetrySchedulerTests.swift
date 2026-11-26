import Foundation
import XCTest
@testable import QiCompass

/// GenerationRetryScheduler 契约测试(2026-11-26,503/429 长周期自动重试)。
///
/// 锁定调度语义(下一批 Deep/Compat/Ask 接入前的底座锚点):
/// - **单发即消费**:到期 fireDue 移除条目,同刻重复 fireDue 不再触发
/// - **未到期不触发**:fireDue(now:) 只挑 <= now 的条目
/// - **kind 隔离**:一个 kind 到期不影响其它 kind 的条目
/// - **schedule 顺延 / clear 清除**:同 kind 重 schedule 覆盖旧期限
/// - **持久化往返**:表经 UserDefaults 落盘,新实例读同一 defaults 可见
/// - **未知 kind 自愈**:表里无法解析的 raw key 到期被清掉且不投递
/// - **通知载荷**:到期通知 userInfo 带 kind rawValue
/// - **65 分钟口径**:retryInterval == 3900(拍板值,错开整点防同步脉冲)
final class GenerationRetrySchedulerTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var scheduler: GenerationRetryScheduler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "gen-retry-scheduler-tests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName), "测试 suite 创建失败"
        )
        scheduler = GenerationRetryScheduler(defaults: defaults)
    }

    override func tearDown() {
        // 双重解包:setUp 若在 defaults 赋值前抛错,tearDown 不得再对
        // IUO 强解把「测试失败」放大成「测试崩溃」。
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        super.tearDown()
    }

    // MARK: - 期限与消费

    func testFireDueBeforeDeadlineDoesNotTrigger() {
        scheduler.schedule(.dailyFortune, retryAfter: 3900)

        let fired = scheduler.fireDue()

        XCTAssertTrue(fired.isEmpty, "未到期不应触发")
        XCTAssertNotNil(
            scheduler.nextRetryAt(.dailyFortune), "未到期条目必须保留"
        )
    }

    func testFireDueAfterDeadlineConsumesEntrySingleShot() {
        let scheduledAt = Date()
        scheduler.schedule(.dailyFortune, retryAfter: 1)

        let fired = scheduler.fireDue(
            now: scheduledAt.addingTimeInterval(100)
        )

        XCTAssertEqual(fired, [.dailyFortune])
        XCTAssertNil(
            scheduler.nextRetryAt(.dailyFortune), "单发即消费:到期后条目删除"
        )
        // 同一刻重复检查:不重发(重试链由 VM 失败后重新 schedule 顺延)
        let refired = scheduler.fireDue(now: scheduledAt.addingTimeInterval(100))
        XCTAssertTrue(refired.isEmpty)
    }

    func testScheduleOverwritesPreviousDeadline() throws {
        scheduler.schedule(.deepModule, retryAfter: 60)
        scheduler.schedule(.deepModule, retryAfter: 500)

        let due = try XCTUnwrap(scheduler.nextRetryAt(.deepModule))
        XCTAssertEqual(
            due.timeIntervalSinceNow, 500, accuracy: 5,
            "同 kind 重 schedule 应覆盖旧期限(顺延语义)"
        )
    }

    func testClearRemovesEntry() {
        scheduler.schedule(.compatibility)
        XCTAssertNotNil(scheduler.nextRetryAt(.compatibility))

        scheduler.clear(.compatibility)
        // 重复 clear 不得崩(幂等)
        scheduler.clear(.compatibility)
        XCTAssertNil(scheduler.nextRetryAt(.compatibility))
    }

    // MARK: - kind 隔离与自愈

    func testFireDueOnlyConsumesDueKinds() {
        scheduler.schedule(.dailyFortune, retryAfter: 1)
        scheduler.schedule(.compatibility, retryAfter: 10_000)

        let fired = scheduler.fireDue(now: Date().addingTimeInterval(100))

        XCTAssertEqual(fired, [.dailyFortune], "只有到期 kind 被消费")
        XCTAssertNotNil(
            scheduler.nextRetryAt(.compatibility), "未到期 kind 条目不受影响"
        )
    }

    func testUnknownKindRawKeyIsCleanedWithoutNotifying() {
        defaults.set(
            ["legacyUnknownKind": Date.distantPast],
            forKey: GenerationRetryScheduler.deadlinesKey
        )

        let fired = scheduler.fireDue()

        XCTAssertTrue(fired.isEmpty, "无法解析的 raw key 不投递")
        let table = defaults.dictionary(
            forKey: GenerationRetryScheduler.deadlinesKey
        ) as? [String: Date]
        XCTAssertTrue(
            table?.isEmpty ?? true, "孤儿条目到期时随消费一并清除"
        )
    }

    // MARK: - 持久化与通知

    func testDeadlinesPersistAcrossInstances() throws {
        scheduler.schedule(.askAnswer, retryAfter: 120)

        let reloaded = try XCTUnwrap(
            scheduler.nextRetryAt(.askAnswer), "写入后应可读"
        )
        // 模拟进程重启:同一 defaults 上新建调度器
        let reborn = GenerationRetryScheduler(defaults: defaults)
        XCTAssertEqual(
            reborn.nextRetryAt(.askAnswer), reloaded,
            "条目经 UserDefaults 往返不丢(冷启补试依赖)"
        )
    }

    func testFireDuePostsNotificationCarryingKind() {
        let exp = expectation(description: "到期通知已投递")
        var receivedKind: String?
        let observer = NotificationCenter.default.addObserver(
            forName: GenerationRetryScheduler.dueNotification,
            object: nil,
            queue: .main
        ) { note in
            receivedKind = note.userInfo?[
                GenerationRetryScheduler.kindUserInfoKey
            ] as? String
            exp.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        scheduler.schedule(.dailyFortune, retryAfter: -1)
        _ = scheduler.fireDue()

        wait(for: [exp], timeout: 1)
        XCTAssertEqual(
            receivedKind, GenerationRetryScheduler.Kind.dailyFortune.rawValue,
            "VM 订阅方靠 userInfo 的 kind rawValue 过滤,载荷必须正确"
        )
    }

    // MARK: - 口径常量

    func testRetryIntervalMatches65MinuteDecision() {
        XCTAssertEqual(
            GenerationRetryScheduler.retryInterval, 65 * 60,
            "2026-11-26 拍板:65 分钟(3900s)错开整点,防服务端小时桶同步脉冲"
        )
    }

    // MARK: - 重试判定矩阵(APIError.isRetryable503Or429)

    func testIsRetryable503Or429Classification() {
        XCTAssertTrue(APIError.isRetryable503Or429(
            APIError.httpError(statusCode: 503, body: nil)
        ))
        XCTAssertTrue(APIError.isRetryable503Or429(
            APIError.httpError(statusCode: 429, body: nil)
        ))
        // 网关层偶发 5xx 里只有 503 在拍板口径内
        XCTAssertFalse(APIError.isRetryable503Or429(
            APIError.httpError(statusCode: 500, body: nil)
        ))
        XCTAssertFalse(APIError.isRetryable503Or429(
            APIError.httpError(statusCode: 502, body: nil)
        ))
        XCTAssertTrue(APIError.isRetryable503Or429(
            APIError.backendError(code: "QUOTA_EXCEEDED", message: "m", requestId: nil)
        ))
        // 专属语义错误不参与自动重试(各有恢复路径,重试只会掩盖真实动作)
        XCTAssertFalse(APIError.isRetryable503Or429(
            APIError.backendError(code: "STALE_SOURCE", message: "m", requestId: nil)
        ))
        XCTAssertFalse(APIError.isRetryable503Or429(
            APIError.backendError(code: "CONTEXT_TOKEN_INVALID", message: "m", requestId: nil)
        ))
        XCTAssertFalse(APIError.isRetryable503Or429(
            APIError.backendError(code: "ASK_CREDITS_REQUIRED", message: "m", requestId: nil)
        ))
        // 离线/超时不在本调度器口径(短周期降级链各自处理)
        XCTAssertFalse(APIError.isRetryable503Or429(
            APIError.networkError(URLError(.notConnectedToInternet))
        ))
        XCTAssertFalse(APIError.isRetryable503Or429(
            NSError(domain: "test", code: 1)
        ))
    }
}
