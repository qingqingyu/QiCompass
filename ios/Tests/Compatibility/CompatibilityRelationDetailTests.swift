import XCTest
@testable import QiCompass

/// 合盘评估卡「点名干支」确定性派生单测(BP Match 设计板 #2/#3/#10,2026-10-01)。
///
/// 对盘 ground truth = 设计稿例盘(BP Match.html):
/// A 盘 1984:甲子 / 丁卯 / 甲寅 / 庚午;B 盘 1989-07-06:己巳 / 庚午 / 丁卯 / 辛丑。
/// 设计稿人工推演:合 = 子丑六合、寅午半合;冲 = 子午;刑 = 寅巳、子卯;
/// 且「卯丑冲」是设计稿明确点名要删掉的错例(卯丑无冲)。
///
/// 另:全扫描比设计稿 Note 多出「午丑害」(A 时支午 × B 时支丑,丑午相害,
/// 后端 XIANGHAI 同表)——设计稿 Note 只列了刑,本层如实全列。
final class CompatibilityRelationDetailTests: XCTestCase {

    // MARK: 夹具

    private func pillar(
        _ position: String,
        _ ganA: String, _ zhiA: String, _ ea: String, _ za: String,
        _ ganB: String, _ zhiB: String, _ eb: String, _ zb: String
    ) -> DualPillarSource {
        DualPillarSource(
            position: position,
            ganA: ganA, zhiA: zhiA, nayinA: nil, ganElementA: ea, zhiElementA: za,
            ganB: ganB, zhiB: zhiB, nayinB: nil, ganElementB: eb, zhiElementB: zb
        )
    }

    /// 设计稿例盘(A 1984 甲子/丁卯/甲寅/庚午;B 1989 己巳/庚午/丁卯/辛丑)。
    private var boardChart: [DualPillarSource] {
        [
            pillar(L10n.Compatibility.dualYearPillar,
                   "甲", "子", "wood", "water",
                   "己", "巳", "earth", "fire"),
            pillar(L10n.Compatibility.dualMonthPillar,
                   "丁", "卯", "fire", "wood",
                   "庚", "午", "metal", "fire"),
            pillar(L10n.Compatibility.dualDayPillar,
                   "甲", "寅", "wood", "wood",
                   "丁", "卯", "fire", "wood"),
            pillar(L10n.Compatibility.dualHourPillar,
                   "庚", "午", "metal", "fire",
                   "辛", "丑", "metal", "earth"),
        ]
    }

    // MARK: 生肖卡
    // (日主卡点名已删,2026-10-07:方向短语归双盘中轴独占,评估卡回落枚举——
    //  一屏不说两遍;方向派生见 DayMasterRelationPhraseTests)

    func test生肖_年支动物() {
        let term = CompatibilityRelationDetailBuilder.make(pillars: boardChart).zodiac
        if AppLanguage.current.isChinese {
            XCTAssertEqual(term, "鼠 · 蛇")
        } else {
            XCTAssertEqual(term, "Rat · Snake")
        }
    }

    // MARK: 五行卡

    func test五行_计数差() {
        // A:木4 水1 火2 金1 土0;B:火3 金2 土2 木1 水0
        // 差 ≥2:B 土 +2、A 木 +3(zh:「对方多 土 · 你多 木」)
        let term = CompatibilityRelationDetailBuilder.make(pillars: boardChart).fiveElements
        if AppLanguage.current.isChinese {
            XCTAssertEqual(term, "对方多 土 · 你多 木")
        } else {
            // 2026-10-07 措辞修正:"brings" 读作"对方是土命"(与右侧丁火日主打架),
            // 改 "has more" 纯盘面字数陈述
            XCTAssertEqual(term?.contains("Partner has more Earth"), true)
            XCTAssertEqual(term?.contains("You have more Wood"), true)
        }
    }

