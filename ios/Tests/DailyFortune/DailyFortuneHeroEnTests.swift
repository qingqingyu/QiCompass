import XCTest
@testable import QiCompass

/// 2026-09-24 评审修复 slice 2/5 的纯逻辑半边(2026-10-01 Today 定稿 D4 改版):
/// - **农历 EN 转写**:hero 第二行 "Lunar 八月十四 · 辛丑 Day" 半中半英
///   → 09-24 版 "5th Moon · 28th · Day of 辛丑" → **定稿版
///   "Eighth lunar month, day 11 · Wu-Shen day"**(月名序数词、日数字、
///   日柱无调拼音连字——EN 基座零汉字)。解析器形状按 lunar_python
///   ground truth(2026-09-24 实测枚举)锁定,未知形状返回 nil(不猜)。
/// - **EN 冲 chip 柱位翻译**:chong targets "日支未" → "Day Pillar"(仅
///   纯函数部分;chongLabel 整体走 AppLanguage,系统语言为 zh 的测试
///   设备只能测 zh 分支回归)。
/// - **zh 冲标签回归**:格式迁移(String(format:) 替字符串拼接)后
///   zh 输出必须与旧拼接逐字相同。
final class DailyFortuneHeroEnTests: XCTestCase {

    // MARK: - lunarMonthNumber / zhNumber / lunarDayNumber

    func testlunarMonthNumber_正月到腊月() {
        // lunar_python 月名 ground truth(2026-09-24 实测):正/二/…/十/冬/腊
        let cases = [
            "正": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6,
            "七": 7, "八": 8, "九": 9, "十": 10, "冬": 11, "腊": 12,
        ]
        for (s, v) in cases {
            XCTAssertEqual(DailyHeaderSection.lunarMonthNumber(s), v, "lunarMonthNumber(\(s)) 应为 \(v)")
        }
        XCTAssertNil(DailyHeaderSection.lunarMonthNumber("十一"), "月名无「十一」(冬月),不猜")
    }

