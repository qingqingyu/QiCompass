import Foundation

// MARK: - Request

/// POST /api/bazi/compatibility 请求。
///
/// 对齐 backend/app/models/compatibility.py:CompatibilityRequest(双模式 A/B):
/// - 模式 A(B 已存档):`personBHash` + `chartPayloadB` 必填,后端零排盘
/// - 模式 B(B 临时输入):`personB` 必填,后端现排 B
/// - `personBHash` 与 `personB` 互斥且至少一个(后端 `model_validator` 兜底,422)
/// - 模式 A 下 `chartPayloadB` 必填(后端 `chart_payload_b_consistency` 兜底)
/// - `chartPayloadA` 始终必填(A 盘从本地存档解出,后端无状态)
struct CompatibilityRequest: Codable, Sendable {
    let personAHash: String
    let personBHash: String?
    let personB: PersonBInput?
    let chartPayloadA: ChartPayloadDTO
    let chartPayloadB: ChartPayloadDTO?
    let context: String

    enum CodingKeys: String, CodingKey {
        case personAHash = "person_a_hash"
        case personBHash = "person_b_hash"
        case personB = "person_b"
        case chartPayloadA = "chart_payload_a"
        case chartPayloadB = "chart_payload_b"
        case context
    }

    /// 模式 A:B 已存档。
    init(
        personAHash: String,
        personBHash: String,
        chartPayloadA: ChartPayloadDTO,
        chartPayloadB: ChartPayloadDTO,
        context: String
    ) {
        self.personAHash = personAHash
        self.personBHash = personBHash
        self.personB = nil
        self.chartPayloadA = chartPayloadA
        self.chartPayloadB = chartPayloadB
        self.context = context
    }

    /// 模式 B:B 临时输入(后端现排)。
    init(
        personAHash: String,
        personB: PersonBInput,
        chartPayloadA: ChartPayloadDTO,
        context: String
    ) {
        self.personAHash = personAHash
        self.personBHash = nil
        self.personB = personB
        self.chartPayloadA = chartPayloadA
        self.chartPayloadB = nil
        self.context = context
    }

    /// 编码:跳过 nil 字段(避免传 `"person_b_hash": null` 干扰后端互斥校验)。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(personAHash, forKey: .personAHash)
        try container.encodeIfPresent(personBHash, forKey: .personBHash)
        try container.encodeIfPresent(personB, forKey: .personB)
        try container.encode(chartPayloadA, forKey: .chartPayloadA)
        try container.encodeIfPresent(chartPayloadB, forKey: .chartPayloadB)
        try container.encode(context, forKey: .context)
    }
}

/// 模式 B 输入(B 临时输入,字段子集复用 BaziCalculateRequest)。
///
/// `city` 与 `longitude` 至少传一个(后端 `city_or_longitude_required` 兜底,422)。
/// `longitude` 优先级高于 `city`。`ziHourRule` MVP 固定 `zi_next_day`。
struct PersonBInput: Codable, Sendable {
    let birthDatetime: Date
    let gender: String
    let city: String?
    let longitude: Double?
    let ziHourRule: String

    enum CodingKeys: String, CodingKey {
        case birthDatetime = "birth_datetime"
        case gender
        case city
        case longitude
        case ziHourRule = "zi_hour_rule"
    }

    init(
        birthDatetime: Date,
        gender: String,
        city: String?,
        longitude: Double?,
        ziHourRule: String = "zi_next_day"
    ) {
        self.birthDatetime = birthDatetime
        self.gender = gender
        self.city = city
        self.longitude = longitude
        self.ziHourRule = ziHourRule
    }

    /// 编码:跳过 nil 字段(避免传 null 干扰后端 city/longitude 互斥校验)。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(birthDatetime, forKey: .birthDatetime)
        try container.encode(gender, forKey: .gender)
        try container.encodeIfPresent(city, forKey: .city)
        try container.encodeIfPresent(longitude, forKey: .longitude)
        try container.encode(ziHourRule, forKey: .ziHourRule)
    }
}

// MARK: - Response

/// POST /api/bazi/compatibility 响应。
///
/// 对齐 backend CompatibilityResponse:
/// - `personAChart` **始终 nil**(A 永远从本地存档渲染,后端不重排)
/// - `personBChart`:模式 A nil(B 也从本地存档渲染);模式 B 为后端现排的 B 盘完整响应
struct CompatibilityResponse: Codable, Sendable {
    let compatibilityHash: String
    let personAChart: BaziResponse?
    let personBChart: BaziResponse?
    let qualitativeAssessment: QualitativeAssessmentDTO
    let syncedFortune: [SyncedFortuneDTO]
    let calcRuleSnapshot: CalcRuleSnapshotDTO

    enum CodingKeys: String, CodingKey {
        case compatibilityHash = "compatibility_hash"
        case personAChart = "person_a_chart"
        case personBChart = "person_b_chart"
        case qualitativeAssessment = "qualitative_assessment"
        case syncedFortune = "synced_fortune"
        case calcRuleSnapshot = "calc_rule_snapshot"
    }
}

struct QualitativeAssessmentDTO: Codable, Sendable, Equatable {
    let fiveElements: String
    let dayMasterRelation: String
    let zodiacMatch: String
    let branchHarmony: String

    enum CodingKeys: String, CodingKey {
        case fiveElements = "five_elements"
        case dayMasterRelation = "day_master_relation"
        case zodiacMatch = "zodiac_match"
        case branchHarmony = "branch_harmony"
    }
}

struct SyncedFortuneDTO: Codable, Sendable, Equatable {
    let year: Int
    let personA: String
    let personB: String
    let sync: String

    enum CodingKeys: String, CodingKey {
        case year
        case personA = "person_a"
        case personB = "person_b"
        case sync
    }
}
