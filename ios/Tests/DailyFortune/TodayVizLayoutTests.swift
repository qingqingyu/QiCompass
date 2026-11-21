import XCTest

@testable import QiCompass

/// 2026-11-21 今日 tab 改版(数字对开 + 气泡场)纯逻辑守护。
/// 设计事实源 docs/design-ref/wuxing-styles/11-merged.html;旧五行条
/// 判定序语义(dominant/borrow)在此延续钉死。
final class TodayVizLayoutTests: XCTestCase {

    // MARK: - TodayStrengthDuel

    /// hi/lo 选取 + 信号方向挂接(值对齐后端 2026-10-24 真值口径:辛未/戌月)。
    func testDuel_hiLoWithSignal() {
        let duel = TodayStrengthDuel.make(
            strength: ["木": 8, "火": 33, "土": 100, "金": 67, "水": 0],
            daySignal: [
                DaySignalItemDTO(element: "土", direction: "up"),
                DaySignalItemDTO(element: "金", direction: "up"),
                DaySignalItemDTO(element: "金", direction: "up"),  // 去重由 Ranked 承担
            ]
        )
        XCTAssertNotNil(duel)
        XCTAssertEqual(duel?.hi.element, "土")
        XCTAssertEqual(duel?.hi.value, 100)
        XCTAssertEqual(duel?.hi.signal, "up")
        // lo 含 0 值行(「今日无此行」是事实,诚实呈现)
        XCTAssertEqual(duel?.lo.element, "水")
        XCTAssertEqual(duel?.lo.value, 0)
        XCTAssertNil(duel?.lo.signal)
    }

    /// guard:有效键 <2 / 全值相等 / 全 0 → nil(宿主连气泡场一起隐藏)。
    func testDuel_guards() {
        XCTAssertNil(TodayStrengthDuel.make(strength: ["木": 50], daySignal: nil),
                     "单键无对比")
        XCTAssertNil(TodayStrengthDuel.make(strength: ["木": 60, "火": 60], daySignal: nil),
                     "全值相等无峰谷")
        XCTAssertNil(TodayStrengthDuel.make(
            strength: ["木": 0, "火": 0, "土": 0, "金": 0, "水": 0], daySignal: nil),
            "全零")
    }

    /// 并列最高取显示序首(确定性,不随 dict 序漂);并列最低取显示序**末位**
    /// (ranked.last 的既定产物——全序列按「值 desc → 显示序 asc」排定,
    /// 最低并列组内显示序最后的落在末位;两端确定性皆有,语义上不偏袒)。
    func testDuel_tieTakesDisplayOrderFirst() {
        let duel = TodayStrengthDuel.make(
            strength: ["木": 100, "火": 0, "土": 100, "金": 0, "水": 0],
            daySignal: nil)
        XCTAssertEqual(duel?.hi.element, "木")
        XCTAssertEqual(duel?.lo.element, "水", "并列最低取显示序末位(ranked.last)")
    }

    /// 标签降级:day_signal 未命中 → 前缀 nil(纯事实「今日最旺/最弱」,
    /// 不编喜忌语义);命中 → 方向前缀。三语各钉一形。
    func testDuel_tagDegradation() {
        let noSignal = TodayStrengthDuel.Side(element: "土", value: 100, signal: nil)
        let (p0, b0) = TodayStrengthDuel.tag(for: noSignal, isHi: true)
        XCTAssertNil(p0)
        XCTAssertEqual(b0, "今日最旺")

        let up = TodayStrengthDuel.Side(element: "土", value: 100, signal: "up")
        let (p1, b1) = TodayStrengthDuel.tag(for: up, isHi: true, language: .zh)
        XCTAssertEqual(p1, "喜用 · ")
        XCTAssertEqual(b1, "今日最旺")

        let down = TodayStrengthDuel.Side(element: "火", value: 35, signal: "down")
        let (p2, b2) = TodayStrengthDuel.tag(for: down, isHi: false, language: .en)
        XCTAssertEqual(p2, "Unfavorable · ")
        XCTAssertEqual(b2, "Weakest today")
    }

