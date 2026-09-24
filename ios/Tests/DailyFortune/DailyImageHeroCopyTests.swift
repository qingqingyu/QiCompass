import XCTest
@testable import QiCompass

/// 每日运势 hero 图文案契约测试(2026-09-23 review #2/#3;#3 于 2026-09-24
/// 随 shengxiao 合入演进为动物方案)。
///
/// - #2:mappingEn 每条 ≤16 chars(S02 自定预算:双列 ~163pt/列单行内;
///   曾有 "Play by the Rules"(17)破线无测试拦截,自此守护)
/// - #3:chongLabel 英文输出 = 生肖动物名 + 英文柱位("Clashes with Goat
///   (your Day Pillar)")。演进自 09-23 位置词翻译版(保留地支字仍不够
///   可读,09-24 外评点 "Clashes: 未" 不可读后重做)。
///
/// 语言断言用 `chongLabel(_:targets:language:)` 显式参数 + **运行时
/// format 值拼接**——xcstrings `String(localized:)` 跟系统 bundle 语言走,
/// 与显式 language 参数在非 en 设备分叉,断言 format 字面量会设备语言
/// 假红(2026-09-23 教训);测试验证的是逻辑分支(动物名/柱位翻译/未知
/// 透出/拼接形态),format 译文归 xcstrings 管。
final class DailyImageHeroCopyTests: XCTestCase {

    // MARK: - #2 mappingEn ≤16 chars 预算

    func testMappingEnBudgetAllWithin16Chars() {
        let over = HeroYiJiColumns.mappingEn.values
            .flatMap { $0.yi + $0.ji }
            .filter { $0.count > 16 }
        XCTAssertTrue(
            over.isEmpty,
            "mappingEn 超出 ≤16 chars 预算(双列 ~163pt/列单行):\(over)"
        )
    }

    // MARK: - #3 chongLabel EN 动物方案(2026-09-24)

    /// 断言辅助:与生产同源的 format 运行时值拼接。
    private func expectEn(_ animal: String, positions: String? = nil) -> String {
        var s = String(format: L10n.DailyFortune.chongWithFormat, animal)
        if let positions {
            s += String(format: L10n.DailyFortune.chongTargetsFormat, positions)
        }
        return s
    }

    func testChongLabelEnAnimalAndPillarPositions() {
        let label = L10n.DailyFortune.chongLabel(
            chong: "巳", targets: ["年支巳", "时支巳"], language: .en
        )
        XCTAssertEqual(
            label,
            expectEn("Snake", positions: "Year & Hour Pillars"),
            "地支→生肖动物名 + 柱位翻译 + 复数 Pillars"
        )
    }

    func testChongLabelEnUnknownTargetPassesThrough() {
        let label = L10n.DailyFortune.chongLabel(
            chong: "午", targets: ["天干甲"], language: .en
        )
        XCTAssertEqual(
            label,
            expectEn("Horse", positions: "天干甲 Pillar"),
            "未识别前缀原样透出(宁可露中文不丢信息),单数 Pillar"
        )
    }

    func testChongLabelZhKeepsTargetsUntranslated() {
        let label = L10n.DailyFortune.chongLabel(
            chong: "巳", targets: ["年支巳", "时支巳"], language: .zh
        )
        var expected = String(format: L10n.DailyFortune.chongWithFormat, "巳")
        expected += String(format: L10n.DailyFortune.chongTargetsFormat, "年支巳、时支巳")
        XCTAssertEqual(label, expected, "zh 分支 targets 原样、顿号连接")
    }

    func testChongLabelEmptyTargetsOmitsParentheses() {
        let label = L10n.DailyFortune.chongLabel(
            chong: "午", targets: [], language: .en
        )
        XCTAssertEqual(label, expectEn("Horse"), "空 targets 不加括号后缀")
    }
}
