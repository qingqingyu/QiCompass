import XCTest
@testable import QiCompass

/// DailyReadCounter 单元测试(全局池口径,方案 §D1 / step 1)。
///
/// 用 `UserDefaults(suiteName:)` 隔离测试,避免污染 .standard。
/// 每个用例独立 suite,确保 counter 状态互不影响。
final class DailyReadCounterTests: XCTestCase {

    /// Helper:创建独立 UserDefaults 的 counter。
    private func makeCounter() -> DailyReadCounter {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // 测试结束清理(防泄漏到其他 suite)
        addTeardownBlock { [weak defaults] in
            defaults?.removePersistentDomain(forName: suite)
        }
        return DailyReadCounter(defaults: defaults)
    }

    // MARK: - 全局池口径

    func test全局池_初始剩余为10次() {
        let counter = makeCounter()
        XCTAssertEqual(counter.remaining(), 10)
    }

    func test全局池_三模块累计到10次后均达上限() {
        let counter = makeCounter()

        // bazi_deep 扣 4 次
        for _ in 0..<4 {
            XCTAssertTrue(counter.tryConsume(module: "bazi_deep"))
        }
        // daily_fortune 扣 3 次
        for _ in 0..<3 {
            XCTAssertTrue(counter.tryConsume(module: "daily_fortune"))
        }
        // compatibility 扣 3 次 → 累计 10,达上限
        for _ in 0..<3 {
            XCTAssertTrue(counter.tryConsume(module: "compatibility"))
        }

        // 三模块再扣均失败(全局池口径)
        XCTAssertFalse(counter.tryConsume(module: "bazi_deep"))
        XCTAssertFalse(counter.tryConsume(module: "daily_fortune"))
        XCTAssertFalse(counter.tryConsume(module: "compatibility"))
        XCTAssertEqual(counter.remaining(), 0)
    }

    // MARK: - 模块埋点

    func test模块埋点_各模块独立计数() {
        let counter = makeCounter()
        _ = counter.tryConsume(module: "bazi_deep")
        _ = counter.tryConsume(module: "bazi_deep")
        _ = counter.tryConsume(module: "daily_fortune")

        XCTAssertEqual(counter.moduleConsumed("bazi_deep"), 2)
        XCTAssertEqual(counter.moduleConsumed("daily_fortune"), 1)
        XCTAssertEqual(counter.moduleConsumed("compatibility"), 0)
        // 全局池 = 2 + 1 = 3
        XCTAssertEqual(counter.remaining(), 7)
    }

    // MARK: - Refund

    func test退款_同步回退全局池与模块埋点() {
        let counter = makeCounter()
        _ = counter.tryConsume(module: "bazi_deep")
        _ = counter.tryConsume(module: "bazi_deep")
        _ = counter.tryConsume(module: "daily_fortune")

        // 退款 bazi_deep 一次
        counter.refund(module: "bazi_deep")

        XCTAssertEqual(counter.moduleConsumed("bazi_deep"), 1)
        XCTAssertEqual(counter.moduleConsumed("daily_fortune"), 1)
        XCTAssertEqual(counter.remaining(), 8)  // 10 - (1+1) = 8
    }

    func test退款_不低于0() {
        let counter = makeCounter()
        // 未消耗直接 refund → 不应变负
        counter.refund(module: "bazi_deep")
        counter.refund(module: "bazi_deep")
        XCTAssertEqual(counter.remaining(), 10)
        XCTAssertEqual(counter.moduleConsumed("bazi_deep"), 0)
    }

    // MARK: - 跨日重置

    func test跨日重置_午夜后新key从0开始() {
        let counter = makeCounter()

        // 今日全部用完
        for _ in 0..<10 {
            XCTAssertTrue(counter.tryConsume(module: "bazi_deep"))
        }
        XCTAssertEqual(counter.remaining(), 0)

        // 明日 00:01:00 → 全新 key,重置回 10
        let cal = Calendar.autoupdatingCurrent
        let tomorrow001 = cal.date(
            bySettingHour: 0, minute: 1, second: 0,
            of: cal.date(byAdding: .day, value: 1, to: Date())!
        )!

        XCTAssertEqual(counter.remaining(date: tomorrow001), 10)
        XCTAssertTrue(counter.tryConsume(module: "bazi_deep", date: tomorrow001))
    }

    // MARK: - nextResetDate

    func test下次重置时间_本地午夜() {
        let counter = makeCounter()
        let now = Date()
        let reset = counter.nextResetDate(date: now)

        let cal = Calendar.autoupdatingCurrent
        let expectedMidnight = cal.startOfDay(for:
            cal.date(byAdding: .day, value: 1, to: now)!
        )
        XCTAssertEqual(reset, expectedMidnight)
    }
}
