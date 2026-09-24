import XCTest
@testable import QiCompass

/// 2026-09-24 评审修复 slice 2/5 的纯逻辑半边:
/// - **农历 EN 转写**:hero 第二行 "Lunar 八月十四 · 辛丑 Day" 半中半英
///   → "5th Moon · 28th · Day of 辛丑"。解析器形状按 lunar_python
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
            XCTAssertEqual(DailyImageHeroSection.lunarMonthNumber(s), v, "lunarMonthNumber(\(s)) 应为 \(v)")
        }
        XCTAssertNil(DailyImageHeroSection.lunarMonthNumber("十一"), "月名无「十一」(冬月),不猜")
    }

    func testzhNumber_一到三十() {
        let cases = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6,
            "七": 7, "八": 8, "九": 9, "十": 10, "十九": 19, "三十": 30,
        ]
        for (s, v) in cases {
            XCTAssertEqual(DailyImageHeroSection.zhNumber(s), v, "zhNumber(\(s)) 应为 \(v)")
        }
    }

    func testzhNumber_不认识返回nil() {
        for s in ["", "廿", "正", "冬", "X", "十一三"] {
            XCTAssertNil(DailyImageHeroSection.zhNumber(s), "zhNumber(\(s)) 应为 nil(不猜)")
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
            XCTAssertEqual(DailyImageHeroSection.lunarDayNumber(s), v, "lunarDayNumber(\(s)) 应为 \(v)")
        }
    }

    // MARK: - enLunarLine

    func testenLunarLine_常规与闰月与传统月名() {
        XCTAssertEqual(
            DailyImageHeroSection.enLunarLine(lunarDate: "五月廿八", dayPillar: "辛丑"),
            "5th Moon · 28th · Day of 辛丑"
        )
        XCTAssertEqual(
            DailyImageHeroSection.enLunarLine(lunarDate: "冬月初十", dayPillar: "甲子"),
            "11th Moon · 10th · Day of 甲子"
        )
        XCTAssertEqual(
            DailyImageHeroSection.enLunarLine(lunarDate: "闰六月初十", dayPillar: "丙寅"),
            "Leap 6th Moon · 10th · Day of 丙寅"
        )
        XCTAssertEqual(
            DailyImageHeroSection.enLunarLine(lunarDate: "四月三十", dayPillar: "壬午"),
            "4th Moon · 30th · Day of 壬午"
        )
    }

    func testenLunarLine_序数后缀() {
        // 1st/2nd/3rd/21st/22nd/23rd/11th/12th/13th
        XCTAssertEqual(DailyImageHeroSection.enLunarLine(lunarDate: "正月初一", dayPillar: "X")?.hasSuffix("1st Moon · 1st · Day of X"), true)
        XCTAssertEqual(DailyImageHeroSection.enLunarLine(lunarDate: "二月初二", dayPillar: "X")?.hasSuffix("2nd · Day of X"), true)
        XCTAssertEqual(DailyImageHeroSection.enLunarLine(lunarDate: "三月初三", dayPillar: "X")?.hasSuffix("3rd · Day of X"), true)
        XCTAssertEqual(DailyImageHeroSection.enLunarLine(lunarDate: "五月廿一", dayPillar: "X")?.hasSuffix("21st · Day of X"), true)
        XCTAssertEqual(DailyImageHeroSection.enLunarLine(lunarDate: "五月廿二", dayPillar: "X")?.hasSuffix("22nd · Day of X"), true)
        XCTAssertEqual(DailyImageHeroSection.enLunarLine(lunarDate: "五月廿三", dayPillar: "X")?.hasSuffix("23rd · Day of X"), true)
        XCTAssertEqual(DailyImageHeroSection.enLunarLine(lunarDate: "冬月十一", dayPillar: "X")?.hasSuffix("11th · Day of X"), true)
        XCTAssertEqual(DailyImageHeroSection.enLunarLine(lunarDate: "冬月十二", dayPillar: "X")?.hasSuffix("12th · Day of X"), true)
        XCTAssertEqual(DailyImageHeroSection.enLunarLine(lunarDate: "冬月十三", dayPillar: "X")?.hasSuffix("13th · Day of X"), true)
    }

    func testenLunarLine_未知形状返回nil不猜() {
        // 后端契约是「X月X日」中文形状;这些是契约外输入,必须 nil(调用方回落)
        for s in ["not-a-date", "五月", "五月卅一", "闰月", "五月三十一"] {
            XCTAssertNil(DailyImageHeroSection.enLunarLine(lunarDate: s, dayPillar: "甲"), "enLunarLine(\(s)) 应为 nil")
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
        // 显式 language 参数断言,不依赖测试设备语言(09-23 假红教训)
        XCTAssertEqual(L10n.DailyFortune.chongLabel(chong: "未", targets: [], language: .zh), "冲未")
        XCTAssertEqual(L10n.DailyFortune.chongLabel(chong: "未", targets: ["日支未", "时支未"], language: .zh), "冲未 (日支未、时支未)")
    }
}