    func test五行_多元素差_zh连排en分隔() {
        // A:木4 火4 土0 金0 水0;B:土4 金4 木0 火0 水0 → 双侧各两元素差 ≥2
        let chart: [DualPillarSource] = [
            pillar(L10n.Compatibility.dualYearPillar,
                   "甲", "寅", "wood", "wood",
                   "戊", "辰", "earth", "earth"),
            pillar(L10n.Compatibility.dualMonthPillar,
                   "甲", "寅", "wood", "wood",
                   "戊", "辰", "earth", "earth"),
            pillar(L10n.Compatibility.dualDayPillar,
                   "丙", "午", "fire", "fire",
                   "庚", "申", "metal", "metal"),
            pillar(L10n.Compatibility.dualHourPillar,
                   "丙", "午", "fire", "fire",
                   "庚", "申", "metal", "metal"),
        ]
        let term = CompatibilityRelationDetailBuilder.make(pillars: chart).fiveElements
        if AppLanguage.current.isChinese {
            // zh 单字连排;顺序固定 B 侧先(对方多)· A 侧后(你多),
            // 元素序 = ElementColors.allCases(木火土金水)
            XCTAssertEqual(term, "对方多 土金 · 你多 木火")
        } else {
            // en 侧分隔符必须有,否则连成 "EarthMetal"(2026-10-01 review 修复)
            XCTAssertEqual(term?.contains("Earth, Metal"), true)
            XCTAssertEqual(term?.contains("Wood, Fire"), true)
        }
    }

    func test五行_无显著差_nil() {
        // 两侧同构盘 → 无 ≥2 差异
        let samey = boardChart.map { p in
            pillar(p.position,
                   p.ganA ?? "", p.zhiA ?? "", p.ganElementA ?? "", p.zhiElementA ?? "",
                   p.ganA ?? "", p.zhiA ?? "", p.ganElementA ?? "", p.zhiElementA ?? "")
        }
        XCTAssertNil(CompatibilityRelationDetailBuilder.make(pillars: samey).fiveElements)
    }

    // MARK: 地支卡(核心对盘)

    func test地支_设计稿例盘_全关系有序列出() {
        let detail = CompatibilityRelationDetailBuilder.make(pillars: boardChart)
        // 同 rank 平局按扫描序(A 年→时 × B 年→时):子卯刑先于寅巳刑害
        if AppLanguage.current.isChinese {
            XCTAssertEqual(
                detail.branch,
                "子丑合 · 寅午半合 · 子午冲 · 子卯刑 · 寅巳刑害 · 午丑害"
            )
            XCTAssertEqual(detail.frictionPairs, ["子卯刑", "寅巳刑害", "午丑害"])
        } else {
            // 关系后缀是干支术语族(zh 字),en 设备同串
            XCTAssertEqual(
                detail.branch,
                "子丑合 · 寅午半合 · 子午冲 · 子卯刑 · 寅巳刑害 · 午丑害"
            )
        }
    }

    func test地支_卯丑无冲_设计稿错例不得出现() {
        let branch = CompatibilityRelationDetailBuilder.make(pillars: boardChart).branch ?? ""
        XCTAssertFalse(branch.contains("卯丑冲"), "卯丑无冲(六冲表无此对);设计稿点名删除的错例")
        XCTAssertFalse(branch.contains("丑卯冲"))
    }

    func test地支_同支跳过_无关系盘为nil() {
        // A 全子、B 全子:同支全部跳过 → 无任何关系
        let zis = ["子", "子", "子", "子"]
        let chart: [DualPillarSource] = [
            L10n.Compatibility.dualYearPillar,
            L10n.Compatibility.dualMonthPillar,
            L10n.Compatibility.dualDayPillar,
            L10n.Compatibility.dualHourPillar,
        ].enumerated().map { idx, pos in
            pillar(pos,
                   "甲", zis[idx], "wood", "water",
                   "甲", zis[idx], "wood", "water")
        }
        let detail = CompatibilityRelationDetailBuilder.make(pillars: chart)
        XCTAssertNil(detail.branch)
        XCTAssertTrue(detail.frictionPairs.isEmpty)
    }

