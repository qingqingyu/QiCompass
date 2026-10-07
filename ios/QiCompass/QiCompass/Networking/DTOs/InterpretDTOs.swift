import Foundation

// MARK: - Request

/// POST /api/interpret 请求。对齐 backend/app/models/interpret.py:InterpretRequest
///
/// 注意:promptVersion 不在 Request 中(必须来自后端 config.PROMPT_VERSIONS,
/// 禁止客户端决定)。
///
/// Stage 7b 扩展:加 v1 prompt 系统链式调用字段(parentFingerprint)+ 按需模块
/// 用户输入(m4Age/m4CurrentConcern/m5AssetsSummary/m5Preference)。默认 nil
/// 向后兼容老 module(bazi_deep_*/compatibility_*/daily_fortune)调用。
struct InterpretRequest: Codable, Sendable {
    let contentHash: String
    let module: String
    let context: [String: AnyCodableJSON]
    let targetDate: Date?
    let question: AnyCodableJSON?
    /// M3 新增:付费 module(`*_paid`)必填,免费 module 可选。
    /// 用于 entitlement 查询(`(content_hash, module, user_local_id)` 三元组)。
    let userLocalId: String?

    // v1 prompt 系统链式调用字段(Stage 7b 引入)
    /// M0 产出的 structure_fingerprint;M1-M7 必填(M0 自身不需要)。
    /// 用于链式调用缓存隔离 parent_hash 维度。老 module 留 nil。
    let parentFingerprint: String?
    /// M4 健康模块必填:年龄。仅 m4_health module 用。
    let m4Age: Int?
    /// M4 健康模块必填:当前困扰(睡眠/疲劳/体重/情绪)。
    let m4CurrentConcern: String?
    /// M5 财富模块必填:资产/收入概况(可粗略)。
    let m5AssetsSummary: String?
    /// M5 财富模块必填:偏好(保守/平衡/进攻)。
    let m5Preference: String?
    /// context_token(2026-10-07 P0 收口):排盘/合盘/每日端点签发,一刀切
    /// 强制(免费+付费);缺 token → 后端 403 CONTEXT_TOKEN_REQUIRED。
    let contextToken: String?

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case module
        case context
        case targetDate = "target_date"
        case question
        case userLocalId = "user_local_id"
        case parentFingerprint = "parent_fingerprint"
        case m4Age = "m4_age"
        case m4CurrentConcern = "m4_current_concern"
        case m5AssetsSummary = "m5_assets_summary"
        case m5Preference = "m5_preference"
        case contextToken = "context_token"
    }

    init(
        contentHash: String,
        module: String,
        context: [String: AnyCodableJSON],
        targetDate: Date? = nil,
        question: AnyCodableJSON? = nil,
        userLocalId: String? = nil,
        // v1 prompt 系统链式调用字段(默认 nil 向后兼容老 module 调用)
        parentFingerprint: String? = nil,
        m4Age: Int? = nil,
        m4CurrentConcern: String? = nil,
        m5AssetsSummary: String? = nil,
        m5Preference: String? = nil,
        contextToken: String? = nil
    ) {
        self.contentHash = contentHash
        self.module = module
        self.context = context
        self.targetDate = targetDate
        self.question = question
        self.userLocalId = userLocalId
        self.parentFingerprint = parentFingerprint
        self.m4Age = m4Age
        self.m4CurrentConcern = m4CurrentConcern
        self.m5AssetsSummary = m5AssetsSummary
        self.m5Preference = m5Preference
        self.contextToken = contextToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        module = try container.decode(String.self, forKey: .module)
        context = try container.decode([String: AnyCodableJSON].self, forKey: .context)
        if let targetDateString = try container.decodeIfPresent(String.self, forKey: .targetDate) {
            guard let parsed = Self.parseTargetDate(targetDateString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .targetDate,
                    in: container,
                    debugDescription: "target_date must be yyyy-MM-dd"
                )
            }
            targetDate = parsed
        } else {
            targetDate = nil
        }
        question = try container.decodeIfPresent(AnyCodableJSON.self, forKey: .question)
        userLocalId = try container.decodeIfPresent(String.self, forKey: .userLocalId)
        // v1 字段(向后兼容:老 response 不含这些 key,decodeIfPresent 返 nil)
        parentFingerprint = try container.decodeIfPresent(String.self, forKey: .parentFingerprint)
        m4Age = try container.decodeIfPresent(Int.self, forKey: .m4Age)
        m4CurrentConcern = try container.decodeIfPresent(String.self, forKey: .m4CurrentConcern)
        m5AssetsSummary = try container.decodeIfPresent(String.self, forKey: .m5AssetsSummary)
        m5Preference = try container.decodeIfPresent(String.self, forKey: .m5Preference)
        contextToken = try container.decodeIfPresent(String.self, forKey: .contextToken)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(module, forKey: .module)
        try container.encode(context, forKey: .context)
        if let targetDate {
            try container.encode(Self.formatTargetDate(targetDate), forKey: .targetDate)
        } else {
            try container.encodeNil(forKey: .targetDate)
        }
        try container.encodeIfPresent(question, forKey: .question)
        try container.encodeIfPresent(userLocalId, forKey: .userLocalId)
        // v1 字段:nil 不编码(后端 model_validator 按 None 处理,默认空校验通过)
        try container.encodeIfPresent(parentFingerprint, forKey: .parentFingerprint)
        try container.encodeIfPresent(m4Age, forKey: .m4Age)
        try container.encodeIfPresent(m4CurrentConcern, forKey: .m4CurrentConcern)
        try container.encodeIfPresent(m5AssetsSummary, forKey: .m5AssetsSummary)
        try container.encodeIfPresent(m5Preference, forKey: .m5Preference)
        try container.encodeIfPresent(contextToken, forKey: .contextToken)
    }

    private static func formatTargetDate(_ date: Date) -> String {
        targetDateFormatter().string(from: date)
    }

    private static func parseTargetDate(_ value: String) -> Date? {
        targetDateFormatter().date(from: value)
    }

    private static func targetDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
}