    /// 小注干支字匹配:干优先于支;都不匹配降级只显十神;EN 零汉字。
    func testDuel_subnoteCharMatch() {
        let water = TodayStrengthDuel.Side(element: "水", value: 100, signal: "up")
        XCTAssertEqual(
            TodayStrengthDuel.subnote(for: water, isHi: true, dayPillar: "丙子",
                                      dayRelation: "食神", language: .zh),
            "子水食神入命")
        let fire = TodayStrengthDuel.Side(element: "火", value: 35, signal: "down")
        XCTAssertEqual(
            TodayStrengthDuel.subnote(for: fire, isHi: false, dayPillar: "丙子",
                                      dayRelation: "食神", language: .zh),
            "丙火食神泄力")
        // 干支都不匹配(土)→ 只显十神,不猜
        let earth = TodayStrengthDuel.Side(element: "土", value: 52, signal: nil)
        XCTAssertEqual(
            TodayStrengthDuel.subnote(for: earth, isHi: true, dayPillar: "丙子",
                                      dayRelation: "食神", language: .zh),
            "食神主事")
        // EN:干支字拼音连字 + 意译十神,零汉字
        let en = TodayStrengthDuel.subnote(for: water, isHi: true, dayPillar: "丙子",
                                           dayRelation: "食神", language: .en)
        XCTAssertEqual(en, "Zi Water · Eating God presides")
        XCTAssertNil(Self.firstCJKScalar(in: en))
    }

    // MARK: - TodayBubbleLayout

    /// 直径锚点:35→64 / 100→150(mockup 两点),clamp [44,150](0 值淡影圆)。
    func testBubbleDiameterAnchors() {
        XCTAssertEqual(TodayBubbleLayout.diameter(for: 35), 64, accuracy: 0.6)
        XCTAssertEqual(TodayBubbleLayout.diameter(for: 100), 150, accuracy: 0.2)
        XCTAssertEqual(TodayBubbleLayout.diameter(for: 0), 44)
        XCTAssertEqual(TodayBubbleLayout.diameter(for: 1000), 150, "上钳")
        XCTAssertEqual(TodayBubbleLayout.diameter(for: -5), 44, "下钳")
    }

    /// 排名 → 槽位:最大者顶位(rank 0);并列沿显示序;信号挂接。
    func testBubbleRankSlots() {
        let bubbles = TodayBubbleLayout.make(
            strength: ["木": 8, "火": 33, "土": 100, "金": 67, "水": 0],
            daySignal: [DaySignalItemDTO(element: "土", direction: "up")]
        )
        XCTAssertEqual(bubbles.count, 5)
        XCTAssertEqual(bubbles[0].element, "土")
        XCTAssertEqual(bubbles[0].center, TodayBubbleLayout.slotCenters[0])
        XCTAssertEqual(bubbles[0].signal, "up")
        XCTAssertEqual(bubbles[4].element, "水", "最小值(0)落末槽")
        XCTAssertNil(bubbles[4].signal, "day_signal 未命中 → 无标(不编喜忌语义)")
        // 槽位互不重叠锚定:顶部主位 x 居中
        XCTAssertEqual(TodayBubbleLayout.slotCenters[0].x, 191)
    }

    /// 同 rank 值并列:木/土并列 100 → 木先(显示序),土落 rank 1 槽。
    func testBubbleTieKeepsDeterministicOrder() {
        let bubbles = TodayBubbleLayout.make(
            strength: ["木": 100, "火": 0, "土": 100, "金": 0, "水": 0],
            daySignal: nil)
        XCTAssertEqual(bubbles[0].element, "木")
        XCTAssertEqual(bubbles[1].element, "土")
    }

    // MARK: - HourRelationShort / 静态三语表

    /// 键集合 == BaziTerms.tenGods zh 键(11,含偏官);zh/hant 两表键一致。
    func testHourRelationShortKeysMatchTenGods() {
        let expected = Set(BaziTerms.tenGods.map(\.zh))
        XCTAssertEqual(Set(HourRelationShort.zh.keys), expected,
                       "新增十神须同步时辰谱短词表(与 HeroShiShenNotes 同款守护)")
        XCTAssertEqual(Set(HourRelationShort.zh.keys), Set(HourRelationShort.hant.keys),
                       "zh/hant 表键必须一致(键为后端简体十神,决策 7)")
        // 未知键 → nil(调用方省略短词,不静默猜)
        XCTAssertNil(HourRelationShort.short("未知星"))
        XCTAssertEqual(HourRelationShort.short("食神"), "食")
        XCTAssertEqual(HourRelationShort.short("伤官", language: .zhHant), "傷")
    }

    /// 信号建议 EN 零汉字(D4 基座纪律延续)。
    func testSignalAdviceEnNoCJK() {
        for isUp in [true, false] {
            let en = TodaySignalAdvice.text(isUp: isUp, language: .en)
            XCTAssertNil(Self.firstCJKScalar(in: en), en)
        }
    }

    /// 底部三栏未知关系 → fallback + 不崩(防御路径)。
    func testBottomColumnsUnknownRelationFallsBack() {
        let pair = TodayBottomColumnsSection.yiJiPair("不存在的星")
        XCTAssertFalse(pair.yi.isEmpty)
        XCTAssertFalse(pair.ji.isEmpty)
    }

    // MARK: 辅助

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