    func test地支_寅巳双属性_刑害都记() {
        // 后端计数把寅巳记「害」(先命中先计);点名层如实双记「刑害」
        let chart: [DualPillarSource] = [
            pillar(L10n.Compatibility.dualYearPillar,
                   "甲", "寅", "wood", "wood",
                   "己", "巳", "earth", "fire"),
            pillar(L10n.Compatibility.dualMonthPillar,
                   "甲", "寅", "wood", "wood",
                   "己", "巳", "earth", "fire"),
            pillar(L10n.Compatibility.dualDayPillar,
                   "甲", "寅", "wood", "wood",
                   "己", "巳", "earth", "fire"),
            pillar(L10n.Compatibility.dualHourPillar,
                   "甲", "寅", "wood", "wood",
                   "己", "巳", "earth", "fire"),
        ]
        let detail = CompatibilityRelationDetailBuilder.make(pillars: chart)
        // 全寅×全巳 = 4×4 共 16 对,每对双记为「刑害」(后端只记害,点名层刑害都记);
        // 展示按文本去重(2026-10-01 review):重复柱位同关系只列一次
        XCTAssertEqual(detail.branch, "寅巳刑害")
        XCTAssertEqual(detail.frictionPairs, ["寅巳刑害"])
    }

    func test地支_重复柱位同关系_去重只列一次() {
        // A 年支/日支均子、B 年支+时支均丑(boardChart 时柱原有辛丑)
        // →「子丑合」在 4×4 扫描命中 2×2=4 次,展示只列 1 次
        var chart = boardChart
        chart[0] = pillar(L10n.Compatibility.dualYearPillar,
                          "甲", "子", "wood", "water",
                          "己", "丑", "earth", "earth")
        chart[2] = pillar(L10n.Compatibility.dualDayPillar,
                          "甲", "子", "wood", "water",
                          "丁", "巳", "fire", "fire")
        let detail = CompatibilityRelationDetailBuilder.make(pillars: chart)
        XCTAssertEqual(detail.branch?.components(separatedBy: " · ").filter { $0 == "子丑合" }.count, 1,
                      "同关系多柱位只列一次,实际:\(detail.branch ?? "")")
    }

    // MARK: 缺字段回落(时辰未知 / 老盘)

    func test时柱缺失_不崩_其余照派() {
        var chart = boardChart
        chart[3] = DualPillarSource(
            position: L10n.Compatibility.dualHourPillar,
            ganA: nil, zhiA: nil, nayinA: nil, ganElementA: nil, zhiElementA: nil,
            ganB: nil, zhiB: nil, nayinB: nil, ganElementB: nil, zhiElementB: nil
        )
        let detail = CompatibilityRelationDetailBuilder.make(pillars: chart)
        // 生肖/年月日支照派;时支对(庚午/辛丑 → 午丑害)不再出现
        XCTAssertEqual(detail.frictionPairs, ["子卯刑", "寅巳刑害"])
    }

    func test空盘_全nil不猜() {
        let detail = CompatibilityRelationDetailBuilder.make(pillars: [])
        XCTAssertNil(detail.fiveElements)
        XCTAssertNil(detail.zodiac)
        XCTAssertNil(detail.branch)
        XCTAssertTrue(detail.frictionPairs.isEmpty)
    }

    // MARK: 五行分布计数(BP #4,ElementBalanceSection.Model)

