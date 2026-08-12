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

// MARK: - MetaBlock(v1 prompt 系统 chart.meta,Stage 1 后端引入)

/// 出生上下文 meta 块。对齐 backend `app/models/bazi.py:MetaBlock`。
///
/// v1 prompt 系统的 M0-M7 prompt 注入 chart_json 含 meta 字段(对齐
/// bazi-prompt-system-v1.md §1 schema)。iOS 解析后透传给 buildV1ChartJSON。
///
/// 所有字段后端确定性产出(同输入同输出,无 calculated_at)。
struct MetaBlockDTO: Codable, Sendable, Equatable {
    let locale: String
    let gender: String
    let birthLocal: String
    let trueSolarTime: String
    let lateZishiRule: String
    let solarTermBoundary: String

    enum CodingKeys: String, CodingKey {
        case locale
        case gender
        case birthLocal = "birth_local"
        case trueSolarTime = "true_solar_time"
        case lateZishiRule = "late_zishi_rule"
        case solarTermBoundary = "solar_term_boundary"
    }
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
    /// 2026-08-01 grill-me 决策 #13:chart anchor sentence(后端确定性拼接,0 AI 成本)
    /// 默认 nil 兼容老 mock/test 构造(APIClient.swift mock 不需手填)
    var anchorSentence: String? = nil
    /// 2026-08-11 生肖 wire up:年柱地支对应生肖英文(如 "Dragon")。
    /// 后端 lunar_python 已按立春算 pillars.year.zhi,这里仅查表暴露。
    /// 非 optional:后端语义保证非空。mock 构造须手填(对齐其他非 optional 字段)。
    let yearBranchZodiac: String

