import XCTest
@testable import QiCompass

/// S5 共享术语释义层(BaziTermNotes)守护(2026-09-30 BP 评审 R9/R10):
/// - 覆盖面(十神 11 含别名 + 日主 + 旺衰 5 + 五行关系 3 + 喜忌 2 = 22)
/// - 三语非空 + 未知术语显式 nil(挂载点据此不挂入口,宁缺毋滥)
/// - 偏官 = 七杀别名释义一致
/// - 键空间 ⊆ BaziTerms(标题渲染走 BaziTerms.display/index,未注册会回落原值+日志)
/// - 忌神释义与 S1 去绝对化同轨(明说"不是生活禁忌")
final class BaziTermNotesTests: XCTestCase {

    func test_allEntries_threeLanguages_nonEmpty() {
        for (key, _) in BaziTermNotes.entries {
            for lang in [AppLanguage.zh, .zhHant, .en] {
                guard let note = BaziTermNotes.note(for: key, language: lang) else {
                    XCTFail("\(key) \(lang) 无释义")
                    continue
                }
                XCTAssertFalse(note.isEmpty, "\(key) \(lang) 释义为空")
            }
        }
    }

    func test_expectedCoverage_22terms() {
        XCTAssertEqual(BaziTermNotes.entries.count, 22, "词表条数漂移(加术语请同步本断言)")
        let expected = [
            // 十神(10 义 11 键)
            "比肩", "劫财", "食神", "伤官", "偏财", "正财", "七杀", "偏官",
            "正官", "偏印", "正印",
            // 日主
            "日主",
            // 旺衰
            "身强", "身弱", "中和", "从格", "专旺",
            // 五行关系
            "相生", "相克", "同气",
            // 喜忌
            "喜用", "忌神",
        ]
        for k in expected {
            XCTAssertNotNil(BaziTermNotes.entries[k], "词表缺术语 \(k)")
        }
    }

    func test_pianGuan_aliasMatchesQiSha() {
        XCTAssertEqual(BaziTermNotes.entries["偏官"], BaziTermNotes.entries["七杀"],
                       "偏官=七杀别名(对齐 BaziTerms.tenGods),释义必须同文")
    }

    func test_unknownTerm_returnsNil() {
        XCTAssertNil(BaziTermNotes.note(for: "不存在的术语"))
        XCTAssertNil(BaziTermNotes.note(for: ""))
    }

    func test_keys_registeredInBaziTerms() {
        for key in BaziTermNotes.entries.keys {
            XCTAssertNotNil(BaziTerms.index[key],
                            "词表 key 未注册进 BaziTerms(标题会回落原值+日志): \(key)")
        }
    }

    func test_jiShen_note_carriesNotTabooCaveat() {
        // 与 S1 喜忌去绝对化同轨:释义层也必须化解"忌 = 生活禁忌"
        XCTAssertEqual(BaziTermNotes.note(for: "忌神", language: .zh)?.contains("不是生活禁忌"), true)
        XCTAssertEqual(BaziTermNotes.note(for: "忌神", language: .en)?.contains("not things to avoid"), true)
    }
}