// MARK: - Response

/// POST /api/interpret 响应。对齐 backend InterpretResponse
struct InterpretResponse: Codable, Sendable {
    let interpretation: String
    let promptVersion: Int
    let cached: Bool
    let generatedAt: Date
    let provider: String
    let model: String
    /// i18n 决策 10(方案 3):后端实际使用的语言(从 Accept-Language 解析)。
    /// 客户端存入 SwiftData 缓存键对齐用,避免客户端自己解析 Locale 导致不一致。
    let language: String
    /// D10(S7,2026-10-01):译文来源语言(zh / zh-hant / en)。
    /// /api/interpret 恒为 nil;/api/interpret/translate 新翻出译文时 = source_language,
    /// 命中缓存时为 nil(同键内容等价不区分来源)。仅埋点/调试用。
    let translatedFrom: String?

    enum CodingKeys: String, CodingKey {
        case interpretation
        case promptVersion = "prompt_version"
        case cached
        case generatedAt = "generated_at"
        case provider
        case model
        case language
        case translatedFrom = "translated_from"
    }

    init(
        interpretation: String,
        promptVersion: Int,
        cached: Bool,
        generatedAt: Date,
        provider: String,
        model: String,
        language: String,
        translatedFrom: String? = nil
    ) {
        self.interpretation = interpretation
        self.promptVersion = promptVersion
        self.cached = cached
        self.generatedAt = generatedAt
        self.provider = provider
        self.model = model
        self.language = language
        self.translatedFrom = translatedFrom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interpretation = try container.decode(String.self, forKey: .interpretation)
        promptVersion = try container.decode(Int.self, forKey: .promptVersion)
        cached = try container.decode(Bool.self, forKey: .cached)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        provider = try container.decode(String.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        language = try container.decode(String.self, forKey: .language)
        // 老响应无此 key(向后兼容;后端已设默认 null,双保险)
        translatedFrom = try container.decodeIfPresent(String.self, forKey: .translatedFrom)
    }
}

// MARK: - 翻译请求(D10,S7)

/// POST /api/interpret/translate 请求。对齐 backend TranslateRequest(继承
/// InterpretRequest 全字段 + 三个 source_* 字段)。
///
/// wire 形态是**扁平**的(与 InterpretRequest 同级多三键),encode 通过
/// `base.encode(to:)` 复用基类字段写入同一 keyed container——两处字段集
/// 各自维护,不复制粘贴(D10.1「请求体 = 内容按目标语言请求 /api/interpret
/// 时会发的那份」由 DeepAnalysisOrchestrator/CompatibilityOrchestrator 的
/// 共享请求构建器保证)。
struct TranslateRequest: Sendable {
    /// 目标语言请求 /api/interpret 时会发的那份完整请求(含 context /
    /// parent_fingerprint / m4_* / m5_*——缓存键对齐的前提)。
    let base: InterpretRequest
    /// 原文语言(客户端 SwiftData 缓存行的 language)。
    let sourceLanguage: String
    /// 原文的 prompt_version(缓存行携带;过期 → 后端 409 STALE_SOURCE,
    /// 客户端走正常重新生成)。
    let sourcePromptVersion: Int
    /// 原文全文(客户端本地缓存里那份)。
    let sourceInterpretation: String

