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
        m5Preference: String? = nil
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

    enum CodingKeys: String, CodingKey {
        case interpretation
        case promptVersion = "prompt_version"
        case cached
        case generatedAt = "generated_at"
        case provider
        case model
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
