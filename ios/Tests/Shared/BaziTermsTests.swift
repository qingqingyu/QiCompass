import XCTest
@testable import QiCompass

/// BaziTerms(L3 命盘术语三语表)单测——展示层语言交接 U3d 验收项:
/// 三语键集合相等 / 未注册 key 的显式回落行为 / 干支带调拼音转写。
/// 键集合与后端 term_translations.py 的对齐由 `tools/check_term_sync.py`
/// 机器比对(本测试只锁 Swift 侧不变量,不重复后端事实源)。
final class BaziTermsTests: XCTestCase {

    // MARK: - 表规模(键序与后端对齐的量的断言)

    func testTableSizes() {
        XCTAssertEqual(BaziTerms.heavenlyStems.count, 10, "天干 10")
        XCTAssertEqual(BaziTerms.earthlyBranches.count, 12, "地支 12")
        XCTAssertEqual(BaziTerms.fiveElements.count, 5, "五行 5")
        XCTAssertEqual(BaziTerms.tenGods.count, 11, "十神 11(含偏官/七杀同义)")
        XCTAssertEqual(BaziTerms.shensha.count, 20, "神煞 20(11 吉 + 9 凶)")
        XCTAssertEqual(BaziTerms.nayin.count, 30, "纳音 30")
        XCTAssertEqual(BaziTerms.twelveStages.count, 12, "十二长生 12")
        XCTAssertEqual(BaziTerms.romanization.count, 22, "干支转写 22")
    }

    func testShenshaPolarityAligned() {
        // ShenshaChips.ShenshaPolarity 的吉煞集合键必须是 BaziTerms 神煞键的子集
        // (展示查表按 zh 稳定 id,吉凶判定同键)
        for name in BaziTerms.shensha.map(\.zh) {
            _ = ShenshaPolarity.isAuspicious(name)  // 不炸即可;键对齐由下面双向断言锁
        }
        let polarityKeys = ["天乙贵人", "太极贵人", "文昌", "天德", "月德",
                            "驿马", "桃花", "将星", "华盖", "金舆", "禄神"]
        let shenshaKeys = Set(BaziTerms.shensha.map(\.zh))
        for key in polarityKeys {
            XCTAssertTrue(shenshaKeys.contains(key), "吉神 \(key) 应在神煞表内")
        }
        // 11 吉 + 9 凶的划分事实源在后端 AUSPICIOUS;此处锁键序前 11 为吉
        XCTAssertEqual(Array(BaziTerms.shensha.map(\.zh).prefix(11)), polarityKeys,
                       "神煞表键序应与后端 SHENSHA_NAMES 一致(前 11 吉神)")
    }

    // MARK: - 三语键集合相等(每条 zh/zhHant/en 非空、zh 即键、跨表无冲突)

    func testThreeLanguageCompleteness() {
        let allTables: [(String, [BaziTerms.Term])] = [
            ("heavenlyStems", BaziTerms.heavenlyStems),
            ("earthlyBranches", BaziTerms.earthlyBranches),
            ("fiveElements", BaziTerms.fiveElements),
            ("tenGods", BaziTerms.tenGods),
            ("misc", BaziTerms.misc),
            ("shensha", BaziTerms.shensha),
            ("nayin", BaziTerms.nayin),
            ("twelveStages", BaziTerms.twelveStages),
            ("strengthLabels", BaziTerms.strengthLabels),
            ("pillarPositions", BaziTerms.pillarPositions),
            ("xijiMethods", BaziTerms.xijiMethods),
        ]
        var seen: Set<String> = []
        for (name, table) in allTables {
            for term in table {
                XCTAssertFalse(term.zh.isEmpty, "\(name) 存在空 zh")
                XCTAssertFalse(term.zhHant.isEmpty, "\(name).\(term.zh) 存在空 zhHant")
                XCTAssertFalse(term.en.isEmpty, "\(name).\(term.zh) 存在空 en")
                XCTAssertEqual(BaziTerms.index[term.zh]?.zh, term.zh,
                               "\(name).\(term.zh) 应可经 index 以 zh 为键查回自身")
                XCTAssertFalse(seen.contains(term.zh),
                               "跨表键冲突:\(term.zh) 出现在多张表")
                seen.insert(term.zh)
            }
        }
        XCTAssertEqual(seen.count, allTables.reduce(0) { $0 + $1.1.count },
                       "融合索引键数应等于各表条目总和(无冲突即无覆盖)")
    }

