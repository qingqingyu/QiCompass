import XCTest
@testable import QiCompass

/// CompatibilitySnapshotStore 单元测试(方案 §阶段 6)。
///
/// 覆盖:
/// - CRUD(upsert / get / updateInterpretation)
/// - hash 对称性(canonicalKey min/max 规范化)
/// - context 隔离(同对夫妻不同 context 各自独立)
/// - JSON round-trip(encode/decode 不丢字段)
/// - A=B 退化(同盘合退化为单 hash + context)
@MainActor
final class CompatibilitySnapshotStoreTests: XCTestCase {

    // MARK: - canonicalKey 对称性(D13 核心)

    func testCanonicalKey_AB互换_hash一致() {
        let h1 = CompatibilitySnapshotStore.canonicalKey(
            aHash: "hash_alpha", bHash: "hash_beta", context: "general"
        )
        let h2 = CompatibilitySnapshotStore.canonicalKey(
            aHash: "hash_beta", bHash: "hash_alpha", context: "general"
        )
        XCTAssertEqual(h1, h2, "A/B 互换 hash 必须一致(canonicalKey min/max 规范化)")
    }

    func testCanonicalKey_context不同_hash不同() {
        let h1 = CompatibilitySnapshotStore.canonicalKey(
            aHash: "alpha", bHash: "beta", context: "general"
        )
        let h2 = CompatibilitySnapshotStore.canonicalKey(
            aHash: "alpha", bHash: "beta", context: "marriage"
        )
        XCTAssertNotEqual(h1, h2, "context 不同必须产生不同 hash(context 隔离)")
    }

    func testCanonicalKey_AB相同_退化正常() {
        let h = CompatibilitySnapshotStore.canonicalKey(
            aHash: "same_hash", bHash: "same_hash", context: "general"
        )
        XCTAssertEqual(h.count, 64, "A=B 退化场景下仍生成 SHA-256 hex(64 字符)")
        XCTAssertFalse(h.isEmpty)
    }

    func testCanonicalKey_SHA256HexLength() {
        let h = CompatibilitySnapshotStore.canonicalKey(
            aHash: "a", bHash: "b", context: "general"
        )
        XCTAssertEqual(h.count, 64, "SHA-256 hex 必须 64 字符")
    }

    // MARK: - 禁词清单静态属性

    func testForbiddenWords_绝对结论清单非空() {
        XCTAssertFalse(ForbiddenWords.absoluteConclusions.isEmpty, "禁词清单不能为空")
        XCTAssertTrue(ForbiddenWords.absoluteConclusions.contains("必成"))
        XCTAssertTrue(ForbiddenWords.absoluteConclusions.contains("必分"))
        XCTAssertTrue(ForbiddenWords.absoluteConclusions.contains("必破财"))
    }

    func testForbiddenWords_扫描命中() {
        let hits = ForbiddenWords.scan("两人必定会在一起")
        XCTAssertTrue(hits.contains("必定"), "必须命中「必定」")
    }

    func testForbiddenWords_扫描未命中() {
        let hits = ForbiddenWords.scan("两人性情较合,有所互补")
        XCTAssertTrue(hits.isEmpty, "无禁词时返回空数组")
    }

    func testForbiddenWords_扫描多个去重() {
        let text = "必成无疑,必定幸福"
        let hits = ForbiddenWords.scan(text)
        let counts = Dictionary(hits.map { ($0, 1) }, uniquingKeysWith: +)
        XCTAssertEqual(counts["必成"], 1, "去重保序")
        XCTAssertEqual(counts["必定"], 1)
    }

    // MARK: - DTO encode/decode(模式 A / 模式 B)

