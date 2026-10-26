import Foundation

// MARK: - 次数包 SKU 常量(S4c)

/// 问事次数包 SKU(MONETIZATION.md §问事窗,2026-10-25 拍板)。
///
/// 与 backend `config.ASK_PACK_PRODUCT_ID` 双端一致,但它**不是 module 权益**:
/// 不入 PRODUCT_MODULE_MAP / AppleProductID / module(forProductID:) /
/// restorePurchases 的 SKU 集合(check_sku_sync ①-④ 只管 entitlement SKU,
/// 误入会被 ③ 判 FAIL——那是护栏按设计工作)。入账走 `POST /api/ask/redeem`
/// 独立钱包台账(ask_credits,不绑 content_hash)。
/// 三方一致性(backend config ↔ 此常量 ↔ Products.storekit)由
/// `tools/check_sku_sync.py` 第⑤节锁定(2026-10-26 用户拍板扩栏)。
enum AskPackProductID {
    /// 15 问次数包($4.99,Consumable)
    static let pack15 = "com.qicompass.daily_ask.pack15"
}

// MARK: - 作答(DailyAskTurn / DailyAskRequest / DailyAskResponse)

/// 对话上文一轮。对齐 backend/app/models/daily_ask.py:DailyAskTurn
/// (role 限 "user"/"ai";服务端整单 ≤20 轮、每轮 ≤2000 字,超限整单 422,
/// 截断职责在客户端)。
struct DailyAskTurn: Codable, Sendable, Equatable {
    let role: String
    let text: String

    init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

/// POST /api/bazi/daily-ask 请求。对齐 backend/app/models/daily_ask.py:DailyAskRequest
///
/// `targetDate` 与 DailyFortuneRequest 同款**单字段自定义 encode/decode** 为
/// `yyyy-MM-dd`(本地时区):后端 `target_date: datetime.date` 严格拒绝带时间
/// 分量的字符串,APICoder 全局 `.iso8601` 会带时分秒 → 422。
struct DailyAskRequest: Codable, Sendable {
    let contentHash: String
    /// 盘面上下文(daily_fortune 同契约 15 字段,PromptContextBuilder.
    /// buildDailyFortune 产出;核心字段须与 context_token 一致)
    let context: [String: AnyCodableJSON]
    /// daily 族 context_token(daily-fortune 响应签发,当日有效)
    var contextToken: String?
    let targetDate: Date
    /// 钱包 owner(匿名必填;登录时 Bearer 由 LiveAPIClient 注入,后端 user_id 优先)
    let userLocalId: String?
    /// 本轮提问(≤200 字,超限由 answerer 截断——服务端超限 422)
    let question: String
    /// 对话上文(≤20 轮;服务端只注入末 6 轮)
    let history: [DailyAskTurn]
    /// 今日解读正文(回传客户端已渲染的五段文本;1-4096 字)
    let dailyInterpretation: String
    /// Apple DeviceCheck token(仅首次铸造试用随 balance 查询带;
    /// 作答请求恒不带——铸造职责单一归 AskWalletModel.refresh)
    let deviceToken: String?

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case context
        case contextToken = "context_token"
        case targetDate = "target_date"
        case userLocalId = "user_local_id"
        case question
        case history
        case dailyInterpretation = "daily_interpretation"
        case deviceToken = "device_token"
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: Codable override(target_date 单字段 yyyy-MM-dd,照 DailyFortuneRequest 先例)

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(contentHash, forKey: .contentHash)
        try c.encode(context, forKey: .context)
        try c.encodeIfPresent(contextToken, forKey: .contextToken)
        try c.encode(Self.isoDateFormatter.string(from: targetDate), forKey: .targetDate)
        try c.encodeIfPresent(userLocalId, forKey: .userLocalId)
        try c.encode(question, forKey: .question)
        try c.encode(history, forKey: .history)
        try c.encode(dailyInterpretation, forKey: .dailyInterpretation)
        try c.encodeIfPresent(deviceToken, forKey: .deviceToken)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentHash = try c.decode(String.self, forKey: .contentHash)
        context = try c.decode([String: AnyCodableJSON].self, forKey: .context)
        contextToken = try c.decodeIfPresent(String.self, forKey: .contextToken)
        let dateStr = try c.decode(String.self, forKey: .targetDate)
        guard let parsed = Self.isoDateFormatter.date(from: dateStr) else {
            throw DecodingError.dataCorruptedError(
                forKey: .targetDate, in: c,
                debugDescription: "target_date 无法按 yyyy-MM-dd 解析: \(dateStr)"
            )
        }
        targetDate = parsed
        userLocalId = try c.decodeIfPresent(String.self, forKey: .userLocalId)
        question = try c.decode(String.self, forKey: .question)
        history = try c.decode([DailyAskTurn].self, forKey: .history)
        dailyInterpretation = try c.decode(String.self, forKey: .dailyInterpretation)
        deviceToken = try c.decodeIfPresent(String.self, forKey: .deviceToken)
    }

