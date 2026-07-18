import Foundation

/// 深度解析编排器:组合 apiClient + store + counter + PromptContextBuilder。
///
/// 分两阶段(方案 §三数据流):
/// - 阶段 1 `runCalculation`:排盘 → 存档 ChartSnapshot。失败 throw → `.chartFailed`
/// - 阶段 2 `runInterpretation`:次数检查 → /api/interpret → 存本地缓存。
///   AI 失败 ≠ 排盘失败,独立 throw(由 VM 转 `.interpretFailed`,排盘已存档可见)。
///
/// 关键解耦(方案 §一):
/// - 排盘成功立即存档 + 进 chartReady;AI 子状态独立
/// - 命中后端缓存 cached=True → refund(不消耗每日次数)
/// - AI 失败 → refund(重试不消耗)
/// - 存档失败也 throw(不提示"命盘已保存")
@MainActor
final class DeepAnalysisOrchestrator {
    private let apiClient: APIClient
    private let chartStore: ChartSnapshotStore
    private let interpretStore: InterpretationCacheStore
    private let counter: DailyReadCounter
    private let aiIdentityResolver: AIIdentityResolver

    init(
        apiClient: APIClient,
        chartStore: ChartSnapshotStore,
        interpretStore: InterpretationCacheStore,
        counter: DailyReadCounter,
        aiIdentityResolver: AIIdentityResolver
    ) {
        self.apiClient = apiClient
        self.chartStore = chartStore
        self.interpretStore = interpretStore
        self.counter = counter
        self.aiIdentityResolver = aiIdentityResolver
    }

    // MARK: - 阶段 1:排盘 + 存档

    /// 排盘 → 存档 ChartSnapshot。任一失败 throw(→ `.chartFailed`)。
    func runCalculation(request: BaziCalculateRequest) async throws -> BaziResponse {
        let response = try await AppLogger.measure(
            AppLogger.networking,
            operation: "calculateBazi",
            context: [
                "birth": Self.isoFormatter.string(from: request.birthDatetime),
                "gender": request.gender,
                "city": request.city ?? "nil",
            ]
        ) {
            try await self.apiClient.calculateBazi(request: request)
        }

        AppLogger.app.info("calc.ok contentHash=\(response.contentHash, privacy: .public) pillars=\(response.pillars.year.ganZhi, privacy: .public)/\(response.pillars.month.ganZhi, privacy: .public)/\(response.pillars.day.ganZhi, privacy: .public)/\(response.pillars.hour.ganZhi, privacy: .public)")

        // 存档(失败 throw → chartFailed,不提示"命盘已保存")
        _ = try chartStore.upsert(response: response, request: request)

        return response
    }

    // MARK: - 阶段 2:AI 命书

    /// AI 命书:次数检查 → /api/interpret → 存本地缓存。
    /// - 达上限抛 `DeepAnalysisError.dailyLimitReached`
    /// - 其他失败抛原 error(AI 失败退款,重试不消耗)
    ///
    /// M3c 新增:`module` 参数让 DeepAnalysisViewModel 切 `bazi_deep_free` / `_paid`。
    /// 默认 `bazi_deep` alias(向后兼容老调用方)。
    /// counter 共享配额用基础名 `bazi_deep`,与 module 参数解耦。
    func runInterpretation(
        response: BaziResponse,
        request: BaziCalculateRequest,
        module: String = "bazi_deep"
    ) async throws -> InterpretResponse {
        // 次数检查(全局池口径,固定基础名;_free / _paid 共享每日 10 次)
        let counterModule = "bazi_deep"
        guard counter.tryConsume(module: counterModule) else {
            throw DeepAnalysisError.dailyLimitReached(
                nextReset: counter.nextResetDate(),
                remaining: 0
            )
        }

        var shouldRefundOnFailure = true

        do {
            let context = PromptContextBuilder.build(response: response, request: request)
            let req = InterpretRequest(
                contentHash: response.contentHash,
                module: module,
                context: context,
                targetDate: nil,
                question: nil,
                userLocalId: UserIdentity.userLocalId
            )
            let resp = try await AppLogger.measure(
                AppLogger.networking,
                operation: "interpret",
                context: [
                    "content_hash": response.contentHash,
                    "module": module,
                ]
            ) {
                try await self.apiClient.interpret(request: req)
            }

            AppLogger.app.info("interpret.ok contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) pv=\(resp.promptVersion) cached=\(resp.cached)")

            // 命中后端缓存 → 退款(命中缓存不消耗每日次数)。
            // 后续本地写失败不能再次退款,避免多还一次全局额度。
            if resp.cached {
                counter.refund(module: counterModule)
                shouldRefundOnFailure = false
            }

            // 存本地缓存。失败必须传导到 UI,不能返回"命书成功但缓存失败"的假成功。
            try await AppLogger.measure(
                AppLogger.persistence,
                operation: "interpretationCache.upsert",
                context: [
                    "content_hash": response.contentHash,
                    "module": module,
                    "prompt_version": String(resp.promptVersion),
                ]
            ) {
                try interpretStore.upsert(
                    contentHash: response.contentHash,
                    module: module,
                    promptVersion: resp.promptVersion,
                    targetDate: nil,
                    provider: resp.provider,
                    model: resp.model,
                    interpretation: resp.interpretation,
                    generatedAt: resp.generatedAt
                )
            }

            return resp
        } catch let error as DeepAnalysisError {
            // dailyLimitReached 不退款(没消耗成功)
            throw error
        } catch {
            // AI / 本地缓存失败 → 退款(重试不消耗)
            if shouldRefundOnFailure {
                counter.refund(module: counterModule)
            }
            AppLogger.app.error("interpret.pipeline_failed contentHash=\(response.contentHash, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// 查询本地缓存最新一条(用于 UI 瞬时显示,方案 §4.5 v1 简化:不跳过网络)。
    /// 错误处理:fetch 失败记录日志后继续 throw,调用方必须进入 UI 错误路径。
    func localCachedInterpretation(
        contentHash: String,
        module: String
    ) async throws -> (text: String, promptVersion: Int)? {
        do {
            let identity = try await aiIdentityResolver.resolve()
            guard let cache = try interpretStore.getLatest(
                contentHash: contentHash,
                module: module,
                targetDate: nil,
                identity: identity
            ) else {
                return nil
            }
            return (cache.interpretation, cache.promptVersion)
        } catch {
            AppLogger.persistence.error(
                "interpretationCache.getLatest failed hash=\(contentHash, privacy: .public) module=\(module, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// 剩余次数(全局池,VM 用于 UI 展示)。
    func remainingReads() -> Int {
        counter.remaining()
    }

    /// 下次重置时间(达上限时用于倒计时)。
    func nextDailyReset() -> Date {
        counter.nextResetDate()
    }

    // MARK: - Private

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - DeepAnalysisError

/// 深度解析领域错误。
enum DeepAnalysisError: Error, LocalizedError {
    /// 每日次数已达上限。nextReset: 本地午夜;remaining: 剩余次数(0)。
    case dailyLimitReached(nextReset: Date, remaining: Int)

    var errorDescription: String? {
        switch self {
        case .dailyLimitReached:
            return "今日机缘已尽,明日再来"
        }
    }
}
