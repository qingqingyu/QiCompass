import Foundation

// MARK: - Request

/// POST /api/bazi/compatibility 请求(stub:后端未实现,DTO 对齐设计文档 §159-184)。
struct CompatibilityRequest: Codable, Sendable {
    let personAHash: String
    let personB: PersonBInput
    let context: String

    enum CodingKeys: String, CodingKey {
        case personAHash = "person_a_hash"
        case personB = "person_b"
        case context
    }
}

struct PersonBInput: Codable, Sendable {
    let birthDatetime: Date
    let gender: String
    let city: String?
    let ziHourRule: String

    enum CodingKeys: String, CodingKey {
        case birthDatetime = "birth_datetime"
        case gender
        case city
        case ziHourRule = "zi_hour_rule"
    }
}

// MARK: - Response

/// POST /api/bazi/compatibility 响应(stub:后端未实现)。
struct CompatibilityResponse: Codable, Sendable {
    let compatibilityHash: String
    let personAChart: BaziResponse
    let personBChart: BaziResponse
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

struct QualitativeAssessmentDTO: Codable, Sendable {
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

struct SyncedFortuneDTO: Codable, Sendable {
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
