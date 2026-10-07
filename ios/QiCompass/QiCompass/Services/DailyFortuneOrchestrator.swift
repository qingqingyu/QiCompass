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
    private let interpretationReader: CachedInterpretationReader

    init(
        apiClient: APIClient,
        dailyStore: DailyFortuneSnapshotStore,
        interpretStore: InterpretationCacheStore,
        chartStore: ChartSnapshotStore,
        counter: DailyReadCounter,
        interpretationReader: CachedInterpretationReader
    ) {
        self.apiClient = apiClient
        self.dailyStore = dailyStore
        self.interpretStore = interpretStore
        self.chartStore = chartStore
        self.counter = counter
        self.interpretationReader = interpretationReader
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
        // 规则 2:函数入口日志
        AppLogger.app.info("daily.runDeterministic.start chartHash=\(chartHash, privacy: .public) targetDate=\(Self.dateFormatter.string(from: businessDate), privacy: .public) forceRefresh=\(forceRefresh, privacy: .public)")
        // 1. 取存档 ChartSnapshot(无 → chartMissing)
        guard let snapshot = try chartStore.get(contentHash: chartHash) else {
            // 规则 1:抛错前打 warning(用户预期业务异常,需先排盘)
            AppLogger.app.warning("daily.runDeterministic.chart_missing chartHash=\(chartHash, privacy: .public)")
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
        // 2026-10-07 P0 收口:per-chart token(端点对账 token↔hash↔payload;
        // 老快照 nil → 后端 403 CONTEXT_TOKEN_REQUIRED 显式暴露)
        let request = DailyFortuneRequest(
            chartHash: chartHash,
            targetDate: businessDate,
            chartPayload: chartPayload,
            contextToken: baziResponse.payloadContextToken
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
        // 规则 2:函数入口日志
        AppLogger.app.info("daily.runInterpretation.start chartHash=\(chartHash, privacy: .public) targetDate=\(Self.dateFormatter.string(from: businessDate), privacy: .public)")
        let module = "daily_fortune"
        let targetDate = businessDate

        // 1. 查本地 24h AI 缓存
        if let cached = try await interpretationReader.read(
            contentHash: chartHash,
            module: module,
            targetDate: targetDate,
            maxAge: 24 * 3600
        ) {
            // S6 缓存毒化自愈(2026-09-30 review):命中行若不满足 v4 五段契约
            // (v3 散文 / 畸形 JSON)→ 不返回,落穿重新生成。否则 Retry 与自动
            // 进入都会拿回同一段坏文本,24h 内静默卡在引擎模板降级态。
            // 重新生成的 upsert 会覆盖同键行(或以更高 promptVersion 行胜出),
            // 坏行自然淘汰,无需显式删除。
            if DailyInsight.parse(cached.interpretation) == nil {
                AppLogger.app.warning(
                    "daily.interpret.cache_stale_unparseable hash=\(chartHash, privacy: .public) targetDate=\(targetDate, privacy: .public) — 绕过本地缓存落穿生成"
                )
                // 不返回:落穿到下方次数检查 + 网络生成
            } else {
                // reader 契约:命中行的 provider/model 必与当前 identity 严格匹配且非 legacy nil
                // (InterpretationCacheStore.getLatest 用 `==` 过滤,legacy nil 行被排除)。
                // SwiftData schema 保留 Optional 是为兼容旧迁移行,逻辑上此处不会命中 nil;
                // 若 nil 出现说明 reader 契约被破坏,降级空串避免崩溃,但日志已可定位。
                let provider = cached.provider ?? ""
                let model = cached.model ?? ""
                // 命中本地 24h 缓存:构造 InterpretResponse(标 cached=true,generatedAt=原时间)
                let resp = InterpretResponse(
                    interpretation: cached.interpretation,
                    promptVersion: cached.promptVersion,
                    cached: true,
                    generatedAt: cached.generatedAt,
                    provider: provider,
                    model: model,
                    language: cached.language ?? AppLanguage.currentWire  // i18n:老缓存行 nil 视为当前 locale(对齐 Q13)
                )
                try dailyStore.updateInterpretation(
                    cached.interpretation,
                    forChartHash: chartHash,
                    targetDate: targetDate,
                    provider: provider,
                    model: model,
                    language: cached.language ?? "zh"  // nil 老行视为 zh(同缓存口径)
                )
                AppLogger.app.info(
                    "daily.interpret.cache_hit hash=\(chartHash, privacy: .public) targetDate=\(targetDate, privacy: .public)"
                )
                return resp
            }
        }

        // 2. L5/F3(2026-10-01 拍板,修订 D10 模块表):当前语言 miss → 先跨语言
        // 查同 target_date 的既有解读,有则**翻译**(不扣次数、结论不变——LLM
        // 非确定性,重生成会让「换个语言命就变了」;次数耗尽时也不再出现
        // 「当天一段新语言解读都没有」)。无源才落穿到下方生成扣次数。
        // F4(2026-10-02,对齐深度解析 L4):STALE_SOURCE(原文版本过期 / 后端
        // 清库后不可核验)例外降级——这条源每次进入都必败(24h 窗口内反复
        // 命中同一行),不落穿会让当天新语言永远拿不到解读。降级生成豁免
        // 配额(语言切换 / 版本 bump 非用户过错,镜像 L4 口径,用户已拍板);
        // 其他翻译错误(离线 / 503 保真失败)显式上抛,不静默改走生成。
        var staleSourceDowngraded = false
        if let crossLanguage = try await crossLanguageSourceIfFresh(
            chartHash: chartHash, module: module, targetDate: targetDate
        ) {
            do {
                return try await translateExisting(
                    chartHash: chartHash,
                    chartPayload: chartPayload,
                    dailyResponse: dailyResponse,
                    businessDate: businessDate,
                    source: crossLanguage
                )
            } catch {
                guard APIError.isStaleSource(error) else { throw error }
                AppLogger.app.warning(
                    "daily.translate.stale_source_downgrade hash=\(chartHash, privacy: .public) targetDate=\(Self.dateFormatter.string(from: targetDate), privacy: .public) — 落穿目标语言生成(豁免配额)"
                )
                staleSourceDowngraded = true
            }
        }

        return try await generateInterpretation(
            chartHash: chartHash,
            chartPayload: chartPayload,
            dailyResponse: dailyResponse,
            businessDate: businessDate,
            quotaExempt: staleSourceDowngraded
        )
    }

    /// 生成路径(步骤 3 起,原 runInterpretation 主体抽出;跨语言翻译与
    /// STALE 降级共用)。quotaExempt=true 时跳过次数检查且全程不 refund
    /// (没扣不退——豁免路径 cached 命中 / 失败都不得动 counter,防 F1
    /// 同款「白送配额」)。
    private func generateInterpretation(
        chartHash: String,
        chartPayload: ChartPayloadDTO,
        dailyResponse: DailyFortuneResponse,
        businessDate: Date,
        quotaExempt: Bool
    ) async throws -> InterpretResponse {
        let module = "daily_fortune"
        let targetDate = businessDate
        // 3. 次数检查(全局池口径,方案 §D1)。quotaExempt(F4,2026-10-02):
        // STALE_SOURCE 降级生成不烧当日配额(镜像深度解析 L4)。
        // 扣/退逻辑收口 InterpretQuotaLedger(2026-10-07:三 orchestrator
        // 手写同款已开始漂移)。
        var ledger = InterpretQuotaLedger(
            counter: counter, module: module, hashForLog: chartHash
        )
        try ledger.consume(quotaExempt: quotaExempt, logLabel: "daily.generateInterpretation")

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
                question: nil,
                // 2026-10-07 P0 收口:daily 族 token(claims 含 target_date)
                contextToken: dailyResponse.contextToken
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

            // 命中后端缓存 → refund(仅实际扣过才退;豁免路径没扣,退了就是
            // 白送配额——F1 同款修复)。后续失败不能再次 refund,避免双退款。
            ledger.settleCacheHit(cached: resp.cached)

            // 写本地 AI 缓存。失败必须传导到 UI,避免返回假成功。
            do {
                try interpretStore.upsert(
                    contentHash: chartHash,
                    module: module,
                    promptVersion: resp.promptVersion,
                    targetDate: targetDate,
                    language: resp.language,  // i18n:用后端实际响应的语言(事实源,决策 10)
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
                    model: resp.model,
                    language: resp.language
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
            ledger.refundOnFailure()
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

    /// 后端 409 STALE_SOURCE 判定已收口到 `APIError.isStaleSource`
    /// (2026-10-07 review:三处同款判定合一,单一事实源)。

    // MARK: - 跨语言翻译(L5/F3,2026-10-01 修订 D10 模块表)

    /// 跨语言探测当前语言之外的既有 daily 解读(同 target_date,24h 新鲜度
    /// 与同语言缓存同口径)。原文必须能过 v4 五段契约——坏行(毒化)**不参与
    /// 候选**(#8,2026-10-02:此前只看「最优语言」那一行,坏行直接判无源;
    /// 现在跳过坏行继续尝试其它语言,全语言皆坏才落穿生成)。后端
    /// `_parse_daily_source_interpretation` 同口径会 422,客户端先拦省一跳网络。
    private func crossLanguageSourceIfFresh(
        chartHash: String, module: String, targetDate: Date
    ) async throws -> InterpretationCache? {
        guard let (sourceLanguage, hits) = try await interpretationReader
            .readAllCrossLanguage(
                contentHash: chartHash,
                modules: [module],
                targetDate: targetDate,
                maxAge: 24 * 3600,
                rowIsValid: { row in
                    let valid = DailyInsight.parse(row.interpretation) != nil
                    if !valid {
                        // #6(2026-10-07 review):坏行此前被 rowIsValid 静默过滤,
                        // 不留痕违反错误显式传播——线上毒化无从定位。行保留
                        // (24h 自然过期;同语言键的重生成会覆盖自愈,跨语言
                        // 坏行无覆写方,依赖过期淘汰),该语言候选跳过。
                        AppLogger.app.warning(
                            "daily.translate.source_row_invalid module=\(row.module, privacy: .public) language=\(row.language ?? "nil", privacy: .public) promptVersion=\(row.promptVersion) — 跳过该语言候选"
                        )
                    }
                    return valid
                }
            ),
            let row = hits[module]
        else { return nil }
        AppLogger.app.info(
            "daily.translate.source_found hash=\(chartHash, privacy: .public) source=\(sourceLanguage, privacy: .public) targetDate=\(Self.dateFormatter.string(from: targetDate), privacy: .public)"
        )
        return row
    }

    /// L5 门控探针(2026-10-07 review 修复):次数耗尽时,自动触发前先探测
    /// 是否存在可翻译的跨语言源——翻译不耗次数,有源即应自动触发,守住
    /// L5/F3「次数耗尽时也不再出现『当天一段新语言解读都没有』」的拍板
    /// (此前 VM 侧 remainingReads > 0 一刀切,耗尽 + 切语言 = 当天无解读)。
    /// 探测失败按无源处理(离线时 identity resolve 即失败,保守不触发,
    /// 与旧门槛行为一致),错误显式记日志。
    func hasCrossLanguageDailySource(chartHash: String, targetDate: Date) async -> Bool {
        do {
            return try await crossLanguageSourceIfFresh(
                chartHash: chartHash, module: "daily_fortune", targetDate: targetDate
            ) != nil
        } catch {
            AppLogger.app.warning(
                "daily.translate.source_probe_failed hash=\(chartHash, privacy: .public) targetDate=\(Self.dateFormatter.string(from: targetDate), privacy: .public) error=\(String(describing: error), privacy: .public) — 按无源处理(不自动触发)"
            )
            return false
        }
    }

    /// 翻译既有 daily 解读到目标语言(不消耗次数)。译文写入目标语言缓存键
    /// (后端共享 `_prepare_prompt_and_key` 保证键对齐)+ 同步快照,镜像生成
    /// 路径的落库逻辑;译文本身也过 v4 五段契约才落库(毒化不进缓存)。
    private func translateExisting(
        chartHash: String,
        chartPayload: ChartPayloadDTO,
        dailyResponse: DailyFortuneResponse,
        businessDate: Date,
        source: InterpretationCache
    ) async throws -> InterpretResponse {
        let module = "daily_fortune"
        let context = PromptContextBuilder.buildDailyFortune(
            chartPayload: chartPayload,
            response: dailyResponse,
            businessDate: businessDate
        )
        let request = TranslateRequest(
            base: InterpretRequest(
                contentHash: chartHash,
                module: module,
                context: context,
                targetDate: businessDate,
                question: nil,
                // 2026-10-07 P0 收口:翻译同闸(译文落共享键,盘身须与 token 一致)
                contextToken: dailyResponse.contextToken
            ),
            sourceLanguage: source.language ?? "zh",
            sourcePromptVersion: source.promptVersion,
            sourceInterpretation: source.interpretation
        )
        let resp = try await AppLogger.measure(
            AppLogger.networking,
            operation: "dailyTranslate",
            context: [
                "chart_hash": chartHash,
                "target_date": Self.dateFormatter.string(from: businessDate),
                "source_language": source.language ?? "zh",
            ]
        ) {
            try await self.apiClient.translate(request: request)
        }

        // 译文契约校验(镜像 S6 毒化自愈判据):坏译文不落库,显式抛错走失败态
        guard DailyInsight.parse(resp.interpretation) != nil else {
            AppLogger.app.error(
                "daily.translate.translated_unparseable hash=\(chartHash, privacy: .public) — 拒绝落库"
            )
            throw DeepAnalysisError.translatedContentInvalid
        }

        try interpretStore.upsert(
            contentHash: chartHash,
            module: module,
            promptVersion: resp.promptVersion,
            targetDate: businessDate,
            language: resp.language,
            provider: resp.provider,
            model: resp.model,
            interpretation: resp.interpretation,
            generatedAt: resp.generatedAt
        )
        try dailyStore.updateInterpretation(
            resp.interpretation,
            forChartHash: chartHash,
            targetDate: businessDate,
            provider: resp.provider,
            model: resp.model,
            language: resp.language
        )
        AppLogger.app.info(
            "daily.translate.ok hash=\(chartHash, privacy: .public) cached=\(resp.cached, privacy: .public)"
        )
        return resp
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
        guard let cached = try await interpretationReader.read(
            contentHash: chartHash,
            module: module,
            targetDate: targetDate,
            maxAge: 24 * 3600
        ) else {
            return nil
        }
        // S6 缓存毒化自愈(2026-09-30 review,补全):命中行不满足 v4 五段契约
        // (v3 散文/畸形 JSON)→ 返回 nil 视为无缓存,让 VM 走自动生成链路
        // (runInterpretation 内同款嗅探会落穿重新生成)。否则毒化行直接进
        // .okFree,自动生成永不触发,用户停在降级模板。
        guard DailyInsight.parse(cached.interpretation) != nil else {
            AppLogger.app.warning(
                "daily.interpret.prefetch_stale_unparseable hash=\(chartHash, privacy: .public) targetDate=\(targetDate, privacy: .public) — 视为无缓存,交给自动生成"
            )
            return nil
        }
        // reader 契约:provider/model 非 legacy nil(同上 cache_hit 分支)。降级空串仅为防崩溃。
        try dailyStore.updateInterpretation(
            cached.interpretation,
            forChartHash: chartHash,
            targetDate: targetDate,
            provider: cached.provider ?? "",
            model: cached.model ?? "",
            language: cached.language ?? "zh"
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
    /// 找不到当前用户的 ChartSnapshot(命盘存档缺失)
    case chartMissing

    var errorDescription: String? {
        switch self {
        case .chartMissing:
            return String(localized: "未找到命盘存档,无法查看每日运势")
        }
    }
}

// MARK: - DailyFortuneSnapshotStore helpers(放此处避免 Store 过胖)

extension DailyFortuneSnapshotStore {
    /// 从存档 DailyFortuneSnapshot 重建 DailyFortuneResponse(给阶段 2 与 VM 复用)。
    /// calcRuleSnapshot 用空占位(daily-fortune 后端返回的 calcRuleSnapshot 不用于 UI 关键路径)。
    /// S6 今日信号:老快照缺列 → 全 nil(信号行隐藏);daySignal JSON 解码失败
    /// 显式抛错(错误显式传播:存档损坏不静默吞)。
    func response(from snapshot: DailyFortuneSnapshot) throws -> DailyFortuneResponse {
        let hours = try decodeHourPillars(from: snapshot)
        let tomorrow = try decodeTomorrowPreview(from: snapshot)
        let dayElements: DayElementsDTO?
        if let stem = snapshot.dayElementsStem, let branch = snapshot.dayElementsBranch {
            dayElements = DayElementsDTO(stemElement: stem, branchElement: branch)
        } else {
            dayElements = nil
        }
        let daySignal: [DaySignalItemDTO]?
        if let data = snapshot.daySignal {
            daySignal = try APICoder.decoder.decode([DaySignalItemDTO].self, from: data)
        } else {
            daySignal = nil
        }
        return DailyFortuneResponse(
            dayPillar: snapshot.dayPillar,
            dayRelationToDayMaster: snapshot.dayRelation,
            dayChong: snapshot.dayChong,
            dayChongTargets: snapshot.dayChongTargets,
            hourPillars: hours,
            currentHourIndex: nil,
            dayElements: dayElements,
            daySignal: daySignal,
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
    ///
    /// S05 时辰未知:柱缺失 → four_pillars 对应 key 整体省略(显式缺失,不猜);
    /// 日柱歧义(无日主)时 dayMaster 落空串 + 显式日志——S09(每日运势)/
    /// S11(合盘)负责入口拦截,本函数不可 throw(多调用方签名约束),
    /// 后端 REQUIRED 校验是最后兜底。
    ///
    /// S05 item 4(2026-09-01 review 补入):`dayMasterStrength` **显式透传**——
    /// 后端引擎对无时辰盘恒输出 `"unknown_hour"`(非 nil),必须原样进 payload
    /// (后端按它切 daily_fortune 降级模板 + REQUIRED 免检);**禁止**
    /// `?? "special_pattern"` 兜底把 unknown_hour 伪装成从格盘(假精度,
    /// 整个时辰未知设计的前提被破坏)。nil 只会出现在防御位/异常存档
    /// (引擎五值必居其一),沿用本函数 dayMaster==nil 同款惯例:显式 warning
    /// + 诚实安全值 `"unknown_hour"`(旺衰未判定——与 backend
    /// `_STRENGTH_LABEL[None]="旺衰未判定"` 同义,不伪装成任何已判定结论)。
    static func from(baziResponse: BaziResponse) -> ChartPayloadDTO {
        let p = baziResponse.pillars
        if p.day == nil {
            AppLogger.app.warning(
                "op=chartPayload.from day_pillar_missing hash=\(baziResponse.contentHash, privacy: .public) note=日柱歧义盘,应被 S09/S11 入口拦截"
            )
        }
        if baziResponse.dayMasterStrength == nil {
            AppLogger.app.warning(
                "op=chartPayload.from day_master_strength_nil hash=\(baziResponse.contentHash, privacy: .public) note=引擎恒输出五值之一,nil=异常存档,显式降级unknown_hour不伪装special_pattern"
            )
        }
        var fourPillars: [String: PillarRefDTO] = [:]
        if let year = p.year {
            fourPillars["year"] = PillarRefDTO(gan: year.gan, zhi: year.zhi)
        }
        if let month = p.month {
            fourPillars["month"] = PillarRefDTO(gan: month.gan, zhi: month.zhi)
        }
        if let day = p.day {
            fourPillars["day"] = PillarRefDTO(gan: day.gan, zhi: day.zhi)
        }
        if let hour = p.hour {
            fourPillars["hour"] = PillarRefDTO(gan: hour.gan, zhi: hour.zhi)
        }
        return ChartPayloadDTO(
            dayMaster: p.day?.gan ?? "",
            dayMasterElement: p.day?.ganElement ?? "",
            dayMasterStrength: baziResponse.dayMasterStrength ?? "unknown_hour",
            favorableElements: baziResponse.favorableElements,
            unfavorableElements: baziResponse.unfavorableElements,
            fourPillars: fourPillars
        )
    }

    /// 合盘路径构造器(2026-09-27「无运」修复):在 `from(baziResponse:)` 基础上
    /// 显式带上 `luckPillars` + `calcRuleSnapshot`(合盘完整构造器)。
    ///
    /// 根因:此前合盘 payloadA / 存档 payloadB 复用了 daily-fortune 主构造器
    /// (`luckPillars=nil`)→ 后端 `luck_pillars=[]` → 流年同步表拼「无运 丁未年」
    /// (backend engine/compatibility.py 的 `_luck_pillar_for_year` 永远 miss)。
    /// 临时人(模式 B)由后端现排自带大运,所以只有 A 列(和存档 B 列)受害。
    ///
    /// daily-fortune 路径继续用 `from(baziResponse:)`(不带扩展字段,行为不变)。
    static func compatibilityPayload(from baziResponse: BaziResponse) -> ChartPayloadDTO {
        let base = from(baziResponse: baziResponse)
        return ChartPayloadDTO(
            dayMaster: base.dayMaster,
            dayMasterElement: base.dayMasterElement,
            dayMasterStrength: base.dayMasterStrength,
            favorableElements: base.favorableElements,
            unfavorableElements: base.unfavorableElements,
            fourPillars: base.fourPillars,
            luckPillars: baziResponse.luckPillars,
            calcRuleSnapshot: baziResponse.calcRuleSnapshot
        )
    }
}
