import XCTest
@testable import QiCompass

/// S4 日主方向短语单测(2026-09-29 结果页主页化):
/// - 三种关系(同气 / 相生 / 相克)× A→B、B→A 两个方向
/// - 方向短语:生成/克方在前(对称类别 + 客户端方向派生)
/// - 一致性守卫:派生 ≠ 后端 → text=nil 走后端标签回退(不静默不猜)
/// - 后端标签归一:zh + en(服务端已译)双语;未知标签回退
/// - 输入缺失(日柱歧义盘字段 nil)→ 回退
final class DayMasterRelationPhraseTests: XCTestCase {

    // MARK: - 同气

    func test同气_甲木乙木() {
        let out = DayMasterRelationPhrase.make(
            ganA: "甲", elementA: "wood",
            ganB: "乙", elementB: "wood",
            backendRelation: "同气"
        )
        XCTAssertEqual(out.derived, .sameQi)
        XCTAssertEqual(out.matchesBackend, true)
        XCTAssertNotNil(out.text)
        XCTAssertTrue(out.text?.contains("甲") == true && out.text?.contains("乙") == true,
                      "同气短语含双方日干,实际:\(out.text ?? "nil")")
        XCTAssertFalse(out.text?.contains("相生") == true)
    }

    // MARK: - 相生(A→B / B→A 各一条,方向 = 生成方在前)

    func test相生_A生B_甲木生丙火() {
        // 木生火:A 甲木 → B 丙火,生成方 A 在前
        let out = DayMasterRelationPhrase.make(
            ganA: "甲", elementA: "wood",
            ganB: "丙", elementB: "fire",
            backendRelation: "相生"
        )
        XCTAssertEqual(out.derived, .generates)
        XCTAssertEqual(out.matchesBackend, true)
        // 2026-10-07 去掉「· 关系标签」后缀(类别词归评估卡,一屏不说两遍)
        XCTAssertEqual(out.text, "日主 甲木生丙火")
    }

    func test相生_B生A_方向仍生成方在前() {
        // 火生土...不对——用 木生火 反排:A 丙火,B 甲木(B 生 A)→ 短语仍「甲木生丙火」
        let out = DayMasterRelationPhrase.make(
            ganA: "丙", elementA: "fire",
            ganB: "甲", elementB: "wood",
            backendRelation: "相生"
        )
        XCTAssertEqual(out.derived, .generates)
        XCTAssertEqual(out.matchesBackend, true)
        // 方向客户端派生:B(甲木)是生成方 → 生成方在前,不因 A/B 座次颠倒
        XCTAssertEqual(out.text, "日主 甲木生丙火")
    }

    // MARK: - 相克(A→B / B→A 各一条)

    func test相克_A克B_甲木克戊土() {
        // 木克土:A 甲木 → B 戊土,克方 A 在前
        let out = DayMasterRelationPhrase.make(
            ganA: "甲", elementA: "wood",
            ganB: "戊", elementB: "earth",
            backendRelation: "相克"
        )
        XCTAssertEqual(out.derived, .overcomes)
        XCTAssertEqual(out.matchesBackend, true)
        XCTAssertEqual(out.text, "日主 甲木克戊土")
    }

    func test相克_B克A_方向仍克方在前() {
        // 木克土反排:A 戊土,B 甲木(B 克 A)→ 短语仍「甲木克戊土」
        let out = DayMasterRelationPhrase.make(
            ganA: "戊", elementA: "earth",
            ganB: "甲", elementB: "wood",
            backendRelation: "相克"
        )
        XCTAssertEqual(out.derived, .overcomes)
        XCTAssertEqual(out.matchesBackend, true)
        XCTAssertEqual(out.text, "日主 甲木克戊土")
    }

    // MARK: - 一致性守卫(不等 → 回退后端标签)

    func test守卫_派生与后端不一致_text为nil() {
        // 五行实为相生(木生火),后端标「相克」→ 不静默不猜,回退
        let out = DayMasterRelationPhrase.make(
            ganA: "甲", elementA: "wood",
            ganB: "丙", elementB: "fire",
            backendRelation: "相克"
        )
        XCTAssertEqual(out.derived, .generates, "客户端按五行表如实派生")
        XCTAssertNil(out.text, "不一致 → 不显示派生串(UI 只显后端标签)")
        XCTAssertFalse(out.matchesBackend)
    }

    func test守卫_后端标签未知_回退() {
        let out = DayMasterRelationPhrase.make(
            ganA: "甲", elementA: "wood",
            ganB: "丙", elementB: "fire",
            backendRelation: "未知档位"
        )
        XCTAssertNil(out.text)
        XCTAssertFalse(out.matchesBackend)
    }

    func test守卫_后端EN标签_可归一对齐() {
        // 后端按请求 language 已译(term_translations.py)→ EN 标签可归一。
        // 2026-10-07 起短语不再拼后端标签后缀(EN 界面曾因此漏出「· 相生」),
        // 归一仅作用于一致性守卫——标签语言不影响短语本体
        let out = DayMasterRelationPhrase.make(
            ganA: "甲", elementA: "wood",
            ganB: "丙", elementB: "fire",
            backendRelation: "Generating cycle"
        )
        XCTAssertEqual(out.matchesBackend, true)
        XCTAssertEqual(out.text, "日主 甲木生丙火",
                       "短语本体与后端标签语言无关,实际:\(out.text ?? "nil")")
    }

    // MARK: - 输入缺失(日柱歧义盘字段 nil)

    func test输入缺失_gan为nil_回退() {
        let out = DayMasterRelationPhrase.make(
            ganA: nil, elementA: nil,
            ganB: "甲", elementB: "wood",
            backendRelation: "相生"
        )
        XCTAssertNil(out.derived)
        XCTAssertNil(out.text)
        XCTAssertFalse(out.matchesBackend)
    }

    func test输入缺失_未知五行key_回退() {
        let out = DayMasterRelationPhrase.make(
            ganA: "甲", elementA: "cosmic",
            ganB: "丙", elementB: "fire",
            backendRelation: "相生"
        )
        XCTAssertNil(out.text)
        XCTAssertFalse(out.matchesBackend)
    }
}