    enum CodingKeys: String, CodingKey {
        case sourceLanguage = "source_language"
        case sourcePromptVersion = "source_prompt_version"
        case sourceInterpretation = "source_interpretation"
    }
}

extension TranslateRequest: Codable {
    func encode(to encoder: Encoder) throws {
        // 复用 InterpretRequest 的字段写入(同 encoder 的 keyed container)
        try base.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceLanguage, forKey: .sourceLanguage)
        try container.encode(sourcePromptVersion, forKey: .sourcePromptVersion)
        try container.encode(sourceInterpretation, forKey: .sourceInterpretation)
    }

    init(from decoder: Decoder) throws {
        // 同一扁平命名空间读回(测试/mock 往返用;线上只发不收)
        base = try InterpretRequest(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceLanguage = try container.decode(String.self, forKey: .sourceLanguage)
        sourcePromptVersion = try container.decode(Int.self, forKey: .sourcePromptVersion)
        sourceInterpretation = try container.decode(String.self, forKey: .sourceInterpretation)
    }
}

// MARK: - AnyCodableJSON

/// 透传 JSON 值(后端 context 是 dict[str, Any],question 是 Any)。
/// 不引入第三方 AnyCodable 库,自写最小实现。
/// @unchecked Sendable:仅持有 JSON 安全值类型(Bool/Int/Double/String/Array/Dict),无共享可变状态。
struct AnyCodableJSON: Codable, Equatable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let v = try? container.decode(Bool.self) {
            self.value = v
        } else if let v = try? container.decode(Int.self) {
            self.value = v
        } else if let v = try? container.decode(Double.self) {
            self.value = v
        } else if let v = try? container.decode(String.self) {
            self.value = v
        } else if let v = try? container.decode([AnyCodableJSON].self) {
            self.value = v.map { $0.value }
        } else if let v = try? container.decode([String: AnyCodableJSON].self) {
            self.value = v.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let v as Bool:
            try container.encode(v)
        case let v as Int:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as String:
            try container.encode(v)
        case let v as [Any]:
            try container.encode(v.map { AnyCodableJSON($0) })
        case let v as [String: Any]:
            try container.encode(v.mapValues { AnyCodableJSON($0) })
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unsupported JSON value type: \(type(of: value))"
                )
            )
        }
    }

    static func == (lhs: AnyCodableJSON, rhs: AnyCodableJSON) -> Bool {
        switch (lhs.value, rhs.value) {
        case (is NSNull, is NSNull): return true
        case let (l as Bool, r as Bool): return l == r
        case let (l as Int, r as Int): return l == r
        case let (l as Double, r as Double): return l == r
        case let (l as String, r as String): return l == r
        default: return false
        }
    }
}
