import Foundation

// MARK: - Request

/// POST /api/interpret 请求。对齐 backend/app/models/interpret.py:InterpretRequest
///
/// 注意:promptVersion 不在 Request 中(必须来自后端 config.PROMPT_VERSIONS,
/// 禁止客户端决定)。
struct InterpretRequest: Codable, Sendable {
    let contentHash: String
    let module: String
    let context: [String: AnyCodableJSON]
    let targetDate: Date?
    let question: AnyCodableJSON?
    /// M3 新增:付费 module(`*_paid`)必填,免费 module 可选。
    /// 用于 entitlement 查询(`(content_hash, module, user_local_id)` 三元组)。
    let userLocalId: String?

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case module
        case context
        case targetDate = "target_date"
        case question
        case userLocalId = "user_local_id"
    }

    init(
        contentHash: String,
        module: String,
        context: [String: AnyCodableJSON],
        targetDate: Date? = nil,
        question: AnyCodableJSON? = nil,
        userLocalId: String? = nil
    ) {
        self.contentHash = contentHash
        self.module = module
        self.context = context
        self.targetDate = targetDate
        self.question = question
        self.userLocalId = userLocalId
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
