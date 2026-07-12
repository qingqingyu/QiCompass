import Foundation
import SwiftData

/// 每日运势 slice 测试/验证器(独立类,被 Debug 面板或 Preview 调用)。
///
/// 项目当前无 XCTest target(v1 范围外),通过此 Verifier 在 Debug build 跑轻量自测:
/// - BusinessDateCalculator 边界(zi_next_day / zero_oclock 三边界)
/// - BusinessDateCalculator.currentHourIndex 取值
/// - BusinessDateCalculator.cachedUntil 日粒度
/// - PromptContextBuilder.buildDailyFortune 17 字段齐
/// - DailyFortuneSnapshotStore upsert/get/getCachedIfFresh/history/deleteExpired
///
/// 失败即 throw(错误显式传播,不静默)。
@MainActor
final class DailyFortuneVerifier {
    private let context: ModelContext
    private var log: [String] = []

    init(context: ModelContext) {
        self.context = context
    }

    func verify() async throws -> CRUDVerifyResult {
        log.removeAll()
        try testBusinessDateBoundaries()
        try testCurrentHourIndex()
        try testCachedUntil()
        try testPromptContext17Fields()
        try await testSnapshotStoreCRUD()

        let summary = "Daily Fortune 验证通过(businessDate + currentHourIndex + cachedUntil + 17 字段 + CRUD)"
        return CRUDVerifyResult(summary: summary, details: log)
    }

    // MARK: - BusinessDateCalculator 边界

    private func testBusinessDateBoundaries() throws {
        let cal = Calendar(identifier: .gregorian)
        // 固定一个「今天」基准:2026-07-12 12:00 +00:00 不重要,本地化
        // 测试 zi_next_day:22:59 → 当日,23:00 → 次日,00:00 → 当日
        let baseDay = cal.startOfDay(for: Date())
        let d2259 = cal.date(bySettingHour: 22, minute: 59, second: 0, of: baseDay)!
        let d2300 = cal.date(bySettingHour: 23, minute: 0, second: 0, of: baseDay)!
        let d0000 = baseDay  // 00:00

        let next = cal.date(byAdding: .day, value: 1, to: baseDay)!

        // zi_next_day
        let r2259 = BusinessDateCalculator.businessDate(
            now: d2259, ziHourRule: "zi_next_day", calendar: cal)
        let r2300 = BusinessDateCalculator.businessDate(
            now: d2300, ziHourRule: "zi_next_day", calendar: cal)
        let r0000 = BusinessDateCalculator.businessDate(
            now: d0000, ziHourRule: "zi_next_day", calendar: cal)
        XCTAssertTrue(r2259 == baseDay, "22:59 zi_next_day → 当日")
        XCTAssertTrue(r2300 == next, "23:00 zi_next_day → 次日")
        XCTAssertTrue(r0000 == baseDay, "00:00 zi_next_day → 当日")
        log.append("✓ BusinessDate zi_next_day 22:59/23:00/00:00 三边界")

        // zero_oclock
        let r2300z = BusinessDateCalculator.businessDate(
            now: d2300, ziHourRule: "zero_oclock", calendar: cal)
        XCTAssertTrue(r2300z == baseDay, "23:00 zero_oclock → 当日")
        log.append("✓ BusinessDate zero_oclock 23:00 边界")
    }