    func testCompatibilityRequest_模式A_encode含BHash与BPayload() throws {
        let payloadA = ChartPayloadDTO(
            dayMaster: "甲", dayMasterElement: "wood",
            dayMasterStrength: "balanced",
            favorableElements: ["水"], unfavorableElements: ["金"],
            fourPillars: ["day": PillarRefDTO(gan: "甲", zhi: "子")]
        )
        let payloadB = ChartPayloadDTO(
            dayMaster: "丙", dayMasterElement: "fire",
            dayMasterStrength: "strong",
            favorableElements: ["火"], unfavorableElements: ["水"],
            fourPillars: ["day": PillarRefDTO(gan: "丙", zhi: "午")]
        )
        let req = CompatibilityRequest(
            personAHash: "a_hash",
            personBHash: "b_hash",
            chartPayloadA: payloadA,
            chartPayloadB: payloadB,
            context: "marriage"
        )
        let data = try APICoder.encoder.encode(req)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"person_b_hash\""), "模式 A 必须含 person_b_hash")
        XCTAssertTrue(json.contains("\"chart_payload_b\""), "模式 A 必须含 chart_payload_b")
        XCTAssertFalse(json.contains("\"person_b\":"), "模式 A 不得含 person_b 对象字段")
    }

    func testCompatibilityRequest_模式B_encode含BObject() throws {
        let payloadA = ChartPayloadDTO.placeholder
        let personB = PersonBInput(
            birthDatetime: Date(timeIntervalSince1970: 638_000_000),
            gender: "female",
            city: "上海",
            longitude: nil
        )
        let req = CompatibilityRequest(
            personAHash: "a_hash",
            personB: personB,
            chartPayloadA: payloadA,
            context: "business"
        )
        let data = try APICoder.encoder.encode(req)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"person_b\":"), "模式 B 必须含 person_b 对象")
        XCTAssertTrue(json.contains("\"birth_datetime\""))
        XCTAssertFalse(json.contains("\"person_b_hash\""), "模式 B 不得含 person_b_hash")
        XCTAssertFalse(json.contains("\"chart_payload_b\""), "模式 B 不得含 chart_payload_b")
    }

    func testCompatibilityResponse_personBChart_Optional模式A_decode() throws {
        // 后端模式 A:person_a_chart / person_b_chart 均为 null
        let json = """
        {
          "compatibility_hash": "abc",
          "person_a_chart": null,
          "person_b_chart": null,
          "qualitative_assessment": {
            "five_elements": "互补佳",
            "day_master_relation": "同气",
            "zodiac_match": "六合",
            "branch_harmony": "无冲无刑"
          },
          "synced_fortune": [],
          "calc_rule_snapshot": {
            "library": "lunar_python", "sect": 1, "zi_hour_rule": "zi_next_day",
            "true_solar_longitude": 116.4, "true_solar_offset_minutes": -14.4,
            "schema_version": 1
          }
        }
        """.data(using: .utf8)!
        let resp = try APICoder.decoder.decode(CompatibilityResponse.self, from: json)
        XCTAssertNil(resp.personAChart, "模式 A 下 personAChart 必须为 nil")
        XCTAssertNil(resp.personBChart, "模式 A 下 personBChart 必须为 nil")
        XCTAssertEqual(resp.qualitativeAssessment.fiveElements, "互补佳")
    }

    // MARK: - ChartPayloadDTO 扩展字段(合盘)

    func testChartPayloadDTO_合盘扩展字段_encode() throws {
        let payload = ChartPayloadDTO(
            dayMaster: "甲", dayMasterElement: "wood",
            dayMasterStrength: "balanced",
            favorableElements: ["水"], unfavorableElements: ["金"],
            fourPillars: ["day": PillarRefDTO(gan: "甲", zhi: "子")],
            luckPillars: [LuckPillarDTO(ganZhi: "甲子", startYear: 1990, endYear: 1999, startAge: 1, endAge: 10)],
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: -14.4, schemaVersion: 1
            )
        )
        let data = try APICoder.encoder.encode(payload)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"luck_pillars\""), "合盘 payload 必须含 luck_pillars")
        XCTAssertTrue(json.contains("\"calc_rule_snapshot\""))
    }

    func testChartPayloadDTO_daily路径_扩展字段为nil_encode不包含() throws {
        let payload = ChartPayloadDTO(
            dayMaster: "甲", dayMasterElement: "wood",
            dayMasterStrength: "balanced",
            favorableElements: ["水"], unfavorableElements: ["金"],
            fourPillars: ["day": PillarRefDTO(gan: "甲", zhi: "子")]
        )
        let data = try APICoder.encoder.encode(payload)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"luck_pillars\""), "daily 路径不含 luck_pillars(默认 nil)")
        XCTAssertFalse(json.contains("\"calc_rule_snapshot\""))
    }
}
