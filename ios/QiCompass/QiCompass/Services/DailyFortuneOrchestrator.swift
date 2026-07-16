import Foundation

/// 每日运势编排器:组合 apiClient + dailyStore + interpretStore + chartStore + counter。
///
/// 分两阶段(决策 §3.2):
/// - 阶段 1 `runDeterministic`:查 ChartSnapshot → 算 businessDate → 查 daily 缓存
///   → 未命中 POST /api/bazi/daily-fortune → upsert DailyFortuneSnapshot
/// - 阶段 2 `runInterpretation`:查 InterpretationCache(24h) → 未命中 tryConsume
///   → POST /api/interpret → refund on cache/failure → upsert + 同步更新 snapshot.interpretation
///
/// 关键解耦(决策 §1.B / §3.2):
/// - 两层缓存职责分离:DailyFortuneSnapshot 走日粒度 cachedUntil;AI 缓存走 generatedAt+24h
/// - 后端 AI 缓存命中 → refund;失败 → refund(重试不消耗)
/// - chart_payload 从存档 ChartSnapshot 解出,作为可信源传给后端,服务端无状态
@MainActor
final class DailyFortuneOrchestrator {
    private let apiClient: APIClient
    private let dailyStore: DailyFortuneSnapshotStore
    private let interpretStore: InterpretationCacheStore
    private let chartStore: ChartSnapshotStore
    private let counter: DailyReadCounter
    private let aiIdentityResolver: AIIdentityResolver

    init(
        apiClient: APIClient,
        dailyStore: DailyFortuneSnapshotStore,
        interpretStore: InterpretationCacheStore,
        chartStore: ChartSnapshotStore,
        counter: DailyReadCounter,
        aiIdentityResolver: AIIdentityResolver
    ) {
        self.apiClient = apiClient
        self.dailyStore = dailyStore
        self.interpretStore = interpretStore
        self.chartStore = chartStore
        self.counter = counter
        self.aiIdentityResolver = aiIdentityResolver
    }

    // MARK: - 阶段 1:确定性排盘

    /// 取当前用户 ChartSnapshot,算 businessDate,查缓存或重排。
    ///
    /// - Parameters:
    ///   - chartHash: 当前命盘 contentHash(由 VM 从 UserSnapshotLink/最近快照取)
    ///   - ziHourRule: 当前命盘的子时规则(来自 ChartSnapshot.ziHourRule)
    ///   - businessDate: VM 算好的业务日期(决策 §3.6,不传 now 以让 VM 控制)
    ///   - forceRefresh: true 时跳过本地缓存,强制重调后端
    /// - Returns: DailyFortuneResponse(新鲜或缓存)+ 是否来自缓存
    func runDeterministic(
        chartHash: String,
        ziHourRule: String,
        businessDate: Date,
        forceRefresh: Bool = false
    ) async throws -> (response: DailyFortuneResponse, fromCache: Bool) {
        // 1. 取存档 ChartSnapshot(无 → chartMissing)
        guard let snapshot = try chartStore.get(contentHash: chartHash) else {
            throw DailyFortuneError.chartMissing
        }
        let baziResponse = try chartStore.decodeResponse(from: snapshot)
        let chartPayload = ChartPayloadDTO.from(baziResponse: baziResponse)

        // 2. 查本地 daily 缓存(非强制刷新时)
        if !forceRefresh,
            let cached = try dailyStore.getCachedIfFresh(
                chartHash: chartHash, targetDate: businessDate
            ) {
            let response = try dailyStore.response(from: cached)
            AppLogger.app.info(
                "daily.deterministic.cache_hit hash=\(chartHash, privacy: .public) targetDate=\(businessDate, privacy: .public)"
            )
            return (response, true)
        }

        // 3. 未命中 → POST /api/bazi/daily-fortune
        let request = DailyFortuneRequest(
            chartHash: chartHash,
            targetDate: businessDate,
            chartPayload: chartPayload,
        )
        let response = try await AppLogger.measure(
            AppLogger.networking,
            operation: "dailyFortune",
            context: [
                "chart_hash": chartHash,
                "target_date": Self.dateFormatter.string(from: businessDate),
            ]
        ) {
            try await self.apiClient.dailyFortune(request: request)
        }

        // 4. upsert(缓存判据:businessDate 本地 23:59:59 + 1s)
        let cachedUntil = BusinessDateCalculator.cachedUntil(forBusinessDate: businessDate)
        try dailyStore.upsert(
            chartHash: chartHash,
            targetDate: businessDate,
            response: response,
            interpretation: "",  // AI 解读后续阶段写入
            cachedUntil: cachedUntil
        )

        AppLogger.app.info(
            "daily.deterministic.ok hash=\(chartHash, privacy: .public) dayPillar=\(response.dayPillar, privacy: .public) lunarDate=\(response.lunarDate, privacy: .public)"
        )
        return (response, false)
    }

