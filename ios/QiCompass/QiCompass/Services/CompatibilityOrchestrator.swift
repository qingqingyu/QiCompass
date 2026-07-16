import Foundation

/// 合盘编排器:组合 apiClient + compatibilityStore + chartStore + interpretStore + counter。
///
/// 分两阶段(决策 §D9 AI 失败隔离):
/// - 阶段 1 `runDeterministic`:构造请求 → POST /api/bazi/compatibility →
///   模式 B 隐式落地 B 盘 ChartSnapshot(无 UserSnapshotLink)→ upsert CompatibilitySnapshot
/// - 阶段 2 `runInterpretation`:禁词预检 / 缓存查询 → 次数检查 →
///   POST /api/interpret → **禁词扫描**(命中即拦截 + 日志 + 抛错,不展示原文)→
///   写 InterpretationCache + 更新 CompatibilitySnapshot.interpretation
///
/// 关键解耦:
/// - 定性评估成功 ≠ AI 成功;AI 子状态独立 error,不影响 resultReady
/// - 命中后端缓存 cached=True → refund;失败 → refund
/// - 禁词拦截显式失败(D10):不做正则替换,直接抛错让 UI 进入 error 态
@MainActor
final class CompatibilityOrchestrator {
    private let apiClient: APIClient
    private let compatibilityStore: CompatibilitySnapshotStore
    private let chartStore: ChartSnapshotStore
    private let interpretStore: InterpretationCacheStore
    private let counter: DailyReadCounter
    private let aiIdentityResolver: AIIdentityResolver

    init(
        apiClient: APIClient,
        compatibilityStore: CompatibilitySnapshotStore,
        chartStore: ChartSnapshotStore,
        interpretStore: InterpretationCacheStore,
        counter: DailyReadCounter,
        aiIdentityResolver: AIIdentityResolver
    ) {
        self.apiClient = apiClient
        self.compatibilityStore = compatibilityStore
        self.chartStore = chartStore
        self.interpretStore = interpretStore
        self.counter = counter
        self.aiIdentityResolver = aiIdentityResolver
    }

    // MARK: - 阶段 1:确定性合盘

    /// 调用 /api/bazi/compatibility 并 upsert CompatibilitySnapshot。
    ///
    /// - Parameters:
    ///   - request:已构造的 CompatibilityRequest(模式 A 或 B)
    ///   - personAHash:A 盘 contentHash(UI 顺序记录用)
    ///   - bChartSnapshotForUI:模式 A 传 B 的 ChartSnapshot(用于 UI 渲染);模式 B 传 nil,
    ///     此方法会用后端返回的 personBChart 隐式落地后回填
    /// - Returns:(response, personBHashFinal, bChartSnapshot)
    ///   - personBHashFinal:模式 A = request.personBHash;模式 B = 隐式落地后的 B contentHash
    ///   - bChartSnapshot:B 盘快照(模式 A 是已有的;模式 B 是新隐式落地的)
    func runDeterministic(
        request: CompatibilityRequest,
        personAHash: String
    ) async throws -> DeterministicResult {
        AppLogger.app.info(
            "compat.start a_hash=\(personAHash, privacy: .public) b_mode=\(request.personBHash == nil ? "B" : "A", privacy: .public) context=\(request.context, privacy: .public)"
        )

        let response = try await AppLogger.measure(
            AppLogger.networking,
            operation: "compatibility",
            context: [
                "a_hash": personAHash,
                "b_mode": request.personBHash == nil ? "B" : "A",
                "context": request.context,
            ]
        ) {
            try await self.apiClient.compatibility(request: request)
        }

        // 模式 B:把后端返回的 person_b_chart 隐式落地为 ChartSnapshot(无 UserSnapshotLink)
        var personBHashFinal: String
        if let bModeBHash = request.personBHash {
            // 模式 A:B hash 来自请求
            personBHashFinal = bModeBHash
        } else if let bResponse = response.personBChart {
            // 模式 B:隐式落地。后端 model_validator 已强制 mode B 下 person_b 非空,
            // 此处用 guard 显式解包,违反 invariant 即抛错(不静默用默认 gender/ziHourRule)。
            guard let personB = request.personB else {
                AppLogger.app.error(
                    "compat.mode_b_missing_person_b_input a_hash=\(personAHash, privacy: .public)"
                )
                throw CompatibilityError.modeBMissingPersonBInput
            }
            personBHashFinal = bResponse.contentHash
            let bRequest = BaziCalculateRequest(
                birthDatetime: bResponse.trueSolarTime,
                gender: personB.gender,
                city: personB.city,
                longitude: personB.longitude,
                ziHourRule: personB.ziHourRule
            )
            _ = try chartStore.upsert(response: bResponse, request: bRequest)
            AppLogger.persistence.info(
                "op=compatibility.bImplicitArchive b_content_hash=\(bResponse.contentHash, privacy: .public) user_link=false"
            )
        } else {
            // 不该发生:模式 B 必返 person_b_chart。显式抛错不静默。
            AppLogger.app.error(
                "compat.mode_b_missing_person_b_chart a_hash=\(personAHash, privacy: .public)"
            )
            throw CompatibilityError.modeBMissingPersonBChart
        }

        // upsert CompatibilitySnapshot(personAHash/personBHash 保留 UI 顺序)
        let upsertResult = try compatibilityStore.upsertQualitative(
            response: response,
            personAHash: personAHash,
            personBHash: personBHashFinal,
            context: request.context
        )

        AppLogger.app.info(
            "compat.ok compatibility_hash=\(response.compatibilityHash, privacy: .public) b_hash=\(personBHashFinal, privacy: .public) created=\(upsertResult.isNew)"
        )

        return DeterministicResult(
            response: response,
            personAHash: personAHash,
            personBHash: personBHashFinal,
            isSnapshotNew: upsertResult.isNew
        )
    }

