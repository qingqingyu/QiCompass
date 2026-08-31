import Foundation

// MARK: - Request

/// POST /api/bazi/calculate 请求。
/// 对齐 backend/app/models/bazi.py:BaziCalculateRequest(S02 契约)
///
/// - birthDatetime:**裸钟面时间字符串**(yyyy-MM-dd'T'HH:mm:ss,无 offset),
///   时区由 timezone 字段解释(后端 zoneinfo,历史夏令时自动套用)。
///   iOS 端用出生城市 Calendar 提取钟面(WYSIWYG),不做 naive→UTC 换算
///   (「客户端不做历法计算」红线)
/// - longitude/latitude/placeName/geonameId:物理真值(S01 cities.sqlite 或
///   自定义输入),后端零城市表
/// - hourKnown/lateNight:时辰未知契约(backend S01 / docs/时辰未知设计决策.md D1+D3)。
///   hourKnown=false 时 birth_datetime 时辰部分由 iOS 显式传 12:00 占位
///   (后端归一亦 12:00,双端一致减少歧义);lateNight 是三态映射
///   是→true / 否→false / 不确定→nil(nil 用 encodeIfPresent 不传,契约两可)
struct BaziCalculateRequest: Codable, Sendable, Equatable {
    let birthDatetime: String
    let timezone: String
    let gender: String
    let longitude: Double
    let latitude: Double?
    let placeName: String?
    let geonameId: Int?
    let ziHourRule: String
    /// 是否知道出生时刻(D1 单一入口)。默认 true = 老路径,合盘 B 盘等既有构造零改动
    var hourKnown: Bool = true
    /// 「是否半夜出生」二值问题答案(D3);nil = 不确定(编码省略 key)
    var lateNight: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case birthDatetime = "birth_datetime"
        case timezone
        case gender
        case longitude
        case latitude
        case placeName = "place_name"
        case geonameId = "geoname_id"
        case ziHourRule = "zi_hour_rule"
        case hourKnown = "hour_known"
        case lateNight = "late_night"
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

/// 四柱。全柱 Optional(时辰未知契约 S01/S02,iOS 消费 S05):
/// - `hour_known=false` → `hour` 为 null(时辰未知,禁哨兵假精度)
/// - 日柱歧义(D3 答「是/不确定」或西偏换日网)→ `day` 为 null
/// - 年/月柱歧义(节气边界双排盘比对)→ `year`/`month` 为 null
/// - 不变量:`pillar_ambiguity.<pos> == true ⟺ 对应柱为 null`
///
/// Optional + 合成 Codable 的 decodeIfPresent:显式 null 与缺 key 均得 nil,
/// 老 payload(四柱齐全)解码不变(2026-08-15 keyNotFound 教训)。
struct PillarsDTO: Codable, Sendable, Equatable {
    let year: PillarDTO?
    let month: PillarDTO?
    let day: PillarDTO?
    let hour: PillarDTO?
}

/// 柱歧义标记(backend `PillarAmbiguity`,S02/D10)。进响应与 calc_rule_snapshot。
/// `true` = 该柱因时辰未知歧义被置 null(节气边界双排盘 / 西偏换日网 / late_night)。
/// 全 false = 无歧义;`hour_known=true` 恒无此对象。
struct PillarAmbiguityDTO: Codable, Sendable, Equatable {
    var year: Bool = false
    var month: Bool = false
    var day: Bool = false

    enum CodingKeys: String, CodingKey {
        case year, month, day
    }

    init(year: Bool = false, month: Bool = false, day: Bool = false) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        year = try c.decodeIfPresent(Bool.self, forKey: .year) ?? false
        month = try c.decodeIfPresent(Bool.self, forKey: .month) ?? false
        day = try c.decodeIfPresent(Bool.self, forKey: .day) ?? false
    }
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
    /// 出生地 IANA 时区(S02 契约;老快照/mock 缺省 nil)
    var birthTimezone: String? = nil
    /// 排盘是否含时柱(时辰未知 S01;对齐 backend CalcRuleSnapshot.hour_known)。
    /// Optional + 合成 Codable 的 decodeIfPresent:老 ChartSnapshot payload 缺 key
    /// 解码不 crash,消费方按 `?? true` 处理(2026-08-15 keyNotFound 教训)。
    var hourKnown: Bool? = nil
    /// 柱歧义标记(时辰未知 S02/D10;对齐 backend CalcRuleSnapshot.pillar_ambiguity)。
    /// hour_known=true 恒 nil(老快照形状不变);hour_known=false 必有值(全 false = 零歧义)。
    /// 歧义状态进快照 → 同 hash 可审计歧义降级口径。
    var pillarAmbiguity: PillarAmbiguityDTO? = nil