    func testzhNumber_一到三十() {
        let cases = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6,
            "七": 7, "八": 8, "九": 9, "十": 10, "十九": 19, "三十": 30,
        ]
        for (s, v) in cases {
            XCTAssertEqual(DailyHeaderSection.zhNumber(s), v, "zhNumber(\(s)) 应为 \(v)")
        }
    }

    func testzhNumber_不认识返回nil() {
        for s in ["", "廿", "正", "冬", "X", "十一三"] {
            XCTAssertNil(DailyHeaderSection.zhNumber(s), "zhNumber(\(s)) 应为 nil(不猜)")
        }
    }

    func testlunarDayNumber_全形状() {
        let cases = [
            "初一": 1, "初五": 5, "初十": 10,
            "十一": 11, "十九": 19,
            "二十": 20, "廿一": 21, "廿八": 28, "廿九": 29,
            "三十": 30,
        ]
        for (s, v) in cases {
            XCTAssertEqual(DailyHeaderSection.lunarDayNumber(s), v, "lunarDayNumber(\(s)) 应为 \(v)")
        }
    }

    // MARK: - enLunarLine(2026-10-01 D4 定稿格式)

    func testenLunarLine_常规与闰月与传统月名() {
        XCTAssertEqual(
            DailyHeaderSection.enLunarLine(lunarDate: "五月廿八", dayPillar: "辛丑"),
            "Fifth lunar month, day 28 · Xin-Chou day"
        )
        XCTAssertEqual(
            DailyHeaderSection.enLunarLine(lunarDate: "冬月初十", dayPillar: "甲子"),
            "Eleventh lunar month, day 10 · Jia-Zi day"
        )
        XCTAssertEqual(
            DailyHeaderSection.enLunarLine(lunarDate: "闰六月初十", dayPillar: "丙寅"),
            "Leap Sixth lunar month, day 10 · Bing-Yin day"
        )
        XCTAssertEqual(
            DailyHeaderSection.enLunarLine(lunarDate: "四月三十", dayPillar: "壬午"),
            "Fourth lunar month, day 30 · Ren-Wu day"
        )
    }

    func testenLunarLine_月词与日数字() {
        // 12 个月名 → First…Twelfth(mockup "Eighth lunar month" 口径)
        let months = ["正": "First", "二": "Second", "三": "Third", "四": "Fourth",
                      "五": "Fifth", "六": "Sixth", "七": "Seventh", "八": "Eighth",
                      "九": "Ninth", "十": "Tenth", "冬": "Eleventh", "腊": "Twelfth"]
        for (zh, word) in months {
            XCTAssertEqual(
                DailyHeaderSection.enLunarLine(lunarDate: "\(zh)月十五", dayPillar: "甲子"),
                "\(word) lunar month, day 15 · Jia-Zi day",
                "月名 \(zh) → \(word)"
            )
        }
        // 日数字(非序数词):day 1 / day 11 / day 21 / day 30
        for (dayZh, dayNum) in [("初一", 1), ("十一", 11), ("廿一", 21), ("三十", 30)] {
            XCTAssertEqual(
                DailyHeaderSection.enLunarLine(lunarDate: "八月\(dayZh)", dayPillar: "戊申"),
                "Eighth lunar month, day \(dayNum) · Wu-Shen day"
            )
        }
    }

    func testenLunarLine_非干支日柱返回nil不猜() {
        // D4:日柱拼音查表 miss(不在 22 干支表)→ 整行 nil(调用方回落 zh 拼接
        // + 日志),不输出半译串
        XCTAssertNil(DailyHeaderSection.enLunarLine(lunarDate: "八月十一", dayPillar: "X"))
        XCTAssertNil(DailyHeaderSection.enLunarLine(lunarDate: "八月十一", dayPillar: "甲子木"))
    }

    func testenLunarLine_未知形状返回nil不猜() {
        // 后端契约是「X月X日」中文形状;这些是契约外输入,必须 nil(调用方回落)
        for s in ["not-a-date", "五月", "五月卅一", "闰月", "五月三十一"] {
            XCTAssertNil(DailyHeaderSection.enLunarLine(lunarDate: s, dayPillar: "甲"), "enLunarLine(\(s)) 应为 nil")
        }
    }

    // MARK: - EN 柱位翻译(chong targets)

    func testenPillarPositions_单柱与多柱() {
        XCTAssertEqual(L10n.DailyFortune.enPillarPositions(["日支未"]), "Day Pillar")
        XCTAssertEqual(L10n.DailyFortune.enPillarPositions(["年支午"]), "Year Pillar")
        XCTAssertEqual(L10n.DailyFortune.enPillarPositions(["月支丑"]), "Month Pillar")
        XCTAssertEqual(L10n.DailyFortune.enPillarPositions(["时支巳"]), "Hour Pillar")
        XCTAssertEqual(L10n.DailyFortune.enPillarPositions(["日支巳", "时支未"]), "Day & Hour Pillars")
    }

    func testenPillarPositions_未识别形状原样保留() {
        // 后端改形状时宁可露原文也不丢信息
        XCTAssertEqual(L10n.DailyFortune.enPillarPositions(["命宫未"]), "命宫未 Pillar")
    }

    // MARK: - zh 冲标签回归(格式迁移后逐字不变)

    func testchongLabel_zh回归_与旧拼接逐字相同() {
        // 显式 language 参数 + 运行时 format 值拼接(xcstrings 跟系统 bundle
        // 语言走,断言字面量在非 zh 设备会假红;format 译文归 xcstrings 管)
        XCTAssertEqual(
            L10n.DailyFortune.chongLabel(chong: "未", targets: [], language: .zh),
            String(format: L10n.DailyFortune.chongWithFormat, "未")
        )
        var expected = String(format: L10n.DailyFortune.chongWithFormat, "未")
        expected += String(format: L10n.DailyFortune.chongTargetsFormat, "日支未、时支未")
        XCTAssertEqual(
            L10n.DailyFortune.chongLabel(chong: "未", targets: ["日支未", "时支未"], language: .zh),
            expected
        )
    }
}