    init(
        contentHash: String,
        context: [String: AnyCodableJSON],
        contextToken: String?,
        targetDate: Date,
        userLocalId: String?,
        question: String,
        history: [DailyAskTurn],
        dailyInterpretation: String,
        deviceToken: String? = nil
    ) {
        self.contentHash = contentHash
        self.context = context
        self.contextToken = contextToken
        self.targetDate = targetDate
        self.userLocalId = userLocalId
        self.question = question
        self.history = history
        self.dailyInterpretation = dailyInterpretation
        self.deviceToken = deviceToken
    }
}

/// POST /api/bazi/daily-ask 响应。对齐 backend/app/models/daily_ask.py:DailyAskResponse
struct DailyAskResponse: Codable, Sendable, Equatable {
    let answer: String
    /// 1-3 条「接着问」候选(LLM 产出,服务端只做契约校验)
    let followUps: [String]
    /// true = 命中跨用户共享缓存(未调 LLM、未扣次数,免费秒回)
    let cached: Bool
    /// 本次之后的剩余次数(试用 + 钱包合计;iOS 展示用)
    let balance: Int

    enum CodingKeys: String, CodingKey {
        case answer
        case followUps = "follow_up_suggestions"
        case cached
        case balance
    }
}

// MARK: - 余额(GET /api/ask/balance)

/// GET /api/ask/balance 响应。对齐 backend/app/models/daily_ask.py:AskBalanceResponse
/// (首次查询自动铸造 3 次试用——「装机即领」的懒铸造入口)。
struct AskBalanceResponse: Codable, Sendable, Equatable {
    let balance: Int
}

// MARK: - 次数包赎回(POST /api/ask/redeem)

/// POST /api/ask/redeem 请求。对齐 backend/app/models/daily_ask.py:AskRedeemRequest
/// (iOS StoreKit 2 完成购买后调;transaction_id 为纯 Apple id 字符串非 JWS,
/// 服务端自己调 App Store Server API 验证)。
struct AskRedeemRequest: Codable, Sendable, Equatable {
    let transactionId: String
    let productId: String
    let userLocalId: String?

    enum CodingKeys: String, CodingKey {
        case transactionId = "transaction_id"
        case productId = "product_id"
        case userLocalId = "user_local_id"
    }
}

/// POST /api/ask/redeem 响应。对齐 backend/app/models/daily_ask.py:AskRedeemResponse
/// (幂等:同 transaction_id 重放 → credits=0、余额不动)。
struct AskRedeemResponse: Codable, Sendable, Equatable {
    /// 本单入账次数(重放为 0)
    let credits: Int
    /// 入账后剩余次数
    let balance: Int
    let transactionId: String
    /// ISO 字符串原样保留(仅展示/日志用,不参与本地时间计算,不转 Date)
    let purchasedAt: String

    enum CodingKeys: String, CodingKey {
        case credits
        case balance
        case transactionId = "transaction_id"
        case purchasedAt = "purchased_at"
    }
}
