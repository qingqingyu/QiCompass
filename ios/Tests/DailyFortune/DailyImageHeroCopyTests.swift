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

    /// 宜词不得出现在兜底模板的**告诫半句**——2026-09-28 外评「宜分利 vs 分利慢一拍」。
    /// S6(2026-09-30)起引擎模板五段化(无分号结构),告诫判定改为子句级:
    /// 含告诫标记(别/不/防/避免/省着/慢一拍/少)的子句内不得出现该十神的宜词。
    /// zh / zh-Hant 两表逐键检查;EN 为短语无法子串比对,靠人工 review(见 slices 文档 S01)。
    func testYiItemsNotContradictedByEngineTemplateCaution() {
        let pairs: [([String: (yi: [String], ji: [String])], [String: DailyInsight])] = [
            (HeroYiJiColumns.mappingZh, EngineReadingTemplates.zh),
            (HeroYiJiColumns.mappingHant, EngineReadingTemplates.hant),
        ]
        let cautionMarkers = ["别", "不", "防", "避免", "省着", "慢一拍", "少"]
        for (mapping, templates) in pairs {
            XCTAssertEqual(Set(mapping.keys), Set(templates.keys))
            for (relation, cols) in mapping {
                guard let insight = templates[relation] else { continue }  // 键集合不等已由上方断言报出
                let fullText = [insight.work, insight.relationships, insight.energy, insight.reminder]
                    .joined(separator: ",")
                for clause in fullText.split(whereSeparator: { ",。;；".contains($0) }) {
                    let clauseStr = String(clause)
                    guard cautionMarkers.contains(where: { clauseStr.contains($0) }) else { continue }
                    let hits = cols.yi.filter { clauseStr.contains($0) }
                    XCTAssertTrue(hits.isEmpty, "\(relation) 宜词出现在模板告诫子句「\(clauseStr)」:\(hits)")
                }
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

    // MARK: - D4 EN 基座零汉字(2026-10-01 Today 定稿)

    /// EN 语言下 Today 屏**常驻可见**文本不得出现任何 CJK 字符
    /// (汉字仅两处豁免:hero 落款题款 + 十神释义弹卡,均不在此扫描)。
    /// 覆盖 Swift 静态表与纯函数层:宜忌词表与表头/降级模板(降级正文也常驻
    /// 可见)/农历行转写/页脚拼音段/十神与五行 EN 显示值/干支无调拼音。
    /// 范围外(注释于此防误判):xcstrings 段(Disclaimer / 领域标签等,跟设备
    /// bundle 语言走,en 设备输出拉丁)与系统 DateFormatter(星期/月年,
    /// Locale.current = AppLanguage 前提下 en 设备输出拉丁)。
    func testEnBaseLayerStaticTextsHaveNoCJK() {
        var texts: [String] = []
        // 宜忌表头 + 词表 + 兜底
        texts += ["Do", "Don't"]
        for cols in HeroYiJiColumns.mappingEn.values {
            texts += cols.yi + cols.ji
        }
        let enFallback = HeroYiJiColumns.fallback(for: .en)
        texts += enFallback.yi + enFallback.ji
        // 降级/兜底模板五段(失败态正文常驻可见,同受 D4 约束)
        for insight in EngineReadingTemplates.en.values {
            texts += [insight.headline, insight.work, insight.relationships,
                      insight.energy, insight.reminder]
        }
        let enFallbackInsight = EngineReadingTemplates.fallbackInsight(for: .en)
        texts += [enFallbackInsight.headline, enFallbackInsight.work,
                  enFallbackInsight.relationships, enFallbackInsight.energy,
                  enFallbackInsight.reminder]
        // 十神/五行 EN 显示值
        texts += BaziTerms.tenGods.map { BaziTerms.display($0.zh, language: .en) }
        texts += BaziTerms.fiveElements.map { BaziTerms.display($0.zh, language: .en) }
        // 农历行转写(月名全形状 + 闰月)
        for (lunar, pillar) in [("八月初一", "戊申"), ("腊月廿九", "辛亥"), ("闰六月初十", "丙寅")] {
            if let line = DailyHeaderSection.enLunarLine(lunarDate: lunar, dayPillar: pillar) {
                texts.append(line)
            } else {
                XCTFail("enLunarLine(\(lunar), \(pillar)) 应可转写")
            }
        }
        // 页脚前两段(拼音日柱 + 十神 EN;免责段走 xcstrings 不扫)
        let footnote = DailyFortuneMainView.footnoteText(dayPillar: "戊申", relation: "偏财", language: .en)
        texts.append(String(footnote.components(separatedBy: " · ").prefix(2).joined(separator: " · ")))

        for text in texts {
            XCTAssertNil(
                Self.firstCJKScalar(in: text),
                "EN 基座层出现 CJK(\(String(Self.firstCJKScalar(in: text) ?? " "))):「\(text)」"
            )
        }
    }

    /// 干支无调拼音连字(D4 基座标识层):22 字全可译、无 CJK、无残留声调;
    /// 样例钉死戊申/辛丑;非干支串 nil(不输出半译串)。
    func testRomanizedHyphenAll22StemsAndBranches() {
        XCTAssertEqual(BaziTerms.romanizedHyphen("戊申"), "Wu-Shen")
        XCTAssertEqual(BaziTerms.romanizedHyphen("辛丑"), "Xin-Chou")
        XCTAssertEqual(BaziTerms.romanizedHyphen("甲"), "Jia", "单字也要可转写")
        let all = BaziTerms.heavenlyStems.map(\.zh) + BaziTerms.earthlyBranches.map(\.zh)
        for ch in all {
            let v = BaziTerms.romanizedHyphen(ch)
            XCTAssertNotNil(v, "\(ch) 应可拼音化")
            XCTAssertNil(Self.firstCJKScalar(in: v ?? ""), "\(ch) → \(v ?? "") 含 CJK")
            XCTAssertFalse((v ?? "").contains(" "), "无空格(连字符连接)")
        }
        XCTAssertNil(BaziTerms.romanizedHyphen("甲子木"), "含非干支字符应 nil")
        XCTAssertNil(BaziTerms.romanizedHyphen("偏财"), "非干支术语 nil")
        XCTAssertNil(BaziTerms.romanizedHyphen(""), "空串 nil")
    }

    /// 十神带调拼音表(D6 释义卡教学层):键集合 == BaziTerms.tenGods 的 zh 键,
    /// 值非空且无 CJK(声调符号允许)。
    func testShiShenPinyinTableMatchesTenGodsKeys() {
        XCTAssertEqual(
            Set(HeroShiShenPinyin.table.keys),
            Set(BaziTerms.tenGods.map(\.zh)),
            "新增十神须同步拼音表(与 HeroShiShenNotes 同款守护)"
        )
        for (relation, pinyin) in HeroShiShenPinyin.table {
            XCTAssertFalse(pinyin.isEmpty, "\(relation) 拼音为空")
            XCTAssertNil(Self.firstCJKScalar(in: pinyin), "\(relation) 拼音含 CJK:\(pinyin)")
        }
        XCTAssertEqual(HeroShiShenPinyin.table["偏财"], "piān cái", "mockup 样例")
    }

    /// zh/zh-Hant 回归(D4 验收项):日柱仍显示汉字、宜忌表头仍「宜/忌」、
    /// 页脚仍「戊申日」形态——D4 只动 EN 腿。
    /// 断言的回归点是**日柱汉字戊申原样保留**;「日」后缀与免责段走 xcstrings
    /// 按设备 bundle 语言解析(en 设备为 " Day"/"For reference only"),故
    /// expected 前缀运行时用同一常量拼接——字面量断言在非 zh 设备会假红
    /// (同 testchongLabel_zh回归 先例,2026-09-23 假红教训)。
    func testZhLegsKeepHanziUnderD4() {
        let zhPrefix = "戊申\(L10n.DailyFortune.dayPillarSuffix) · "
        XCTAssertTrue(DailyFortuneMainView.footnoteText(dayPillar: "戊申", relation: "偏财", language: .zh)
            .hasPrefix(zhPrefix))
        // relation 传后端契约键(简体,决策 7)——传繁体会让 display 走 miss
        // 兜底而非 zhHant 路由(键集 = 简体 id)
        XCTAssertTrue(DailyFortuneMainView.footnoteText(dayPillar: "戊申", relation: "偏财", language: .zhHant)
            .hasPrefix(zhPrefix))
        // 词表键仍为后端简体十神(决策 7),zh 表值仍汉字
        XCTAssertTrue(HeroYiJiColumns.mappingZh["偏财"]?.yi.contains("拓展") == true)
    }

    // MARK: D4 断言辅助

    /// 首个 CJK 字符(表意 Han/扩展 A/兼容表意 + CJK 符号标点区),nil = 无。
    private static func firstCJKScalar(in s: String) -> Character? {
        s.first { ch in
            guard let scalar = ch.unicodeScalars.first else { return false }
            return (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x3000...0x303F).contains(scalar.value)
        }
    }
}