    // MARK: - 阶段 2:AI 解读

    /// 查 InterpretationCache(24h) → 未命中 tryConsume → POST /api/interpret。
    /// 后端缓存命中 → refund;失败 → refund。
    /// 同时更新 DailyFortuneSnapshot.interpretation,让 7 天历史回看能直接显示原解读。
    func runInterpretation(
        chartHash: String,
        chartPayload: ChartPayloadDTO,
        dailyResponse: DailyFortuneResponse,
        businessDate: Date
    ) async throws -> InterpretResponse {
        let module = "daily_fortune"
        let targetDate = businessDate

        // 1. 查本地 24h AI 缓存
        let identity = try await aiIdentityResolver.resolve()
        if let cached = try interpretStore.getLatest(
            contentHash: chartHash,
            module: module,
            targetDate: targetDate,
            identity: identity
        ),
            cached.generatedAt.addingTimeInterval(24 * 3600) > .now {
            // 命中本地 24h 缓存:构造 InterpretResponse(标 cached=true,generatedAt=原时间)
            let resp = InterpretResponse(
                interpretation: cached.interpretation,
                promptVersion: cached.promptVersion,
                cached: true,
                generatedAt: cached.generatedAt,
                provider: identity.provider,
                model: identity.model
            )
            try dailyStore.updateInterpretation(
                cached.interpretation,
                forChartHash: chartHash,
                targetDate: targetDate,
                provider: identity.provider,
                model: identity.model
            )
            AppLogger.app.info(
                "daily.interpret.cache_hit hash=\(chartHash, privacy: .public) targetDate=\(targetDate, privacy: .public)"
            )
            return resp
        }

        // 2. 次数检查(全局池口径,方案 §D1)
        guard counter.tryConsume(module: module) else {
            throw DeepAnalysisError.dailyLimitReached(
                nextReset: counter.nextResetDate(),
                remaining: 0
            )
        }

        var shouldRefundOnFailure = true

        do {
            let context = PromptContextBuilder.buildDailyFortune(
                chartPayload: chartPayload,
                response: dailyResponse,
                businessDate: businessDate
            )
            let req = InterpretRequest(
                contentHash: chartHash,
                module: module,
                context: context,
                targetDate: targetDate,
                question: nil
            )
            let resp = try await AppLogger.measure(
                AppLogger.networking,
                operation: "dailyInterpret",
                context: [
                    "chart_hash": chartHash,
                    "module": module,
                    "target_date": Self.dateFormatter.string(from: targetDate),
                ]
            ) {
                try await self.apiClient.interpret(request: req)
            }

            AppLogger.app.info(
                "daily.interpret.ok hash=\(chartHash, privacy: .public) pv=\(resp.promptVersion) cached=\(resp.cached)"
            )

            // 命中后端缓存 → refund。后续失败不能再次 refund,避免双退款多还一次额度。
            if resp.cached {
                counter.refund(module: module)
                shouldRefundOnFailure = false
            }

            // 写本地 AI 缓存。失败必须传导到 UI,避免返回假成功。
            do {
                try interpretStore.upsert(
                    contentHash: chartHash,
                    module: module,
                    promptVersion: resp.promptVersion,
                    targetDate: targetDate,
                    provider: resp.provider,
                    model: resp.model,
                    interpretation: resp.interpretation,
                    generatedAt: resp.generatedAt
                )
            } catch {
                AppLogger.persistence.error(
                    "daily.interpret.cacheWrite_failed hash=\(chartHash, privacy: .public) targetDate=\(targetDate, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                throw error
            }

            // 同步更新 DailyFortuneSnapshot.interpretation,让历史回看直接显示。
            // 失败必须传导到 UI,避免本地状态与成功提示不一致。
            do {
                try dailyStore.updateInterpretation(
                    resp.interpretation,
                    forChartHash: chartHash,
                    targetDate: targetDate,
                    provider: resp.provider,
                    model: resp.model
                )
            } catch {
                AppLogger.persistence.error(
                    "daily.interpret.snapshotSync_failed hash=\(chartHash, privacy: .public) targetDate=\(targetDate, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                throw error
            }

            return resp
        } catch let error as DeepAnalysisError {
            throw error
        } catch {
            if shouldRefundOnFailure {
                counter.refund(module: module)
            }
            AppLogger.app.error(
                "daily.interpret.failed hash=\(chartHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// 剩余次数(全局池,VM 用于 UI 展示)。
    func remainingReads() -> Int {
        counter.remaining()
    }

    /// 下次重置时间(本地午夜,达上限时用于倒计时)。
    func nextDailyReset() -> Date {
        counter.nextResetDate()
    }

    /// 查询本地 24h AI 缓存(用于阶段 1 完成后立即显示已缓存解读)。
    /// 失败 throw 上抛,由调用方转换为解读错误态。
    func cachedInterpretationIfFresh(
        chartHash: String, targetDate: Date
    ) async throws -> (text: String, promptVersion: Int)? {
        let module = "daily_fortune"
        let identity = try await aiIdentityResolver.resolve()
        guard let cached = try interpretStore.getLatest(
            contentHash: chartHash,
            module: module,
            targetDate: targetDate,
            identity: identity
        ),
            cached.generatedAt.addingTimeInterval(24 * 3600) > .now
        else {
            return nil
        }
        try dailyStore.updateInterpretation(
            cached.interpretation,
            forChartHash: chartHash,
            targetDate: targetDate,
            provider: identity.provider,
            model: identity.model
        )
        return (cached.interpretation, cached.promptVersion)
    }

    // MARK: - Private

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}

// MARK: - DailyFortuneError

/// 每日运势领域错误。
enum DailyFortuneError: Error, LocalizedError {
    /// 找不到当前用户的 ChartSnapshot(需先完成深度解析)
    case chartMissing

    var errorDescription: String? {
        switch self {
        case .chartMissing:
            return "需先完成深度解析,才能查看每日运势"
        }
    }
}

// MARK: - DailyFortuneSnapshotStore helpers(放此处避免 Store 过胖)

extension DailyFortuneSnapshotStore {
    /// 从存档 DailyFortuneSnapshot 重建 DailyFortuneResponse(给阶段 2 与 VM 复用)。
    /// calcRuleSnapshot 用空占位(daily-fortune 后端返回的 calcRuleSnapshot 不用于 UI 关键路径)。
    func response(from snapshot: DailyFortuneSnapshot) throws -> DailyFortuneResponse {
        let hours = try decodeHourPillars(from: snapshot)
        let tomorrow = try decodeTomorrowPreview(from: snapshot)
        return DailyFortuneResponse(
            dayPillar: snapshot.dayPillar,
            dayRelationToDayMaster: snapshot.dayRelation,
            dayChong: snapshot.dayChong,
            dayChongTargets: snapshot.dayChongTargets,
            hourPillars: hours,
            currentHourIndex: nil,
            lunarDate: snapshot.lunarDate,
            huangliYi: snapshot.huangliYi,
            huangliJi: snapshot.huangliJi,
            tomorrowPreview: tomorrow ?? TomorrowPreviewDTO(
                dayPillar: "", dayRelation: "", dayChong: nil
            ),
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "", sect: 1, ziHourRule: "",
                trueSolarLongitude: 0, trueSolarOffsetMinutes: 0,
                schemaVersion: 1
            )
        )
    }
}

// MARK: - ChartPayloadDTO 转换 helper

extension ChartPayloadDTO {
    /// 从存档 BaziResponse 解出 chart_payload(决策 §1.A,客户端可信源)。
    static func from(baziResponse: BaziResponse) -> ChartPayloadDTO {
        let p = baziResponse.pillars
        return ChartPayloadDTO(
            dayMaster: p.day.gan,
            dayMasterElement: p.day.ganElement,
            dayMasterStrength: baziResponse.dayMasterStrength ?? "special_pattern",
            favorableElements: baziResponse.favorableElements,
            unfavorableElements: baziResponse.unfavorableElements,
            fourPillars: [
                "year": PillarRefDTO(gan: p.year.gan, zhi: p.year.zhi),
                "month": PillarRefDTO(gan: p.month.gan, zhi: p.month.zhi),
                "day": PillarRefDTO(gan: p.day.gan, zhi: p.day.zhi),
                "hour": PillarRefDTO(gan: p.hour.gan, zhi: p.hour.zhi),
            ]
        )
    }
}