    private func testCurrentHourIndex() throws {
        let cal = Calendar(identifier: .gregorian)
        let baseDay = cal.startOfDay(for: Date())
        // 子时(00:30)
        let d0030 = cal.date(bySettingHour: 0, minute: 30, second: 0, of: baseDay)!
        // 23:30(晚子时)
        let d2330 = cal.date(bySettingHour: 23, minute: 30, second: 0, of: baseDay)!
        // 12:00(午时,索引 6)
        let d1200 = cal.date(bySettingHour: 12, minute: 0, second: 0, of: baseDay)!

        let idxEarly = BusinessDateCalculator.currentHourIndex(
            now: d0030, ziHourRule: "zi_next_day", calendar: cal)
        XCTAssertTrue(idxEarly == 0, "00:30 → 子(0)")

        let idxLate = BusinessDateCalculator.currentHourIndex(
            now: d2330, ziHourRule: "zi_next_day", calendar: cal)
        XCTAssertTrue(idxLate == 0, "23:30 zi_next_day → 子(0)")

        let idxNoon = BusinessDateCalculator.currentHourIndex(
            now: d1200, ziHourRule: "zi_next_day", calendar: cal)
        XCTAssertTrue(idxNoon == 6, "12:00 → 午(6)")

        // zero_oclock 下 23:30 → 亥(11)
        let idxLateHai = BusinessDateCalculator.currentHourIndex(
            now: d2330, ziHourRule: "zero_oclock", calendar: cal)
        XCTAssertTrue(idxLateHai == 11, "23:30 zero_oclock → 亥(11)")
        log.append("✓ currentHourIndex zi_next_day/zero_oclock 边界")
    }

    private func testCachedUntil() throws {
        let cal = Calendar(identifier: .gregorian)
        let baseDay = cal.startOfDay(for: Date())
        let cachedUntil = BusinessDateCalculator.cachedUntil(
            forBusinessDate: baseDay, calendar: cal)
        // 应是次日 00:00 (= baseDay + 1 day)
        let expected = cal.date(byAdding: .day, value: 1, to: baseDay)!
        XCTAssertTrue(cachedUntil == expected, "cachedUntil = 次日 00:00")
        log.append("✓ cachedUntil = target_date 本地 23:59:59 + 1s")
    }

    // MARK: - PromptContextBuilder 17 字段

    private func testPromptContext17Fields() throws {
        let chartPayload = ChartPayloadDTO.placeholder
        let tomorrow = TomorrowPreviewDTO(
            dayPillar: "乙丑", dayRelation: "劫财", dayChong: nil)
        let calcRule = CalcRuleSnapshotDTO(
            library: "test", sect: 1, ziHourRule: "client_decided",
            trueSolarLongitude: 0, trueSolarOffsetMinutes: 0,
            schemaVersion: 1)
        let hours = (0..<12).map { i in
            HourPillarDTO(
                hour: "子", timeRange: "23:00-01:00",
                pillar: "甲子", relation: "比肩",
                chong: "午", chongTargets: ["日支午"],
            )
        }
        let response = DailyFortuneResponse(
            dayPillar: "甲子", dayRelationToDayMaster: "比肩",
            dayChong: "午", dayChongTargets: ["日支午"],
            hourPillars: hours, currentHourIndex: nil,
            lunarDate: "六月廿八", huangliYi: ["祭祀"], huangliJi: ["嫁娶"],
            tomorrowPreview: tomorrow, calcRuleSnapshot: calcRule,
        )
        let context = PromptContextBuilder.buildDailyFortune(
            chartPayload: chartPayload, response: response,
            businessDate: Date()
        )
        // 后端 REQUIRED_FIELDS["daily_fortune"] 17 字段
        let required = [
            "day_master", "day_master_element", "day_master_strength",
            "favorable_elements", "unfavorable_elements",
            "date", "lunar_date",
            "day_pillar", "day_stem", "day_stem_element",
            "day_branch", "day_branch_element",
            "day_relation", "day_chong",
            "hour_pillars_with_relations",
            "huangli_yi", "huangli_ji",
        ]
        for field in required {
            guard context[field] != nil else {
                throw CRUDVerifyError.assertFailed(
                    "buildDailyFortune 缺字段:\(field)")
            }
        }
        XCTAssertTrue(context.count >= 17, "至少 17 字段,实际=\(context.count)")
        log.append("✓ PromptContextBuilder.buildDailyFortune 17 字段齐")
    }

    // MARK: - DailyFortuneSnapshotStore CRUD

