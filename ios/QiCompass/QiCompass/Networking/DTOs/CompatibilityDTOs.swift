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
    /// per-chart token(2026-10-07 P0 收口):A/B 盘各自排盘响应的
    /// contextTokens["payload"],后端对账 token↔hash↔payload 后才签发合盘
    /// token(模式 B 后端现排 B,无需 B token)。
    var contextTokenA: String
    var contextTokenB: String?

    enum CodingKeys: String, CodingKey {
        case personAHash = "person_a_hash"
        case personBHash = "person_b_hash"
        case personB = "person_b"
        case chartPayloadA = "chart_payload_a"
        case chartPayloadB = "chart_payload_b"
        case context
        case contextTokenA = "context_token_a"
        case contextTokenB = "context_token_b"
    }

    /// 模式 A:B 已存档。
    init(
        personAHash: String,
        personBHash: String,
        chartPayloadA: ChartPayloadDTO,
        chartPayloadB: ChartPayloadDTO,
        context: String,
        contextTokenA: String,
        contextTokenB: String
    ) {
        self.personAHash = personAHash
        self.personBHash = personBHash
        self.personB = nil
        self.chartPayloadA = chartPayloadA
        self.chartPayloadB = chartPayloadB
        self.context = context
        self.contextTokenA = contextTokenA
        self.contextTokenB = contextTokenB
    }

    /// 模式 B:B 临时输入(后端现排)。
    init(
        personAHash: String,
        personB: PersonBInput,
        chartPayloadA: ChartPayloadDTO,
        context: String,
        contextTokenA: String
    ) {
        self.personAHash = personAHash
        self.personBHash = nil
        self.personB = personB
        self.chartPayloadA = chartPayloadA
        self.chartPayloadB = nil
        self.context = context
        self.contextTokenA = contextTokenA
        self.contextTokenB = nil
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
        try container.encode(contextTokenA, forKey: .contextTokenA)
        try container.encodeIfPresent(contextTokenB, forKey: .contextTokenB)
    }
}

/// 模式 B 输入(B 临时输入,字段子集复用 BaziCalculateRequest)。
///
/// S02 契约(与 /api/bazi/calculate 同一套):birthDatetime **裸钟面字符串**
/// (yyyy-MM-dd'T'HH:mm:ss)+ timezone(后端 zoneinfo 解释)+ longitude 必填;
/// latitude/placeName/geonameId 存档展示用。`ziHourRule` MVP 固定 `zi_next_day`。
struct PersonBInput: Codable, Sendable, Equatable {
    let birthDatetime: String
    let timezone: String
    let gender: String
    let longitude: Double
    let latitude: Double?
    let placeName: String?
    let geonameId: Int?
    let ziHourRule: String

    enum CodingKeys: String, CodingKey {
        case birthDatetime = "birth_datetime"
        case timezone
        case gender
        case longitude
        case latitude
        case placeName = "place_name"
        case geonameId = "geoname_id"
        case ziHourRule = "zi_hour_rule"
    }

    init(
        birthDatetime: String,
        timezone: String,
        gender: String,
        longitude: Double,
        latitude: Double? = nil,
        placeName: String? = nil,
        geonameId: Int? = nil,
        ziHourRule: String = "zi_next_day"
    ) {
        self.birthDatetime = birthDatetime
        self.timezone = timezone
        self.gender = gender
        self.longitude = longitude
        self.latitude = latitude
        self.placeName = placeName
        self.geonameId = geonameId
        self.ziHourRule = ziHourRule
    }

    /// 编码:跳过 nil 字段(避免传 null 干扰后端互斥校验,对齐后端 extra=forbid)。
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(birthDatetime, forKey: .birthDatetime)
        try container.encode(timezone, forKey: .timezone)
        try container.encode(gender, forKey: .gender)
        try container.encode(longitude, forKey: .longitude)
        try container.encodeIfPresent(latitude, forKey: .latitude)
        try container.encodeIfPresent(placeName, forKey: .placeName)
        try container.encodeIfPresent(geonameId, forKey: .geonameId)
        try container.encode(ziHourRule, forKey: .ziHourRule)
    }

    /// 裸钟面字符串 → 展示格式(yyyy-MM-dd HH:mm,去秒)。
    /// 格式固定 19 字符(yyyy-MM-dd'T'HH:mm:ss),dropLast(3) 去 ":ss" 安全。
    /// 名单行 / 失败卡片兜底名共用,避免各处内联重复(S04 review)。
    var wallClockDisplay: String {
        String(birthDatetime.dropLast(3)).replacingOccurrences(of: "T", with: " ")
    }
}

// MARK: - Response

/// POST /api/bazi/compatibility 响应。
///
/// 对齐 backend CompatibilityResponse:
/// - `personAChart` **始终 nil**(A 永远从本地存档渲染,后端不重排)
/// - `personBChart`:模式 A nil(B 也从本地存档渲染);模式 B 为后端现排的 B 盘完整响应
/// - `ruleVersion`:引擎规则版本(2026-10-07)——客户端快照重算判据,不参与
///   compatibilityHash;老后端缺字段 → nil(视同过期,重算兜底)
struct CompatibilityResponse: Codable, Sendable {
    let compatibilityHash: String
    let personAChart: BaziResponse?
    let personBChart: BaziResponse?
    let qualitativeAssessment: QualitativeAssessmentDTO
    let syncedFortune: [SyncedFortuneDTO]
    let calcRuleSnapshot: CalcRuleSnapshotDTO?
    /// var + nil 默认:memberwise 才有默认值(let 可选无隐式默认,老构造点
    /// 会缺参);解码/显式传参照常覆盖
    var ruleVersion: Int? = nil
    /// compat 族 context_token(2026-10-07 P0 收口):interpret/translate 验签;
    /// 老后端缺字段 → nil(触发重算)。合成 Codable 的 decodeIfPresent。
    var contextToken: String? = nil

    enum CodingKeys: String, CodingKey {
        case compatibilityHash = "compatibility_hash"
        case personAChart = "person_a_chart"
        case personBChart = "person_b_chart"
        case qualitativeAssessment = "qualitative_assessment"
        case syncedFortune = "synced_fortune"
        case calcRuleSnapshot = "calc_rule_snapshot"
        case ruleVersion = "rule_version"
        case contextToken = "context_token"
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
