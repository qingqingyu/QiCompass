import XCTest
@testable import QiCompass

/// 每日运势 hero 图文案契约测试(2026-09-23 review #2/#3;#3 于 2026-09-24
/// 随 shengxiao 合入演进为动物方案)。
///
/// - #2:mappingEn 每条 ≤16 chars(S02 自定预算:双列 ~138pt/列单行内
///   @375pt 屏——2026-09-28 S03 hero 内边距 4→20 + 列距 34→24 后的列宽;
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
            "mappingEn 超出 ≤16 chars 预算(双列 ~138pt/列单行 @375pt 屏):\(over)"
        )
    }

    // MARK: - 宜忌词表 ⟷ 兜底模板一致性(2026-09-28 外评)

    /// 宜词不得出现在兜底模板的告诫半句(分号后)——2026-09-28 外评「宜分利 vs 分利慢一拍」。
    /// zh / zh-Hant 两表逐键检查;EN 为短语无法子串比对,靠人工 review(见 slices 文档 S01)。
    func testYiItemsNotContradictedByEngineTemplateCaution() {
        let pairs: [([String: (yi: [String], ji: [String])], [String: String])] = [
            (HeroYiJiColumns.mappingZh, EngineReadingTemplates.zh),
            (HeroYiJiColumns.mappingHant, EngineReadingTemplates.hant),
        ]
        for (mapping, templates) in pairs {
            XCTAssertEqual(Set(mapping.keys), Set(templates.keys))
            for (relation, cols) in mapping {
                guard let text = templates[relation] else { continue }  // 键集合不等已由上方断言报出
                guard let semi = text.firstIndex(where: { $0 == ";" || $0 == "；" }) else {
                    XCTFail("模板缺分号(告诫半句分隔):\(relation)")
                    continue
                }
                let caution = text[semi...]
                let hits = cols.yi.filter { caution.contains($0) }
                XCTAssertTrue(hits.isEmpty, "\(relation) 宜词出现在模板告诫半句:\(hits)")
            }
        }
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

    // MARK: - 十神释义静态表(D3,2026-09-29)

    /// 键集合 == BaziTerms.tenGods 的 zh 键(11,含偏官别名)——三语表同守。
    func testShiShenNotesKeySetMatchesBaziTermsTenGods() {
        let expected = Set(BaziTerms.tenGods.map(\.zh))
        for (name, table) in [("zh", HeroShiShenNotes.zh),
                              ("hant", HeroShiShenNotes.hant),
                              ("en", HeroShiShenNotes.en)] {
            XCTAssertEqual(
                Set(table.keys), expected,
                "[\(name)] 释义表键集合 ≠ BaziTerms.tenGods(新增十神须同步释义)"
            )
        }
    }

    /// 文案预算:zh/hant ≤50 字、en ≤150 chars(释义卡 250pt detent 内 ~3 行);
    /// 同时守护空值/过短(漏写半句)。
    func testShiShenNotesLengthBudgetAndNonEmpty() {
        for table in [HeroShiShenNotes.zh, HeroShiShenNotes.hant] {
            XCTAssertTrue(table.values.allSatisfy { (8...50).contains($0.count) }, "zh/hant 释义应在 8-50 字:\(table)")
        }
        XCTAssertTrue(
            HeroShiShenNotes.en.values.allSatisfy { (20...150).contains($0.count) },
            "en 释义应在 20-150 chars"
        )
    }

    /// 偏官 = 七杀 同义(BaziTerms 同用 Seven Killings),释义必须同文。
    func testShiShenNotesPianGuanAliasesQiSha() {
        XCTAssertEqual(HeroShiShenNotes.zh["偏官"], HeroShiShenNotes.zh["七杀"])
        XCTAssertEqual(HeroShiShenNotes.hant["偏官"], HeroShiShenNotes.hant["七杀"])
        XCTAssertEqual(HeroShiShenNotes.en["偏官"], HeroShiShenNotes.en["七杀"])
    }

    /// S01 守护同款,升格到三语:宜词不得出现在释义**告诫半句**(分号后)。
    /// S01 时 EN 模板不可子串比对;本表为自有长句,EN 词表短语可精确比对。
    /// 比对大小写不敏感:mappingEn 宜词是 Title Case("Take the Lead"),释义
    /// 告诫半句是小写("take the lead"),区分大小写会让 EN 腿永不命中(空转)。
    func testShiShenNotesYiWordsNotInCautionHalf() {
        let pairs: [([String: String], [String: (yi: [String], ji: [String])], String)] = [
            (HeroShiShenNotes.zh, HeroYiJiColumns.mappingZh, "zh"),
            (HeroShiShenNotes.hant, HeroYiJiColumns.mappingHant, "hant"),
            (HeroShiShenNotes.en, HeroYiJiColumns.mappingEn, "en"),
        ]
        for (notes, mapping, lang) in pairs {
            for (relation, cols) in mapping {
                guard let text = notes[relation],
                      let semi = text.firstIndex(where: { $0 == ";" || $0 == "；" })
                else {
                    XCTFail("[\(lang)] \(relation) 释义缺失或无分号(宜/告诫两半结构)")
                    continue
                }
                let caution = text[semi...].lowercased()
                let hits = cols.yi.filter { caution.contains($0.lowercased()) }
                XCTAssertTrue(
                    hits.isEmpty,
                    "[\(lang)] \(relation) 宜词出现在释义告诫半句:\(hits)"
                )
            }
        }
    }
}