    struct DeterministicResult {
        let response: CompatibilityResponse
        let personAHash: String
        let personBHash: String
        let isSnapshotNew: Bool
    }

    // MARK: - 阶段 2:AI 合盘解读

    /// AI 合盘解读:本地 24h 缓存查询 → 次数检查 → POST /api/interpret → 禁词扫描 → 缓存写入。
    ///
    /// 禁词扫描(D10):命中即拦截,**不展示原文**,抛 `CompatibilityError.forbiddenWordsHit`,
    /// 由 VM 转 interpretState = .failed。AI 失败不影响已成功的定性结果。
    func runInterpretation(
        compatibilityHash: String,
        chartA: ChartPromptContext,
        chartB: ChartPromptContext,
        assessment: QualitativeAssessmentDTO,
        syncedFortune: [SyncedFortuneDTO],
        context: String
    ) async throws -> InterpretResponse {
        let module = "compatibility"

        // 1. 查本地 24h AI 缓存(命中不消耗次数)
        let identity = try await aiIdentityResolver.resolve()
        if let cached = try interpretStore.getLatest(
            contentHash: compatibilityHash,
            module: module,
            targetDate: nil,
            identity: identity
        ),
            cached.generatedAt.addingTimeInterval(24 * 3600) > .now {
            // 二次禁词扫描(防止老缓存被污染)
            let hits = ForbiddenWords.scan(cached.interpretation)
            if !hits.isEmpty {
                AppLogger.app.error(
                    "compat.interpret.cache_forbidden compatibility_hash=\(compatibilityHash, privacy: .public) hits=\(hits.joined(separator: ","), privacy: .public)"
                )
                throw CompatibilityError.forbiddenWordsHit(words: hits)
            }
            let resp = InterpretResponse(
                interpretation: cached.interpretation,
                promptVersion: cached.promptVersion,
                cached: true,
                generatedAt: cached.generatedAt,
                provider: identity.provider,
                model: identity.model
            )
            try syncCompatibilityInterpretation(
                cached.interpretation,
                compatibilityHash: compatibilityHash,
                source: "cache_hit",
                provider: identity.provider,
                model: identity.model
            )
            AppLogger.app.info(
                "compat.interpret.cache_hit compatibility_hash=\(compatibilityHash, privacy: .public)"
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
            let contextLabel = PromptContextBuilder.contextLabel(context)
            let promptContext = PromptContextBuilder.buildCompatibility(
                contextLabel: contextLabel,
                chartA: chartA,
                chartB: chartB,
                assessment: assessment,
                syncedFortune: syncedFortune
            )
            let req = InterpretRequest(
                contentHash: compatibilityHash,
                module: module,
                context: promptContext,
                targetDate: nil,
                question: nil
            )
            let resp = try await AppLogger.measure(
                AppLogger.networking,
                operation: "compatInterpret",
                context: [
                    "compatibility_hash": compatibilityHash,
                    "module": module,
                ]
            ) {
                try await self.apiClient.interpret(request: req)
            }

            // 3. 禁词扫描(D10 显式失败,不做替换)
            let hits = ForbiddenWords.scan(resp.interpretation)
            if !hits.isEmpty {
                AppLogger.app.error(
                    "compat.interpret.forbidden compatibility_hash=\(compatibilityHash, privacy: .public) context=\(context, privacy: .public) pv=\(resp.promptVersion) hits=\(hits.joined(separator: ","), privacy: .public)"
                )
                // refund(用户不应为后端 LLM 失控买单)
                counter.refund(module: module)
                throw CompatibilityError.forbiddenWordsHit(words: hits)
            }

            AppLogger.app.info(
                "compat.interpret.ok compatibility_hash=\(compatibilityHash, privacy: .public) pv=\(resp.promptVersion) cached=\(resp.cached) words=\(resp.interpretation.count)"
            )

            // 4. 命中后端缓存 → refund。后续失败不能再次 refund,避免双退款。
            if resp.cached {
                counter.refund(module: module)
                shouldRefundOnFailure = false
            }

            // 5. 写本地 24h AI 缓存。失败必须传导到 UI,避免返回假成功。
            do {
                try interpretStore.upsert(
                    contentHash: compatibilityHash,
                    module: module,
                    promptVersion: resp.promptVersion,
                    targetDate: nil,
                    provider: resp.provider,
                    model: resp.model,
                    interpretation: resp.interpretation,
                    generatedAt: resp.generatedAt
                )
            } catch {
                AppLogger.persistence.error(
                    "compat.interpret.cacheWrite_failed compatibility_hash=\(compatibilityHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                throw error
            }

            // 6. 同步更新 CompatibilitySnapshot.interpretation(长期命书)。
            // 失败必须传导到 UI,避免本地状态与成功提示不一致。
            try syncCompatibilityInterpretation(
                resp.interpretation,
                compatibilityHash: compatibilityHash,
                source: "network",
                provider: resp.provider,
                model: resp.model
            )

            return resp
        } catch let error as CompatibilityError {
            throw error
        } catch let error as DeepAnalysisError {
            throw error
        } catch {
            if shouldRefundOnFailure {
                counter.refund(module: module)
            }
            AppLogger.app.error(
                "compat.interpret.failed compatibility_hash=\(compatibilityHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
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

    /// 查询本地 24h AI 缓存,命中时同步长期 CompatibilitySnapshot 后返回。
    /// 用于阶段 1 完成后立即显示已缓存解读。
    ///
    /// 同步失败必须上抛给 VM 转成解读错误态,避免 UI 显示“缓存成功”但长期命书
    /// 没有实际落地。缓存读取本身(`interpretStore.getLatest`)失败也上抛。
    func cachedInterpretationIfFresh(
        compatibilityHash: String
    ) async throws -> (text: String, promptVersion: Int)? {
        let module = "compatibility"
        let identity = try await aiIdentityResolver.resolve()
        guard let cached = try interpretStore.getLatest(
            contentHash: compatibilityHash,
            module: module,
            targetDate: nil,
            identity: identity
        ),
            cached.generatedAt.addingTimeInterval(24 * 3600) > .now
        else {
            return nil
        }
        try syncCompatibilityInterpretation(
            cached.interpretation,
            compatibilityHash: compatibilityHash,
            source: "prefetch_cache",
            provider: identity.provider,
            model: identity.model
        )
        return (cached.interpretation, cached.promptVersion)
    }

    private func syncCompatibilityInterpretation(
        _ interpretation: String,
        compatibilityHash: String,
        source: String,
        provider: String,
        model: String
    ) throws {
        do {
            try compatibilityStore.updateInterpretation(
                interpretation,
                forCompatibilityHash: compatibilityHash,
                provider: provider,
                model: model
            )
        } catch {
            AppLogger.persistence.error(
                "compat.interpret.snapshotSync_failed compatibility_hash=\(compatibilityHash, privacy: .public) source=\(source, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

}

// MARK: - CompatibilityError

/// 合盘领域错误。
enum CompatibilityError: Error, LocalizedError {
    /// 模式 B 后端未返回 person_b_chart(理论不应发生)
    case modeBMissingPersonBChart
    /// 模式 B 请求构造时缺 person_b 字段(invariant 违反,后端 model_validator 应已拦截)
    case modeBMissingPersonBInput
    /// AI 解读包含禁词(D10 拦截)
    case forbiddenWordsHit(words: [String])

    var errorDescription: String? {
        switch self {
        case .modeBMissingPersonBChart:
            return "模式 B 后端响应缺少 B 盘数据"
        case .modeBMissingPersonBInput:
            return "模式 B 请求缺少 B 盘输入字段"
        case .forbiddenWordsHit:
            return "解读包含不合规绝对结论,请重试"
        }
    }
}

// MARK: - ForbiddenWords(D10 禁忌词守卫)

/// 禁词集中管理(D6 风险 #6:抽到独立文件,演化时同步后端 prompt)。
///
/// 设计理由(D10):**不做文本替换**,替换会掩盖 AI 故障,违反"错误显式传播"。
/// 命中即拦截 + 日志 + 错误态,定性卡片本身不含禁词风险。
enum ForbiddenWords {
    /// 禁词清单:绝对结论类。LLM 必须用"倾向 / 较易 / 较难"等模糊叙事。
    static let absoluteConclusions: [String] = [
        "必成", "必分", "必破财", "必定", "一定会", "一定不会",
        "必然", "绝对", "百分之百", "铁定", "注定",
    ]

    /// 扫描文本,返回所有命中禁词(去重保序)。
    /// 空列表 = 通过;非空 = 拦截。
    static func scan(_ text: String) -> [String] {
        var hits: [String] = []
        for word in absoluteConclusions where text.contains(word) {
            if !hits.contains(word) { hits.append(word) }
        }
        return hits
    }
}
