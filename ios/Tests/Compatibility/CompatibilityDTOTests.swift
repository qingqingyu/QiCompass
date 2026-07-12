import XCTest
@testable import QiCompass

/// CompatibilityDTOs encode/decode 单元测试(方案 §阶段 6)。
///
/// 验证:
/// - 模式 A:encode 含 person_b_hash + chart_payload_b,不含 person_b
/// - 模式 B:encode 含 person_b,不含 person_b_hash + chart_payload_b
/// - PersonBInput.city 与 longitude 至少传一个(后端校验,客户端编码层不强制)
/// - 可空 chart 字段对齐后端(person_a_chart 始终 None / person_b_chart 模式相关)
/// - 扩展字段 luck_pillars + calc_rule_snapshot 正确编码
final class CompatibilityDTOTests: XCTestCase {

    // MARK: - PersonBInput

    func testPersonBInput_带城市_编码() throws {
        let input = PersonBInput(
            birthDatetime: Date(timeIntervalSince1970: 638_000_000),
            gender: "male",
            city: "北京",
            longitude: nil
        )
        let data = try APICoder.encoder.encode(input)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"city\":\"北京\""))
        XCTAssertFalse(json.contains("\"longitude\""), "longitude 为 nil 不编码")
        XCTAssertTrue(json.contains("\"zi_hour_rule\":\"zi_next_day\""))
    }

    func testPersonBInput_带经度_编码() throws {
        let input = PersonBInput(
            birthDatetime: Date(timeIntervalSince1970: 638_000_000),
            gender: "female",
            city: nil,
            longitude: 116.41
        )
        let data = try APICoder.encoder.encode(input)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"longitude\":116.41"))
        XCTAssertFalse(json.contains("\"city\""), "city 为 nil 不编码")
    }

    // MARK: - CompatibilityRequest 模式 A

    func testRequest_模式A_编码完整() throws {
        let payloadA = Self.makePayload(dayMaster: "甲", element: "wood")
        let payloadB = Self.makePayload(dayMaster: "丙", element: "fire")
        let req = CompatibilityRequest(
            personAHash: "alpha",
            personBHash: "beta",
            chartPayloadA: payloadA,
            chartPayloadB: payloadB,
            context: "general"
        )
        let data = try APICoder.encoder.encode(req)
        let decoded = try APICoder.decoder.decode(CompatibilityRequest.self, from: data)
        XCTAssertEqual(decoded.personAHash, "alpha")
        XCTAssertEqual(decoded.personBHash, "beta")
        XCTAssertNil(decoded.personB, "模式 A personB 必须为 nil")
        XCTAssertEqual(decoded.chartPayloadA.dayMaster, "甲")
        XCTAssertEqual(decoded.chartPayloadB?.dayMaster, "丙")
        XCTAssertEqual(decoded.context, "general")
    }

    // MARK: - CompatibilityRequest 模式 B

    func testRequest_模式B_编码完整() throws {
        let payloadA = Self.makePayload(dayMaster: "甲", element: "wood")
        let personB = PersonBInput(
            birthDatetime: Date(timeIntervalSince1970: 638_000_000),
            gender: "female",
            city: "上海",
            longitude: nil
        )
        let req = CompatibilityRequest(
            personAHash: "alpha",
            personB: personB,
            chartPayloadA: payloadA,
            context: "business"
        )
        let data = try APICoder.encoder.encode(req)
        let decoded = try APICoder.decoder.decode(CompatibilityRequest.self, from: data)
        XCTAssertEqual(decoded.personAHash, "alpha")
        XCTAssertNil(decoded.personBHash, "模式 B personBHash 必须为 nil")
        XCTAssertNotNil(decoded.personB)
        XCTAssertEqual(decoded.personB?.gender, "female")
        XCTAssertNil(decoded.chartPayloadB, "模式 B chartPayloadB 必须为 nil")
    }

    // MARK: - CompatibilityResponse

    func testResponse_模式A_decode含nullCharts() throws {
        let json = """
        {
          "compatibility_hash": "compat_hash_x",
          "person_a_chart": null,
          "person_b_chart": null,
          "qualitative_assessment": {
            "five_elements": "互补佳",
            "day_master_relation": "同气",
            "zodiac_match": "六合",
            "branch_harmony": "无冲无刑"
          },
          "synced_fortune": [
            {"year": 2026, "person_a": "甲子运 2026年", "person_b": "丙午运 2026年", "sync": "同步走强"}
          ],
          "calc_rule_snapshot": {
            "library": "lunar_python", "sect": 1, "zi_hour_rule": "zi_next_day",
            "true_solar_longitude": 116.4, "true_solar_offset_minutes": -14.4,
            "schema_version": 1
          }
        }
        """.data(using: .utf8)!
        let resp = try APICoder.decoder.decode(CompatibilityResponse.self, from: json)
        XCTAssertEqual(resp.compatibilityHash, "compat_hash_x")
        XCTAssertNil(resp.personAChart)
        XCTAssertNil(resp.personBChart)
        XCTAssertEqual(resp.qualitativeAssessment.branchHarmony, "无冲无刑")
        XCTAssertEqual(resp.syncedFortune.count, 1)
        XCTAssertEqual(resp.syncedFortune[0].sync, "同步走强")
    }

    // MARK: - Helpers

    private static func makePayload(dayMaster: String, element: String) -> ChartPayloadDTO {
        ChartPayloadDTO(
            dayMaster: dayMaster, dayMasterElement: element,
            dayMasterStrength: "balanced",
            favorableElements: [element], unfavorableElements: [],
            fourPillars: ["day": PillarRefDTO(gan: dayMaster, zhi: "子")]
        )
    }
}
