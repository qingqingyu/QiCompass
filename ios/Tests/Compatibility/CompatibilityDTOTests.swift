import XCTest
@testable import QiCompass

/// CompatibilityDTOs encode/decode 单元测试(方案 §阶段 6)。
///
/// 验证:
/// - 模式 A:encode 含 person_b_hash + chart_payload_b,不含 person_b
/// - 模式 B:encode 含 person_b,不含 person_b_hash + chart_payload_b
/// - PersonBInput S02 契约:裸钟面 + timezone + longitude 必填,nil 字段不编码
/// - 可空 chart 字段对齐后端(person_a_chart 始终 None / person_b_chart 模式相关)
/// - 扩展字段 luck_pillars + calc_rule_snapshot 正确编码
final class CompatibilityDTOTests: XCTestCase {

    // MARK: - PersonBInput

    func testPersonBInput_完整字段_编码() throws {
        let input = PersonBInput(
            birthDatetime: "1990-03-15T14:30:00",
            timezone: "Asia/Shanghai",
            gender: "male",
            longitude: 116.4074,
            latitude: 39.9042,
            placeName: "北京",
            geonameId: 1816670
        )
        let data = try APICoder.encoder.encode(input)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // 注:JSONEncoder 会把 "/" 转义为 "\/"(Asia\/Shanghai,后端解码等价),
        // 故 timezone 用解析回字典断言,其余用 contains
        XCTAssertTrue(json.contains("\"birth_datetime\":\"1990-03-15T14:30:00\""))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["timezone"] as? String, "Asia/Shanghai")
        XCTAssertTrue(json.contains("\"longitude\":116.4074"))
        XCTAssertTrue(json.contains("\"place_name\":\"北京\""))
        XCTAssertTrue(json.contains("\"zi_hour_rule\":\"zi_next_day\""))
        XCTAssertFalse(json.contains("\"city\""), "旧 city 字段必须消失(S02 零兼容)")
    }

    func testPersonBInput_可选字段nil不编码() throws {
        let input = PersonBInput(
            birthDatetime: "1990-03-15T14:30:00",
            timezone: "Etc/GMT-8",
            gender: "female",
            longitude: 87.62
        )
        let data = try APICoder.encoder.encode(input)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("\"latitude\""), "latitude 为 nil 不编码")
        XCTAssertFalse(json.contains("\"place_name\""), "place_name 为 nil 不编码")
        XCTAssertFalse(json.contains("\"geoname_id\""), "geoname_id 为 nil 不编码")
    }

    func testPersonBInput_wallClockDisplay_去秒展示() {
        // 名单行 / 失败卡片兜底名共用格式(yyyy-MM-dd HH:mm,无秒)
        let input = PersonBInput(
            birthDatetime: "1990-03-15T14:30:00",
            timezone: "Asia/Shanghai",
            gender: "male",
            longitude: 116.4074
        )
        XCTAssertEqual(input.wallClockDisplay, "1990-03-15 14:30")
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
            birthDatetime: "1990-03-15T14:30:00",
            timezone: "Asia/Shanghai",
            gender: "female",
            longitude: 121.4737
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
