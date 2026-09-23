import XCTest
@testable import QiCompass

/// 每日运势 hero 图文案契约测试(2026-09-23 review #2/#3)。
///
/// - #2:mappingEn 每条 ≤16 chars(S02 自定预算:mono 14.5pt 双列 ~163pt/列
///   单行内;曾有 "Play by the Rules"(17)破线无测试拦截,自此守护)
/// - #3:chongLabel 英文 targets 位置前缀翻译——后端 `_chong_targets` 恒出
///   中文"年支巳"形,EN 需显示 "Year Branch 巳";此前注释宣称此输出而实现未译。
///
/// 语言断言用 `chongLabel(_:targets:language:)` 显式参数 + `chongPrefix`
/// 符号拼接,不依赖测试设备语言(2026-09-23 教训:设备语言敏感测试会假红)。
final class DailyImageHeroCopyTests: XCTestCase {

    // MARK: - #2 mappingEn ≤16 chars 预算

    func testMappingEnBudgetAllWithin16Chars() {
        let over = HeroYiJiColumns.mappingEn.values
            .flatMap { $0.yi + $0.ji }
            .filter { $0.count > 16 }
        XCTAssertTrue(
            over.isEmpty,
            "mappingEn 超出 ≤16 chars 预算(mono 14.5pt 单列 ~163pt 单行):\(over)"
        )
    }

    // MARK: - #3 chongLabel EN 位置前缀翻译

    func testChongLabelEnTranslatesPositionPrefixes() {
        let label = L10n.DailyFortune.chongLabel(
            chong: "巳", targets: ["年支巳", "时支巳"], language: .en
        )
        XCTAssertEqual(
            label,
            "\(L10n.DailyFortune.chongPrefix)巳 (Year Branch 巳, Hour Branch 巳)"
        )
    }

    func testChongLabelEnUnknownPrefixPassesThrough() {
        let label = L10n.DailyFortune.chongLabel(
            chong: "午", targets: ["天干甲"], language: .en
        )
        XCTAssertEqual(
            label,
            "\(L10n.DailyFortune.chongPrefix)午 (天干甲)"
        )
    }

    func testChongLabelZhKeepsTargetsUntranslated() {
        let label = L10n.DailyFortune.chongLabel(
            chong: "巳", targets: ["年支巳", "时支巳"], language: .zh
        )
        XCTAssertEqual(
            label,
            "\(L10n.DailyFortune.chongPrefix)巳 (年支巳、时支巳)"
        )
    }

    func testChongLabelEmptyTargetsOmitsParentheses() {
        let label = L10n.DailyFortune.chongLabel(
            chong: "午", targets: [], language: .en
        )
        XCTAssertEqual(label, "\(L10n.DailyFortune.chongPrefix)午")
    }
}