    enum CodingKeys: String, CodingKey {
        case library
        case sect
        case ziHourRule = "zi_hour_rule"
        case trueSolarLongitude = "true_solar_longitude"
        case trueSolarOffsetMinutes = "true_solar_offset_minutes"
        case schemaVersion = "schema_version"
        case birthTimezone = "birth_timezone"
        case hourKnown = "hour_known"
        case pillarAmbiguity = "pillar_ambiguity"
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
    /// 时辰未知(S01)→ 后端显式 null:12:00 占位的真太阳时属假精度,不漏到响应。
    /// 老 payload 恒有值(decodeIfPresent 兼容)。
    let trueSolarTime: Date?
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
    /// 时辰未知 S02:年柱歧义(立春日 + 时辰未知)→ 显式 null(年支不确定则生肖
    /// 不猜,生肖屏降级归 S08)。老缓存缺 key 时从 pillars.year.zhi 本地查表兜底
    /// (见 init(from:) 的 key-presence 分支)。
    let yearBranchZodiac: String?
    /// 2026-08-13 onboarding 反馈屏「好朋友 / 需磨合」:
    /// 好朋友 = 六合 1 + 三合 2 = 3 个英文生肖名;需磨合 = 六冲 1 个。
    /// 后端复用 branch_relations.py(合盘引擎同一事实源)。
    /// 年柱歧义时随生肖一并置 null(对齐 yearBranchZodiac,不猜);
    /// 老缓存缺 key 时本地查表兜底(见 init(from:))。
    let yearBranchFriends: [String]?
    let yearBranchClash: String?

    // v1 prompt 系统 chart 注入字段(Stage 1 后端引入,iOS Stage 7b 接入)
    // 不在声明处给默认值(否则 init(from decoder:) + 默认值会触发"immutable value
    // may only be initialized once"编译错误),由 memberwise init 的默认参数 +
    // init(from decoder:) 的 decodeIfPresent ?? default 两处分别提供。
    // 注:用 let(不用 var)以保持 BaziResponse 的 Sendable 合成
    // (Swift 严格并发检查要求 Sendable struct 所有 stored property 是 let 或自身 Sendable)
    /// 全局十神权重(10 个十神 → 计数)。空 dict = 老 response 或 special_pattern 时未算
    let tenGodWeights: [String: Int]
    /// 喜用五行中文 list(special_pattern 时为空)
    let usefulGodCandidates: [String]
    /// 出生上下文 meta 块。nil = 老 response 未含此字段;
    /// 时辰未知(S01)后端恒 None(birth_local/true_solar_time 均时辰精确,假精度不漏)
    let meta: MetaBlockDTO?
    /// 时辰未知存档字段(S04,D3):「是否半夜出生」三态答案(是→true/否→false/不确定→nil)。
    /// 后端响应**不回显**此字段(只参与日柱歧义判定),由 `ChartSnapshotStore.upsert`
    /// 从 request 注入 payload 存档;老 payload 缺 key decodeIfPresent → nil。
    var lateNight: Bool? = nil
    /// 神煞完整性标注(时辰未知 S01):按可用柱查表,时支/日支相关条目自然缺失,
    /// 后端显式标注不静默。老响应缺 key → false(decodeIfPresent)。
    var shenshaIncomplete: Bool = false
    /// 柱歧义标记(时辰未知 S02/D10;对齐 backend BaziCalculateResponse.pillar_ambiguity)。
    /// hour_known=true 恒 nil(老路径响应形状不变);渲染留白以 `pillars.<pos> == nil`
    /// 为准(不变量:pillar_ambiguity.<pos> == true ⟺ pillars.<pos> 为 null)。
    var pillarAmbiguity: PillarAmbiguityDTO? = nil

