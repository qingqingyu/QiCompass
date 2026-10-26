import DeviceCheck
import Foundation

// MARK: - 作答返回(S4c,协议载荷)

/// `DailyAskAnswering.reply` 的返回:正文 + 追问候选 + 缓存命中 + 服务端余额。
/// balance 可选(FakeAnswerer/占位实现免填);cached 仅作 UI 参考
/// (命中免费秒回,渲染与扣费语义同路,无特殊分支)。
struct DailyAskReply: Equatable, Sendable {
    let text: String
    let followUps: [String]
    let cached: Bool
    let balance: Int?
}

// MARK: - 真作答服务(S4c,替换 ServicePendingAskAnswerer 占位)

/// 问事作答真实现:组 `POST /api/bazi/daily-ask` 请求(上下文快照在
/// DailyAskContext,make 时点由 MainView 组装),history/question 纵深截断
/// (服务端整单 >20 轮 422、每轮 ≤2000、问题 ≤200——模型层已截,这里再防)。
struct LiveDailyAskAnswerer: DailyAskAnswering {
    let apiClient: APIClient
    let context: DailyAskContext

    func reply(to question: String, history: [DailyAskTurn]) async throws -> DailyAskReply {
        let clampedQuestion = String(question.prefix(200))
        if clampedQuestion.count < question.count {
            AppLogger.app.info("op=dailyAsk.questionClamped raw_len=\(question.count, privacy: .public) -> 200")
        }
        let clampedHistory = history.suffix(20).map { turn in
            DailyAskTurn(role: turn.role, text: String(turn.text.prefix(2000)))
        }
        let request = DailyAskRequest(
            contentHash: context.contentHash,
            context: context.context,
            contextToken: context.contextToken,
            targetDate: context.targetDate,
            userLocalId: UserIdentity.userLocalId,
            question: clampedQuestion,
            history: clampedHistory,
            dailyInterpretation: context.dailyInterpretation,
            // 铸造职责单一归 AskWalletModel.refresh(首查 balance 带 token);
            // 作答请求恒不带,后端对老身份不再查 DeviceCheck
            deviceToken: nil
        )
        let response = try await apiClient.dailyAsk(request: request)
        return DailyAskReply(
            text: response.answer,
            followUps: response.followUps,
            cached: response.cached,
            balance: response.balance
        )
    }
}

// MARK: - 请求上下文快照(make 时点组装,随 askModel 重建)

/// 一次问事对话所需的全部请求上下文(命盘 + 今日 + token + 解读正文)。
/// 值快照而非 provider 闭包:pristine 重建语义(syncAskModel)下,解读态
/// 变化即换新快照;开口后对话保留 = 旧快照随行——作答须与用户开口时所见
/// 一致,追新反而错位。
struct DailyAskContext: Sendable {
    let contentHash: String
    /// daily_fortune 同契约 15 字段(PromptContextBuilder.buildDailyFortune 产出,
    /// 核心字段须与 context_token 绑定集一致)
    let context: [String: AnyCodableJSON]
    /// daily 族 token(daily-fortune 响应签发,当日有效)
    let contextToken: String
    let targetDate: Date
    /// 回传客户端已渲染的五段解读正文(≤4096,构造时已 clamp)
    let dailyInterpretation: String

    /// 解读正文重建:把 interpretState 里的原始文本重连成「屏上所渲染的
    /// 五段正文」。口径与 DailyInterpretationSection 渲染同源——
    /// - okFree/okPaid/离线兜底:DailyInsight.parse 成功 → 五段值以 \n 连
    ///   (label 是 UI 骨架,不进上下文);parse nil(畸形 JSON)→ 引擎模板
    ///   同款重连(= 降级态屏上正文)
    /// - offlineLegacy(v3 散文):parse nil → 原文透传(散文没有五段可拆)
    /// - 其余未就绪态(idle/fetching/failed/lockedPaid/dailyLimitReached/
    ///   contextTokenExpired):引擎模板同款重连(降级态屏上渲染的就是它)
    /// - 统一 prefix(4096) clamp + 日志(服务端 max_length=4096)
    static func interpretationText(for state: InterpretState, relation: String) -> String {
        let joined: String
        switch state {
        case .okFree(let text, _), .okPaid(let text, _):
            joined = Self.fiveParagraphs(text, relation: relation)
        case .offlineLegacy(let text, _):
            if let insight = DailyInsight.parse(text) {
                joined = Self.joined(insight)
            } else if DailyInsight.looksLikeJSON(text) {
                // 畸形 v4 快照(缓存毒化残留):屏上兜底渲染引擎模板
                // (DailyInterpretationSection 三分支同款判定),context 同路
                joined = Self.joined(EngineReadingTemplates.insight(for: relation))
            } else {
                joined = text  // v3 散文快照:原文即屏上正文
            }
        case .idle, .fetching, .failed, .lockedPaid, .dailyLimitReached, .contextTokenExpired:
            joined = Self.joined(EngineReadingTemplates.insight(for: relation))
        }
        guard joined.count > 4096 else { return joined }
        AppLogger.app.info("op=dailyAsk.interpretationClamped raw_len=\(joined.count, privacy: .public) -> 4096")
        return String(joined.prefix(4096))
    }

