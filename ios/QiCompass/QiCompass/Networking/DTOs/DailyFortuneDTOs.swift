import Foundation

// MARK: - Request

/// POST /api/bazi/daily-fortune 请求(stub:后端未实现,DTO 对齐设计文档 §187-207)。
struct DailyFortuneRequest: Codable, Sendable {
    let chartHash: String
    let targetDate: Date

    enum CodingKeys: String, CodingKey {
        case chartHash = "chart_hash"
        case targetDate = "target_date"
    }
}

// MARK: - Response

/// POST /api/bazi/daily-fortune 响应(stub:后端未实现)。
struct DailyFortuneResponse: Codable, Sendable {
    let dayPillar: String
    let dayRelationToDayMaster: String
    let dayChong: String
    let hourPillars: [HourPillarDTO]
    let currentHourIndex: Int
    let huangliYi: [String]
    let huangliJi: [String]
    let calcRuleSnapshot: CalcRuleSnapshotDTO

    enum CodingKeys: String, CodingKey {
        case dayPillar = "day_pillar"
        case dayRelationToDayMaster = "day_relation_to_day_master"
        case dayChong = "day_chong"
        case hourPillars = "hour_pillars"
        case currentHourIndex = "current_hour_index"
        case huangliYi = "huangli_yi"
        case huangliJi = "huangli_ji"
        case calcRuleSnapshot = "calc_rule_snapshot"
    }
}

struct HourPillarDTO: Codable, Sendable {
    let hour: String
    let timeRange: String
    let pillar: String
    let relation: String
    let chong: String

    enum CodingKeys: String, CodingKey {
        case hour
        case timeRange = "time_range"
        case pillar
        case relation
        case chong
    }
}
