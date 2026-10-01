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

    // MARK: 日主卡

    func test日主_相生_生成方元素在前() {
        let term = CompatibilityRelationDetailBuilder.make(pillars: boardChart).dayMaster
        // A=甲木 B=丁火,木生火(zh 设备;en 变体含 "feeds")
        let isZh = AppLanguage.current.isChinese
        if isZh {
            XCTAssertEqual(term, "甲遇丁 · 木生火")
        } else {
            XCTAssertEqual(term?.contains("feeds"), true)
        }
    }

    func test日主_同气() {
        let chart = boardChart
        let day = pillar(L10n.Compatibility.dualDayPillar,
                         "甲", "寅", "wood", "wood",
                         "乙", "卯", "wood", "wood")
        var mutated = chart
        mutated[2] = day
        let term = CompatibilityRelationDetailBuilder.make(pillars: mutated).dayMaster
        if AppLanguage.current.isChinese {
            XCTAssertEqual(term, "甲遇乙 · 同为木")
        } else {
            XCTAssertEqual(term?.contains("both"), true)
        }
    }

    func test日主_相克_克方元素在前() {
        var mutated = boardChart
        mutated[2] = pillar(L10n.Compatibility.dualDayPillar,
                            "甲", "寅", "wood", "wood",
                            "戊", "辰", "earth", "earth")
        let term = CompatibilityRelationDetailBuilder.make(pillars: mutated).dayMaster
        if AppLanguage.current.isChinese {
            XCTAssertEqual(term, "甲遇戊 · 木克土")
        } else {
            XCTAssertEqual(term?.contains("controls"), true)
        }
    }

    // MARK: 生肖卡

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
            XCTAssertEqual(term?.contains("Partner brings Earth"), true)
            XCTAssertEqual(term?.contains("You bring Wood"), true)
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
        // 全寅×全巳 = 4×4 共 16 对,每对双记为「刑害」(后端只记害,点名层刑害都记)
        XCTAssertEqual(detail.frictionPairs.count, 16)
        XCTAssertTrue(detail.frictionPairs.allSatisfy { $0 == "寅巳刑害" },
                      "16 对全部双记为寅巳刑害,实际:\(detail.frictionPairs)")
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
        // 日主/生肖/年月日支照派;时支对(庚午/辛丑 → 午丑害)不再出现
        if AppLanguage.current.isChinese {
            XCTAssertEqual(detail.dayMaster, "甲遇丁 · 木生火")
        } else {
            XCTAssertEqual(detail.dayMaster?.contains("甲"), true)
            XCTAssertEqual(detail.dayMaster?.contains("feeds"), true)
        }
        XCTAssertEqual(detail.frictionPairs, ["子卯刑", "寅巳刑害"])
    }

    func test空盘_全nil不猜() {
        let detail = CompatibilityRelationDetailBuilder.make(pillars: [])
        XCTAssertNil(detail.dayMaster)
        XCTAssertNil(detail.fiveElements)
        XCTAssertNil(detail.zodiac)
        XCTAssertNil(detail.branch)
        XCTAssertTrue(detail.frictionPairs.isEmpty)
    }
}