    // v1 prompt 系统 chart 注入字段(Stage 1 后端引入,iOS Stage 7b 接入)
    // 默认值兼容老 mock / 老 response:Swift synthesized Codable 对 let + 默认值
    // 用 decodeIfPresent + ?? default,缺 key 时用默认值(对齐 backend bazi_engine
    // Stage 1+ 总是返回非空值的语义)
    // 注:用 let + 默认值(不用 var)以保持 BaziResponse 的 Sendable 合成
    // (Swift 严格并发检查要求 Sendable struct 所有 stored property 是 let 或自身 Sendable)
    /// 全局十神权重(10 个十神 → 计数)。空 dict = 老 response 或 special_pattern 时未算
    let tenGodWeights: [String: Int] = [:]
    /// 喜用五行中文 list(special_pattern 时为空)
    let usefulGodCandidates: [String] = []
    /// 出生上下文 meta 块。nil = 老 response 未含此字段
    let meta: MetaBlockDTO? = nil

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
        case anchorSentence = "anchor_sentence"
        case yearBranchZodiac = "year_branch_zodiac"
        case tenGodWeights = "ten_god_weights"
        case usefulGodCandidates = "useful_god_candidates"
        case meta
    }

    // Stage 7b 关键修复:自定义 init(from:) 让 v1 字段真能解码。
    // Swift synthesized Codable 对 `let + 默认值` 的非 Optional 字段会跳过解码
    // ( compiler warning "immutable property will not be decoded because it is
    //   declared with an initial value which cannot be overwritten" ),
    // 属性永远是默认值。这会让 tenGodWeights/usefulGodCandidates/meta 永远空,
    // buildV1ChartJSON 永远 throw missingMetaBlock,整个 v1 prompt 系统不可用。
    // 显式 init 用 decodeIfPresent + ?? default 解决(对齐 InterpretRequest 模式)。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        trueSolarTime = try c.decode(Date.self, forKey: .trueSolarTime)
        trueSolarOffsetMinutes = try c.decode(Double.self, forKey: .trueSolarOffsetMinutes)
        pillars = try c.decode(PillarsDTO.self, forKey: .pillars)
        mingGong = try c.decode(GanZhiNaYinDTO.self, forKey: .mingGong)
        shenGong = try c.decode(GanZhiNaYinDTO.self, forKey: .shenGong)
        taiYuan = try c.decode(GanZhiNaYinDTO.self, forKey: .taiYuan)
        elementBalance = try c.decode(ElementBalanceDTO.self, forKey: .elementBalance)
        favorableElements = try c.decode([String].self, forKey: .favorableElements)
        unfavorableElements = try c.decode([String].self, forKey: .unfavorableElements)
        dayMasterStrength = try c.decodeIfPresent(String.self, forKey: .dayMasterStrength)
        tiaoshouApplied = try c.decode(Bool.self, forKey: .tiaoshouApplied)
        xijiMethod = try c.decodeIfPresent(String.self, forKey: .xijiMethod)
        patternHint = try c.decodeIfPresent(String.self, forKey: .patternHint)
        shensha = try c.decode([ShenshaItemDTO].self, forKey: .shensha)
        luckPillars = try c.decode([LuckPillarDTO].self, forKey: .luckPillars)
        currentLuckPillar = try c.decodeIfPresent(CurrentPillarDTO.self, forKey: .currentLuckPillar)
        currentYearPillar = try c.decodeIfPresent(String.self, forKey: .currentYearPillar)
        currentDayPillar = try c.decodeIfPresent(String.self, forKey: .currentDayPillar)
        currentHourPillar = try c.decodeIfPresent(String.self, forKey: .currentHourPillar)
        calcRuleSnapshot = try c.decode(CalcRuleSnapshotDTO.self, forKey: .calcRuleSnapshot)
        boundaryWarning = try c.decodeIfPresent(String.self, forKey: .boundaryWarning)
        anchorSentence = try c.decodeIfPresent(String.self, forKey: .anchorSentence)
        yearBranchZodiac = try c.decode(String.self, forKey: .yearBranchZodiac)
        // v1 字段:decodeIfPresent + 默认值,缺 key 走默认(对齐 backend Stage 1+ 语义)
        tenGodWeights = try c.decodeIfPresent([String: Int].self, forKey: .tenGodWeights) ?? [:]
        usefulGodCandidates = try c.decodeIfPresent([String].self, forKey: .usefulGodCandidates) ?? []
        meta = try c.decodeIfPresent(MetaBlockDTO.self, forKey: .meta)
    }

    // Stage 7b:memberwise init(自定义 init(from:) 后失去合成,手写带默认值
    // 让 mock / test 调用兼容)。v1 字段都有默认值,mock 不传也能构造。
    init(
        contentHash: String,
        trueSolarTime: Date,
        trueSolarOffsetMinutes: Double,
        pillars: PillarsDTO,
        mingGong: GanZhiNaYinDTO,
        shenGong: GanZhiNaYinDTO,
        taiYuan: GanZhiNaYinDTO,
        elementBalance: ElementBalanceDTO,
        favorableElements: [String],
        unfavorableElements: [String],
        dayMasterStrength: String?,
        tiaoshouApplied: Bool,
        xijiMethod: String?,
        patternHint: String?,
        shensha: [ShenshaItemDTO],
        luckPillars: [LuckPillarDTO],
        currentLuckPillar: CurrentPillarDTO?,
        currentYearPillar: String?,
        currentDayPillar: String?,
        currentHourPillar: String?,
        calcRuleSnapshot: CalcRuleSnapshotDTO,
        boundaryWarning: String?,
        yearBranchZodiac: String,
        anchorSentence: String? = nil,
        tenGodWeights: [String: Int] = [:],
        usefulGodCandidates: [String] = [],
        meta: MetaBlockDTO? = nil
    ) {
        self.contentHash = contentHash
        self.trueSolarTime = trueSolarTime
        self.trueSolarOffsetMinutes = trueSolarOffsetMinutes
        self.pillars = pillars
        self.mingGong = mingGong
        self.shenGong = shenGong
        self.taiYuan = taiYuan
        self.elementBalance = elementBalance
        self.favorableElements = favorableElements
        self.unfavorableElements = unfavorableElements
        self.dayMasterStrength = dayMasterStrength
        self.tiaoshouApplied = tiaoshouApplied
        self.xijiMethod = xijiMethod
        self.patternHint = patternHint
        self.shensha = shensha
        self.luckPillars = luckPillars
        self.currentLuckPillar = currentLuckPillar
        self.currentYearPillar = currentYearPillar
        self.currentDayPillar = currentDayPillar
        self.currentHourPillar = currentHourPillar
        self.calcRuleSnapshot = calcRuleSnapshot
        self.boundaryWarning = boundaryWarning
        self.yearBranchZodiac = yearBranchZodiac
        self.anchorSentence = anchorSentence
        self.tenGodWeights = tenGodWeights
        self.usefulGodCandidates = usefulGodCandidates
        self.meta = meta
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