    // MARK: - display 三语取值(显式 language 参数,不依赖设备语言)

    func testDisplayPerLanguage() {
        XCTAssertEqual(BaziTerms.display("七杀", language: .zh), "七杀")
        XCTAssertEqual(BaziTerms.display("七杀", language: .zhHant), "七殺")
        XCTAssertEqual(BaziTerms.display("七杀", language: .en), "Seven Killings")
        // 同义键偏官:zh-hant 同形,en 同值(对齐后端 TEN_GODS_EN)
        XCTAssertEqual(BaziTerms.display("偏官", language: .zhHant), "偏官")
        XCTAssertEqual(BaziTerms.display("偏官", language: .en), "Seven Killings")
        // 干支:三语均汉字主标(§3 有意行为)
        XCTAssertEqual(BaziTerms.display("甲", language: .en), "甲")
        XCTAssertEqual(BaziTerms.display("甲", language: .zhHant), "甲")
        // 五行/旺衰/UI 词汇
        XCTAssertEqual(BaziTerms.display("木", language: .en), "Wood")
        XCTAssertEqual(BaziTerms.display("身弱", language: .zhHant), "身弱")
        XCTAssertEqual(BaziTerms.display("身弱", language: .en), "Weak")
        XCTAssertEqual(BaziTerms.display("从格特征", language: .zhHant), "從格特徵")
        // 日主(misc)
        XCTAssertEqual(BaziTerms.display("日主", language: .en), "Day Master")
    }

    func testShenshaChipTextEnHasHanziAnnotation() {
        // §3:神煞 en = 意译 + 汉字括注(括注用繁体形)
        XCTAssertEqual(BaziTerms.shenshaChipText("天乙贵人", language: .en),
                       "Nobleman (天乙貴人)")
        XCTAssertEqual(BaziTerms.shenshaChipText("天乙贵人", language: .zh), "天乙贵人")
        XCTAssertEqual(BaziTerms.shenshaChipText("天乙贵人", language: .zhHant), "天乙貴人")
        XCTAssertEqual(BaziTerms.shenshaChipText("天罗地网", language: .en),
                       "Heaven Net, Earth Snare (天羅地網)")
    }

    // MARK: - 未注册 key 的显式回落(不静默吞:回落原值,日志在 AppLogger)

    func testUnregisteredKeyFallsBackToRaw() {
        let unknowns = ["不存在的术语", "七殺", "Wood", ""]
        for unknown in unknowns {
            XCTAssertEqual(BaziTerms.display(unknown, language: .en), unknown,
                           "未注册 key 应显式回落原值(繁体键/英文值不在 zh 键域)")
            XCTAssertEqual(BaziTerms.display(unknown, language: .zh), unknown)
            XCTAssertEqual(BaziTerms.shenshaChipText(unknown, language: .en), unknown,
                           "神煞入口同样回落原值")
        }
    }

    // MARK: - 干支带调拼音转写

    func testRomanized() {
        XCTAssertEqual(BaziTerms.romanized("甲子"), "Jiǎ Zǐ")
        XCTAssertEqual(BaziTerms.romanized("庚午"), "Gēng Wǔ")
        XCTAssertEqual(BaziTerms.romanized("癸"), "Guǐ", "单字也要可转写")
        XCTAssertEqual(BaziTerms.romanized("戌亥"), "Xū Hài", "地支对(旬空值)")
        XCTAssertNil(BaziTerms.romanized("甲子木"), "含非干支字符应返回 nil(不输出半译串)")
        XCTAssertNil(BaziTerms.romanized(""), "空串 nil")
        XCTAssertNil(BaziTerms.romanized("七杀"), "非干支术语 nil")
    }

    func testRomanizationKeysEqualGanzhiUnion() {
        let union = Set(BaziTerms.heavenlyStems.map(\.zh))
            .union(BaziTerms.earthlyBranches.map(\.zh))
        XCTAssertEqual(Set(BaziTerms.romanization.keys), union,
                       "转写表键集合应恰为干支并集(与 check_term_sync ② 同口径)")
    }
}