    /// 五段正文重连:parse 成功用真值,失败回落引擎模板(与屏上降级同路)。
    private static func fiveParagraphs(_ text: String, relation: String) -> String {
        if let insight = DailyInsight.parse(text) {
            return joined(insight)
        }
        return joined(EngineReadingTemplates.insight(for: relation))
    }

    private static func joined(_ insight: DailyInsight) -> String {
        [insight.headline, insight.work, insight.relationships, insight.energy, insight.reminder]
            .joined(separator: "\n")
    }
}

// MARK: - 问事钱包(全局余额,server 单一事实源)

/// 问事次数余额(试用 3 次 + 次数包合计,不绑盘不绑日永不过期)。
/// AppEnvironment 级持有(MainView 换盘/换日重建不丢);server 是单一
/// 事实源,内存只缓存最近值——每次作答响应 / 赎回 / 首查都回写。
@MainActor
final class AskWalletModel: ObservableObject {
    /// nil = 未查询(UI 不显示余额签);0 = 耗尽(问事框切加购形态)
    @Published private(set) var balance: Int?

    private let apiClient: APIClient
    /// DeviceCheck token 供给(默认真实现;测试注入假供给——模拟器不支持
    /// DeviceCheck,不注入则「首查带 token」语义不可测)
    private let tokenProvider: @Sendable () async -> String?
    /// 「已尝试铸造」flag:首次 balance 查询带 device_token(装机即领 3 次
    /// 的 DeviceCheck 防重装锚点),无论后端接受还是拒绝(已铸过/限铸拦)
    /// 都不再带——重复送无意义;仅未出网的失败(networkError/encodingError
    /// 等,请求未达后端)不置,下次再试。
    private static let mintAttemptedKey = "qicompass.ask.mint_attempted.v1"
    /// apply 乱序守卫:作答响应与 refresh 并发回写时只认最新时点的值
    private var lastIssuedAt = Date.distantPast

    init(
        apiClient: APIClient,
        tokenProvider: @escaping @Sendable () async -> String? = DeviceCheckTokenProvider.token
    ) {
        self.apiClient = apiClient
        self.tokenProvider = tokenProvider
    }

    /// 查询余额(今日页 .task 触发一次;不轮询)。首次附带 DeviceCheck
    /// token 触发后端懒铸造 3 次试用。
    func refresh() async {
        let attempted = UserDefaults.standard.bool(forKey: Self.mintAttemptedKey)
        let deviceToken: String? = attempted ? nil : await tokenProvider()
        do {
            let response = try await apiClient.askBalance(
                userLocalId: UserIdentity.userLocalId,
                deviceToken: deviceToken
            )
            if !attempted {
                UserDefaults.standard.set(true, forKey: Self.mintAttemptedKey)
            }
            apply(response.balance)
            AppLogger.app.info("op=askWallet.refresh ok balance=\(response.balance, privacy: .public)")
        } catch {
            // 显式传播:错误进日志;请求已达后端(铸造已发生或已被拒)则置
            // flag;未出网(networkError/encodingError/未知错误)保留 flag
            // 未置,下次 refresh 再带 token——重送 token 后端幂等,归错类
            // 才会永久丢铸造锚点
            let reachedBackend: Bool
            switch error as? APIError {
            case .backendError, .httpError, .decodingError:
                reachedBackend = true
            case .networkError, .encodingError, nil:
                reachedBackend = false
            }
            if !attempted && reachedBackend {
                UserDefaults.standard.set(true, forKey: Self.mintAttemptedKey)
            }
            AppLogger.app.error(
                "op=askWallet.refresh failed reached_backend=\(reachedBackend, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    /// 回写余额(作答响应 / 赎回响应 / refresh 共用)。issuedAt 单调守卫:
    /// 忽略比最近一次回写更早时点的值(乱序竞态只丢过期数据,不回卷)。
    func apply(_ balance: Int, issuedAt: Date = .now) {
        guard issuedAt >= lastIssuedAt else {
            AppLogger.app.info("op=askWallet.apply_stale_dropped balance=\(balance, privacy: .public)")
            return
        }
        lastIssuedAt = issuedAt
        self.balance = balance
    }
}

// MARK: - DeviceCheck token(防重装指纹,模拟器/失败降级 nil)

/// Apple DeviceCheck(跨重装 2 比特):generateToken 返回含 JWT 文本的
/// Data,按 UTF-8 字符串直传后端(后端转发 Apple devicecheck API 验证;
/// base64 再包一层会腐蚀令牌)。模拟器不支持 / 生成失败 → nil 显式降级,
/// 后端走纯 IP 限铸闸(已核实 service.py 该降级路径),不视作错误。
enum DeviceCheckTokenProvider {
    static func token() async -> String? {
        guard DCDevice.current.isSupported else {
            AppLogger.app.info("op=deviceCheck.unsupported simulator_or_device")
            return nil
        }
        do {
            let data = try await DCDevice.current.generateToken()
            guard let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                // Data 非合法 UTF-8:显式记日志降级,不猜编码
                AppLogger.app.error("op=deviceCheck.token_decode_failed bytes=\(data.count, privacy: .public)")
                return nil
            }
            return token
        } catch {
            AppLogger.app.error("op=deviceCheck.generate_failed error=\(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