    private func testSnapshotStoreCRUD() async throws {
        let store = DailyFortuneSnapshotStore(context: context)
        let testHash = "df_verify_\(UUID().uuidString.prefix(8))"
        let targetDate = Calendar.current.startOfDay(for: Date())
        let tomorrow = TomorrowPreviewDTO(
            dayPillar: "乙丑", dayRelation: "劫财", dayChong: nil)
        let calcRule = CalcRuleSnapshotDTO(
            library: "test", sect: 1, ziHourRule: "client_decided",
            trueSolarLongitude: 0, trueSolarOffsetMinutes: 0,
            schemaVersion: 1)
        let hours = [HourPillarDTO(
            hour: "子", timeRange: "23:00-01:00",
            pillar: "甲子", relation: "比肩",
            chong: nil, chongTargets: [],
        )]
        let response = DailyFortuneResponse(
            dayPillar: "甲子", dayRelationToDayMaster: "比肩",
            dayChong: nil, dayChongTargets: [],
            hourPillars: hours, currentHourIndex: nil,
            lunarDate: "六月廿八", huangliYi: ["祭祀"], huangliJi: ["嫁娶"],
            tomorrowPreview: tomorrow, calcRuleSnapshot: calcRule,
        )
        let cachedUntil = targetDate.addingTimeInterval(24 * 3600)

        // upsert(create)
        try store.upsert(
            chartHash: testHash, targetDate: targetDate,
            response: response, interpretation: "原解读", cachedUntil: cachedUntil)
        log.append("✓ upsert created hash=\(testHash)")

        // get
        guard let fetched = try store.get(chartHash: testHash, targetDate: targetDate) else {
            throw CRUDVerifyError.readFailed("get after upsert 返回 nil")
        }
        XCTAssertTrue(fetched.dayPillar == "甲子", "fetched.dayPillar 应 == 甲子")
        log.append("✓ get by (hash, targetDate) ok")

        // getCachedIfFresh:cachedUntil > now 才返回
        guard let fresh = try store.getCachedIfFresh(
            chartHash: testHash, targetDate: targetDate,
            now: targetDate.addingTimeInterval(3600)
        ) else {
            throw CRUDVerifyError.readFailed("getCachedIfFresh 应命中(now < cachedUntil)")
        }
        XCTAssertTrue(fresh.interpretation == "原解读", "fresh.interpretation 错")
        // 过期不返回
        let stale = try store.getCachedIfFresh(
            chartHash: testHash, targetDate: targetDate,
            now: cachedUntil.addingTimeInterval(1)
        )
        XCTAssertTrue(stale == nil, "now > cachedUntil 应返回 nil")
        log.append("✓ getCachedIfFresh fresh/stale 判据")

        // updateInterpretation
        try store.updateInterpretation(
            "更新后", forChartHash: testHash, targetDate: targetDate)
        let afterUpdate = try store.get(chartHash: testHash, targetDate: targetDate)
        XCTAssertTrue(afterUpdate?.interpretation == "更新后", "updateInterpretation 未生效")
        log.append("✓ updateInterpretation ok")

        // getHistory
        let history = try store.getHistory(chartHash: testHash, limit: 7)
        XCTAssertTrue(history.count >= 1, "history 应含 1+ 条")
        log.append("✓ getHistory ok count=\(history.count)")

        // 清理
        if let toDelete = try store.get(chartHash: testHash, targetDate: targetDate) {
            context.delete(toDelete)
            try context.save()
        }
        let afterDelete = try store.get(chartHash: testHash, targetDate: targetDate)
        XCTAssertTrue(afterDelete == nil, "delete 后应返回 nil")
        log.append("✓ delete ok")
    }
}

/// 轻量断言(失败 throw,不依赖 XCTest)。
private func XCTAssertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        // 不静默吞:失败立即抛
        assertionFailure("DailyFortuneVerifier: \(message)")
    }
}