    /// 存档/响应是否含时柱(时辰未知 S04)。单一事实源是后端
    /// `calc_rule_snapshot.hour_known`;老 payload 缺 key → true(decodeIfPresent ?? true)。
    var isHourKnown: Bool {
        calcRuleSnapshot.hourKnown ?? true
    }

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
        case yearBranchFriends = "year_branch_friends"
        case yearBranchClash = "year_branch_clash"
        case tenGodWeights = "ten_god_weights"
        case usefulGodCandidates = "useful_god_candidates"
        case meta
        case lateNight = "late_night"
        case shenshaIncomplete = "shensha_incomplete"
        case pillarAmbiguity = "pillar_ambiguity"
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
        // 时辰未知(S01)→ 后端显式 null(占位一致性验收);老 payload 恒有值
        trueSolarTime = try c.decodeIfPresent(Date.self, forKey: .trueSolarTime)
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
        // 2026-08-15 老缓存兼容:生肖三字段(08-11 zodiac / 08-13 friends+clash)
        // 上线前落库的 ChartSnapshot.payload 缺 key,强制 decode 会 keyNotFound
        // → 全模块「排盘异常」。decodeIfPresent + 从已解码的 pillars.year.zhi
        // 本地查表兜底(ZodiacHelper.legacyYearBranchFields,语义对齐 backend
        // pillars.py:ZODIAC_NAME / branch_relations.py:compute_friends_and_clash)。
        //
        // S05 关键区分(时辰未知 S02 契约):decodeIfPresent 对「key 缺失」与
        // 「显式 null」同返 nil,但两者语义不同——新契约显式 null = 年柱歧义
        // (生肖系不猜),必须原样透传;只有 **key 缺失**(老缓存)才走查表兜底。
        // 用 contains(key) 区分;三字段独立兜底(两批字段落地日期不同,存在
        // 只有部分 key 的中间缓存);需要兜底但年柱缺失/年支不在表 → 显式抛
        // DecodingError(不静默吞)。
        let zodiacKeyPresent = c.contains(CodingKeys.yearBranchZodiac)
        let friendsKeyPresent = c.contains(CodingKeys.yearBranchFriends)
        let clashKeyPresent = c.contains(CodingKeys.yearBranchClash)
        // 任一 key 缺失 → 老缓存/中间缓存,查表兜底只补**缺失**的 key;
        // 需要兜底但年柱缺失(S02 年柱歧义)/年支不在表 → 显式抛 DecodingError
        var legacy: (zodiac: String, friends: [String], clash: String)?
        if !zodiacKeyPresent || !friendsKeyPresent || !clashKeyPresent {
            guard let yearZhi = pillars.year?.zhi,
                  let fields = ZodiacHelper.legacyYearBranchFields(forYearZhi: yearZhi) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [CodingKeys.yearBranchZodiac],
                    debugDescription: "老缓存缺生肖字段且年柱缺失或年支不在兜底表,无法推导"
                ))
            }
            legacy = fields
        }
        // key 在 → 解码值(显式 null = 年柱歧义,原样透传 nil);key 缺 → 兜底值
        func field<T: Decodable>(_ key: CodingKeys, present: Bool, legacy: T?) throws -> T? {
            if present {
                return try c.decodeIfPresent(T.self, forKey: key)
            }
            return legacy
        }
        yearBranchZodiac = try field(.yearBranchZodiac, present: zodiacKeyPresent, legacy: legacy?.zodiac)
        yearBranchFriends = try field(.yearBranchFriends, present: friendsKeyPresent, legacy: legacy?.friends)
        yearBranchClash = try field(.yearBranchClash, present: clashKeyPresent, legacy: legacy?.clash)
        // v1 字段:decodeIfPresent + 默认值,缺 key 走默认(对齐 backend Stage 1+ 语义)
        tenGodWeights = try c.decodeIfPresent([String: Int].self, forKey: .tenGodWeights) ?? [:]
        usefulGodCandidates = try c.decodeIfPresent([String].self, forKey: .usefulGodCandidates) ?? []
        meta = try c.decodeIfPresent(MetaBlockDTO.self, forKey: .meta)
        // 时辰未知存档字段(S04):后端不回显,仅 ChartSnapshotStore.upsert 注入;
        // 老 payload 缺 key → nil(decodeIfPresent,不 crash)
        lateNight = try c.decodeIfPresent(Bool.self, forKey: .lateNight)
        // 时辰未知 S01/S02:神煞完整性标注 + 柱歧义标记(老 payload 缺 key → 默认值)
        shenshaIncomplete = try c.decodeIfPresent(Bool.self, forKey: .shenshaIncomplete) ?? false
        pillarAmbiguity = try c.decodeIfPresent(PillarAmbiguityDTO.self, forKey: .pillarAmbiguity)
    }

    // Stage 7b:memberwise init(自定义 init(from:) 后失去合成,手写带默认值
    // 让 mock / test 调用兼容)。v1 字段都有默认值,mock 不传也能构造。
    init(
        contentHash: String,
        trueSolarTime: Date?,
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
        yearBranchZodiac: String?,
        yearBranchFriends: [String]?,
        yearBranchClash: String?,
        anchorSentence: String? = nil,
        tenGodWeights: [String: Int] = [:],
        usefulGodCandidates: [String] = [],
        meta: MetaBlockDTO? = nil,
        lateNight: Bool? = nil,
        shenshaIncomplete: Bool = false,
        pillarAmbiguity: PillarAmbiguityDTO? = nil
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
        self.yearBranchFriends = yearBranchFriends
        self.yearBranchClash = yearBranchClash
        self.anchorSentence = anchorSentence
        self.tenGodWeights = tenGodWeights
        self.usefulGodCandidates = usefulGodCandidates
        self.meta = meta
        self.lateNight = lateNight
        self.shenshaIncomplete = shenshaIncomplete
        self.pillarAmbiguity = pillarAmbiguity
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