    func test五行计数_设计稿例盘() {
        // A 甲子/丁卯/甲寅/庚午:木4 火2 土0 金1 水1
        // B 己巳/庚午/丁卯/辛丑:木1 火3 土2 金2 水0
        let model = ElementBalanceSection.Model.make(pillars: boardChart)
        XCTAssertFalse(model.hourUnknown)
        let byElement = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.element, ($0.countA, $0.countB)) })
        XCTAssertEqual(byElement[.wood]?.0, 4)
        XCTAssertEqual(byElement[.wood]?.1, 1)
        XCTAssertEqual(byElement[.fire]?.0, 2)
        XCTAssertEqual(byElement[.fire]?.1, 3)
        XCTAssertEqual(byElement[.earth]?.0, 0)
        XCTAssertEqual(byElement[.earth]?.1, 2)
        XCTAssertEqual(byElement[.metal]?.0, 1)
        XCTAssertEqual(byElement[.metal]?.1, 2)
        XCTAssertEqual(byElement[.water]?.0, 1)
        XCTAssertEqual(byElement[.water]?.1, 0)
        XCTAssertEqual(model.rows.count, 5, "五行五行全列(含 0 计数行,不隐藏)")
    }

    func test五行计数_时柱未知_按6字计_脚注置位() {
        var chart = boardChart
        chart[3] = DualPillarSource(
            position: L10n.Compatibility.dualHourPillar,
            ganA: nil, zhiA: nil, nayinA: nil, ganElementA: nil, zhiElementA: nil,
            ganB: nil, zhiB: nil, nayinB: nil, ganElementB: nil, zhiElementB: nil
        )
        let model = ElementBalanceSection.Model.make(pillars: chart)
        XCTAssertTrue(model.hourUnknown)
        // A 时柱庚午(金1 火1)缺失 → 木4 火1 土0 金0 水1
        let byElement = Dictionary(uniqueKeysWithValues: model.rows.map { ($0.element, ($0.countA, $0.countB)) })
        XCTAssertEqual(byElement[.wood]?.0, 4)
        XCTAssertEqual(byElement[.fire]?.0, 1)
        XCTAssertEqual(byElement[.metal]?.0, 0)
        // B 时柱辛丑(金1 土1)缺失 → 木1 火3 土1 金1 水0
        XCTAssertEqual(byElement[.earth]?.1, 1)
        XCTAssertEqual(byElement[.metal]?.1, 1)
    }

    // MARK: 同步四态符号(BP #5,SyncedFortuneTable.SyncMark)

    func test同步符号_四态映射与未知回落() {
        XCTAssertEqual(SyncedFortuneTable.SyncMark.syncMark(for: "同步走强")?.glyph, "●")
        XCTAssertEqual(SyncedFortuneTable.SyncMark.syncMark(for: "同步承压")?.glyph, "○")
        XCTAssertEqual(SyncedFortuneTable.SyncMark.syncMark(for: "运势分化")?.glyph, "◐")
        XCTAssertEqual(SyncedFortuneTable.SyncMark.syncMark(for: "难以定性")?.glyph, "—")
        // 未知标签(后端未来结构化/en 化)→ nil 无符号纯文字,前向兼容
        XCTAssertNil(SyncedFortuneTable.SyncMark.syncMark(for: "In sync"))
        XCTAssertNil(SyncedFortuneTable.SyncMark.syncMark(for: ""))
    }

    // MARK: 刑害提示行按合冲标签分档(2026-10-07 判定序修复配套)

    func test刑害提示_多刑多害_重语气变体_与卡解释同调() {
        let note = AssessmentCardGrid.frictionNote(
            branchHarmony: "多刑多害", pairs: ["子卯刑", "寅巳刑害", "午丑害"]
        )
        if AppLanguage.current.isChinese {
            // 重档:与卡解释「刑害偏多,近距离相处消耗较大」同调,不再「小事上」轻描
            // (isChinese 含 zh-Hant,轻语气短语双体并检防繁体环境假红)
            XCTAssertTrue(note.contains("消耗偏大"), "实际:\(note)")
            XCTAssertFalse(
                note.contains("习惯与小事") || note.contains("習慣與小事"),
                "多刑多害不得沿用轻语气,实际:\(note)"
            )
        } else {
            XCTAssertTrue(note.contains("Friction runs high"), "实际:\(note)")
            XCTAssertFalse(note.contains("habits and small things"), "实际:\(note)")
        }
        // 刑害点名照常注入
        XCTAssertTrue(note.contains("子卯刑") && note.contains("午丑害"), "实际:\(note)")
    }

    func test刑害提示_其余标签_保留轻语气() {
        // 略有冲刑害 / 多合少冲(带零星刑害)的卡解释本就轻语气,提示行保持原句
        for label in ["略有冲刑害", "多合少冲", "一冲一合"] {
            let note = AssessmentCardGrid.frictionNote(branchHarmony: label, pairs: ["子卯刑"])
            if AppLanguage.current.isChinese {
                // zh-Hant 同句异体(習慣與小事),双体并检
                XCTAssertTrue(
                    note.contains("习惯与小事") || note.contains("習慣與小事"),
                    "\(label) 实际:\(note)"
                )
                XCTAssertFalse(note.contains("消耗偏大"), "\(label) 实际:\(note)")
            } else {
                XCTAssertTrue(note.contains("habits and small things"), "\(label) 实际:\(note)")
                XCTAssertFalse(note.contains("Friction runs high"), "\(label) 实际:\(note)")
            }
        }
    }
}
