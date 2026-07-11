import Foundation

// MARK: - Request

/// POST /api/bazi/calculate 请求。
/// 对齐 backend/app/models/bazi.py:BaziCalculateRequest
struct BaziCalculateRequest: Codable, Sendable {
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
}

// MARK: - Pillar

/// 单柱结构(年/月/日/时通用)。对齐 backend Pillar
struct PillarDTO: Codable, Sendable, Equatable {
    let ganZhi: String
    let gan: String
    let zhi: String
    let ganElement: String
    let zhiElement: String
    let hideGan: [String]
    let shishenGan: String
    let shishenZhi: [String]
    let nayin: String
    let dishi: String
    let xunkong: String

    enum CodingKeys: String, CodingKey {
        case ganZhi = "gan_zhi"
        case gan
        case zhi
        case ganElement = "gan_element"
        case zhiElement = "zhi_element"
        case hideGan = "hide_gan"
        case shishenGan = "shishen_gan"
        case shishenZhi = "shishen_zhi"
        case nayin
        case dishi
        case xunkong
    }
}

struct PillarsDTO: Codable, Sendable, Equatable {
    let year: PillarDTO
    let month: PillarDTO
    let day: PillarDTO
    let hour: PillarDTO
}

struct GanZhiNaYinDTO: Codable, Sendable, Equatable {
    let ganZhi: String
    let nayin: String

    enum CodingKeys: String, CodingKey {
        case ganZhi = "gan_zhi"
        case nayin
    }
}

struct ElementBalanceDTO: Codable, Sendable, Equatable {
    let wood: Int
    let fire: Int
    let earth: Int
    let metal: Int
    let water: Int
}

struct LuckPillarDTO: Codable, Sendable, Equatable {
    let ganZhi: String
    let startYear: Int
    let endYear: Int
    let startAge: Int
    let endAge: Int

    enum CodingKeys: String, CodingKey {
        case ganZhi = "gan_zhi"
        case startYear = "start_year"
        case endYear = "end_year"
        case startAge = "start_age"
        case endAge = "end_age"
    }
}

struct CurrentPillarDTO: Codable, Sendable, Equatable {
    let ganZhi: String
    let startYear: Int
    let endYear: Int

    enum CodingKeys: String, CodingKey {
        case ganZhi = "gan_zhi"
        case startYear = "start_year"
        case endYear = "end_year"
    }
}

struct CalcRuleSnapshotDTO: Codable, Sendable, Equatable {
    let library: String
    let sect: Int
    let ziHourRule: String
    let trueSolarLongitude: Double
    let trueSolarOffsetMinutes: Double
    let schemaVersion: Int

    enum CodingKeys: String, CodingKey {
        case library
        case sect
        case ziHourRule = "zi_hour_rule"
        case trueSolarLongitude = "true_solar_longitude"
        case trueSolarOffsetMinutes = "true_solar_offset_minutes"
        case schemaVersion = "schema_version"
    }
}

struct ShenshaItemDTO: Codable, Sendable, Equatable {
    let name: String
    let position: String
    let source: String
}

// MARK: - Response

/// POST /api/bazi/calculate 响应。对齐 backend BaziCalculateResponse
struct BaziResponse: Codable, Sendable {
    let contentHash: String
    let trueSolarTime: Date
    let trueSolarOffsetMinutes: Double
    let pillars: PillarsDTO
    let mingGong: GanZhiNaYinDTO
    let shenGong: GanZhiNaYinDTO
    let taiYuan: GanZhiNaYinDTO
    let elementBalance: ElementBalanceDTO
    let favorableElements: [String]
    let unfavorableElements: [String]
    let dayMasterStrength: String?
    let tiaoshouApplied: Bool
    let xijiMethod: String?
    let patternHint: String?
    let shensha: [ShenshaItemDTO]
    let luckPillars: [LuckPillarDTO]
    let currentLuckPillar: CurrentPillarDTO?
    let currentYearPillar: String?
    let currentDayPillar: String?
    let currentHourPillar: String?
    let calcRuleSnapshot: CalcRuleSnapshotDTO
    let boundaryWarning: String?

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case trueSolarTime = "true_solar_time"
        case trueSolarOffsetMinutes = "true_solar_offset_minutes"
        case pillars
        case mingGong = "ming_gong"
        case shenGong = "shen_gong"
        case taiYuan = "tai_yuan"
        case elementBalance = "element_balance"
        case favorableElements = "favorable_elements"
        case unfavorableElements = "unfavorable_elements"
        case dayMasterStrength = "day_master_strength"
        case tiaoshouApplied = "tiaoshou_applied"
        case xijiMethod = "xiji_method"
        case patternHint = "pattern_hint"
        case shensha
        case luckPillars = "luck_pillars"
        case currentLuckPillar = "current_luck_pillar"
        case currentYearPillar = "current_year_pillar"
        case currentDayPillar = "current_day_pillar"
        case currentHourPillar = "current_hour_pillar"
        case calcRuleSnapshot = "calc_rule_snapshot"
        case boundaryWarning = "boundary_warning"
    }
}

// MARK: - Error

/// 后端结构化错误体。对齐 backend ErrorBody / ErrorResponse
struct ErrorBodyDTO: Codable, Sendable {
    let code: String
    let message: String
    let requestId: String?
    let contentHash: String?

    enum CodingKeys: String, CodingKey {
        case code
        case message
        case requestId = "request_id"
        case contentHash = "content_hash"
    }
}

struct ErrorResponseDTO: Codable, Sendable {
    let error: ErrorBodyDTO
}
