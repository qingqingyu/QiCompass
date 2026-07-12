import Foundation

// MARK: - Request

/// POST /api/bazi/daily-fortune 请求。对齐 backend/app/models/daily_fortune.py:DailyFortuneRequest
///
/// chart_payload 模式(决策 §1.A):客户端传存档解出的日主/喜忌/四柱,
/// 后端不反推 birth,不持久化 ChartSnapshot,纯函数排盘。
struct DailyFortuneRequest: Codable, Sendable {
    let chartHash: String
    let targetDate: Date
    let chartPayload: ChartPayloadDTO

    enum CodingKeys: String, CodingKey {
        case chartHash = "chart_hash"
        case targetDate = "target_date"
        case chartPayload = "chart_payload"
    }

    init(chartHash: String, targetDate: Date, chartPayload: ChartPayloadDTO) {
        self.chartHash = chartHash
        self.targetDate = targetDate
        self.chartPayload = chartPayload
    }

    /// 兼容旧调用(stub 期间只传 hash + date)。实际生产请用完整 init。
    init(chartHash: String, targetDate: Date) {
        self.init(
            chartHash: chartHash,
            targetDate: targetDate,
            chartPayload: ChartPayloadDTO.placeholder
        )
    }
}

/// 单柱引用(chart_payload.four_pillars 用,仅含排盘命中冲所需字段)。
struct PillarRefDTO: Codable, Sendable {
    let gan: String
    let zhi: String
}

/// 客户端从存档 ChartSnapshot.payload 解出的核心字段,作为可信源传给后端。
///
/// 兼容字段(合盘用,daily-fortune 不填不影响):
/// - `luckPillars`:合盘算「{大运} {流年}」必需
/// - `calcRuleSnapshot`:合盘 response 需要回显规则快照
struct ChartPayloadDTO: Codable, Sendable {
    let dayMaster: String
    let dayMasterElement: String
    let dayMasterStrength: String
    let favorableElements: [String]
    let unfavorableElements: [String]
    let fourPillars: [String: PillarRefDTO]
    let luckPillars: [LuckPillarDTO]?
    let calcRuleSnapshot: CalcRuleSnapshotDTO?

    enum CodingKeys: String, CodingKey {
        case dayMaster = "day_master"
        case dayMasterElement = "day_master_element"
        case dayMasterStrength = "day_master_strength"
        case favorableElements = "favorable_elements"
        case unfavorableElements = "unfavorable_elements"
        case fourPillars = "four_pillars"
        case luckPillars = "luck_pillars"
        case calcRuleSnapshot = "calc_rule_snapshot"
    }

    /// daily-fortune 路径主构造器(不带扩展字段)。
    init(
        dayMaster: String,
        dayMasterElement: String,
        dayMasterStrength: String,
        favorableElements: [String],
        unfavorableElements: [String],
        fourPillars: [String: PillarRefDTO]
    ) {
        self.dayMaster = dayMaster
        self.dayMasterElement = dayMasterElement
        self.dayMasterStrength = dayMasterStrength
        self.favorableElements = favorableElements
        self.unfavorableElements = unfavorableElements
        self.fourPillars = fourPillars
        self.luckPillars = nil
        self.calcRuleSnapshot = nil
    }

    /// 合盘路径完整构造器(带扩展字段)。
    init(
        dayMaster: String,
        dayMasterElement: String,
        dayMasterStrength: String,
        favorableElements: [String],
        unfavorableElements: [String],
        fourPillars: [String: PillarRefDTO],
        luckPillars: [LuckPillarDTO],
        calcRuleSnapshot: CalcRuleSnapshotDTO
    ) {
        self.dayMaster = dayMaster
        self.dayMasterElement = dayMasterElement
        self.dayMasterStrength = dayMasterStrength
        self.favorableElements = favorableElements
        self.unfavorableElements = unfavorableElements
        self.fourPillars = fourPillars
        self.luckPillars = luckPillars
        self.calcRuleSnapshot = calcRuleSnapshot
    }

    /// MockAPIClient / 测试用占位(日主甲木 balanced)。
    static let placeholder = ChartPayloadDTO(
        dayMaster: "甲",
        dayMasterElement: "wood",
        dayMasterStrength: "balanced",
        favorableElements: ["水"],
        unfavorableElements: ["金"],
        fourPillars: [
            "year": PillarRefDTO(gan: "甲", zhi: "子"),
            "month": PillarRefDTO(gan: "甲", zhi: "子"),
            "day": PillarRefDTO(gan: "甲", zhi: "子"),
            "hour": PillarRefDTO(gan: "甲", zhi: "子"),
        ]
    )
}

// MARK: - Response

/// POST /api/bazi/daily-fortune 响应。对齐 backend DailyFortuneResponse
struct DailyFortuneResponse: Codable, Sendable {
    let dayPillar: String
    let dayRelationToDayMaster: String
    let dayChong: String?
    let dayChongTargets: [String]
    let hourPillars: [HourPillarDTO]
    let currentHourIndex: Int?
    let lunarDate: String
    let huangliYi: [String]
    let huangliJi: [String]
    let tomorrowPreview: TomorrowPreviewDTO
    let calcRuleSnapshot: CalcRuleSnapshotDTO

    enum CodingKeys: String, CodingKey {
        case dayPillar = "day_pillar"
        case dayRelationToDayMaster = "day_relation_to_day_master"
        case dayChong = "day_chong"
        case dayChongTargets = "day_chong_targets"
        case hourPillars = "hour_pillars"
        case currentHourIndex = "current_hour_index"
        case lunarDate = "lunar_date"
        case huangliYi = "huangli_yi"
        case huangliJi = "huangli_ji"
        case tomorrowPreview = "tomorrow_preview"
        case calcRuleSnapshot = "calc_rule_snapshot"
    }
}

struct HourPillarDTO: Codable, Sendable {
    let hour: String
    let timeRange: String
    let pillar: String
    let relation: String
    let chong: String?
    let chongTargets: [String]

    enum CodingKeys: String, CodingKey {
        case hour
        case timeRange = "time_range"
        case pillar
        case relation
        case chong
        case chongTargets = "chong_targets"
    }
}

struct TomorrowPreviewDTO: Codable, Sendable {
    let dayPillar: String
    let dayRelation: String
    let dayChong: String?

    enum CodingKeys: String, CodingKey {
        case dayPillar = "day_pillar"
        case dayRelation = "day_relation"
        case dayChong = "day_chong"
    }
}
