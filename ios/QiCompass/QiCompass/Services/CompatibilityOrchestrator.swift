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
/// - 定性评估成功 ≠ AI 成功;AI 子状态独立 error,不影响 ready
/// - 命中后端缓存 cached=True → refund;失败 → refund
/// - 禁词拦截显式失败(D10):不做正则替换,直接抛错让 UI 进入 error 态
@MainActor
final class CompatibilityOrchestrator {
    private let apiClient: APIClient
    private let compatibilityStore: CompatibilitySnapshotStore
    private let chartStore: ChartSnapshotStore
    private let interpretStore: InterpretationCacheStore
    private let counter: DailyReadCounter
    private let interpretationReader: CachedInterpretationReader

    init(
        apiClient: APIClient,
        compatibilityStore: CompatibilitySnapshotStore,
        chartStore: ChartSnapshotStore,
        interpretStore: InterpretationCacheStore,
        counter: DailyReadCounter,
        interpretationReader: CachedInterpretationReader
    ) {
        self.apiClient = apiClient
        self.compatibilityStore = compatibilityStore
        self.chartStore = chartStore
        self.interpretStore = interpretStore
        self.counter = counter
        self.interpretationReader = interpretationReader
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
            // S04:PersonBInput 已迁 S02 契约(裸钟面+timezone+物理真值),直传存档
            let bRequest = BaziCalculateRequest(
                birthDatetime: personB.birthDatetime,
                timezone: personB.timezone,
                gender: personB.gender,
                longitude: personB.longitude,
                latitude: personB.latitude,
                placeName: personB.placeName,
                geonameId: personB.geonameId,
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
    ///
    /// - Parameter module: `compatibility` / `compatibility_free` / `compatibility_paid`
    ///   (M4 拆分 _free/_paid,VM 按 entitlement 状态传入)
    /// - Parameter nameA/nameB: 两人称呼(2026-09-27 A/B 代号修复,A 恒「你/you」,
    ///   B 为对方 alias/兜底名;进 prompt context 供后端 v4 模板称呼全文)
    /// - Parameter quotaExempt: R3(2026-10-02 review):STALE_SOURCE 降级重生成
    ///   豁免——语言切换引起,非用户过错(与深度解析 L4 同口径);豁免路径
    ///   无消费故同样跳过 refund(退未消费的额度 = 白送配额)。
    func runInterpretation(
        compatibilityHash: String,
        chartA: ChartPromptContext,
        chartB: ChartPromptContext,
        assessment: QualitativeAssessmentDTO,
        syncedFortune: [SyncedFortuneDTO],
        context: String,
        nameA: String,
        nameB: String,
        module: String = "compatibility",
        quotaExempt: Bool = false
    ) async throws -> InterpretResponse {
        // 规则 2:函数入口日志
        AppLogger.app.info("compat.runInterpretation.start compatibilityHash=\(compatibilityHash, privacy: .public) context=\(context, privacy: .public) module=\(module, privacy: .public)")

        // 1. 查本地 24h AI 缓存(命中不消耗次数)
        if let cached = try await interpretationReader.read(
            contentHash: compatibilityHash,
            module: module,
            maxAge: 24 * 3600
        ) {
            // reader 契约:命中行的 provider/model 必与当前 identity 严格匹配且非 legacy nil
            // (InterpretationCacheStore.getLatest 用 `==` 过滤,legacy nil 行被排除)。
            // SwiftData schema 保留 Optional 是为兼容旧迁移行,逻辑上此处不会命中 nil;
            // 若 nil 出现说明 reader 契约被破坏,降级空串避免崩溃,但日志已可定位。
            let provider = cached.provider ?? ""
            let model = cached.model ?? ""
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
                provider: provider,
                model: model,
                language: cached.language ?? AppLanguage.currentWire  // i18n:老缓存行 nil 视为当前 locale(对齐 Q13)
            )
            try syncCompatibilityInterpretation(
                cached.interpretation,
                compatibilityHash: compatibilityHash,
                source: "cache_hit",
                provider: provider,
                model: model
            )
            AppLogger.app.info(
                "compat.interpret.cache_hit compatibility_hash=\(compatibilityHash, privacy: .public)"
            )
            return resp
        }

        // 2. 次数检查(全局池口径,方案 §D1;quotaExempt 见函数注释)
        var shouldRefundOnFailure = false
        if quotaExempt {
            AppLogger.app.info(
                "compat.runInterpretation.quota_exempt compatibilityHash=\(compatibilityHash, privacy: .public) module=\(module, privacy: .public)"
            )
        } else {
            shouldRefundOnFailure = true
            guard counter.tryConsume(module: module) else {
                // 规则 1:抛错前打 warning(用户预期行为,非系统错误)
                let nextReset = counter.nextResetDate()
                AppLogger.app.warning("compat.runInterpretation.daily_limit_reached compatibilityHash=\(compatibilityHash, privacy: .public) nextReset=\(nextReset.description, privacy: .public)")
                throw DeepAnalysisError.dailyLimitReached(
                    nextReset: nextReset,
                    remaining: 0
                )
            }
        }

        do {
            let contextLabel = PromptContextBuilder.contextLabel(context)
            let promptContext = PromptContextBuilder.buildCompatibility(
                contextLabel: contextLabel,
                chartA: chartA,
                chartB: chartB,
                assessment: assessment,
                syncedFortune: syncedFortune,
                nameA: nameA,
                nameB: nameB
            )
            let req = InterpretRequest(
                contentHash: compatibilityHash,
                module: module,
                context: promptContext,
                targetDate: nil,
                question: nil,
                // 2026-08-23:compatibility_paid 进后端 PAID_MODULES 后 user_local_id
                // 必填(entitlement 查询维度);免费 module 统一传无副作用,
                // 对齐 DeepAnalysisOrchestrator 的做法
                userLocalId: UserIdentity.userLocalId
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
                // refund(用户不应为后端 LLM 失控买单);quotaExempt 路径未消费
                // 不退——退未消费的额度 = 白送配额(与下方 cached 分支同款守卫,
                // 2026-10-02 三查补)
                if !quotaExempt {
                    counter.refund(module: module)
                }
                throw CompatibilityError.forbiddenWordsHit(words: hits)
            }

            AppLogger.app.info(
                "compat.interpret.ok compatibility_hash=\(compatibilityHash, privacy: .public) pv=\(resp.promptVersion) cached=\(resp.cached) words=\(resp.interpretation.count)"
            )

            // 4. 命中后端缓存 → refund。后续失败不能再次 refund,避免双退款。
            // quotaExempt 路径未消费,跳过 refund(退未消费的额度 = 白送配额)。
            if resp.cached {
                if quotaExempt {
                    shouldRefundOnFailure = false
                } else {
                    counter.refund(module: module)
                    shouldRefundOnFailure = false
                }
            }

            // 5. 写本地 24h AI 缓存。失败必须传导到 UI,避免返回假成功。
            do {
                try interpretStore.upsert(
                    contentHash: compatibilityHash,
                    module: module,
                    promptVersion: resp.promptVersion,
                    targetDate: nil,
                    // i18n(trilingual T1,2026-09-22):compatibility_free/paid 的 en
                    // 模板与翻译层已落地(后端 prompts/en/ + translate_context),
                    // 缓存改存 resp.language(后端实际渲染语言,事实源)——
                    // 否则 en 用户读按 currentWire="en" 查、写恒落 "zh",
                    // 24h 客户端缓存永不命中。alias `compatibility` 无 en 模板,
                    // en 请求在模板加载处 500,到不了此写入,不受影响。
                    language: resp.language,
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
        guard let cached = try await interpretationReader.read(
            contentHash: compatibilityHash,
            module: module,
            maxAge: 24 * 3600
        ) else {
            return nil
        }
        // reader 契约:provider/model 非 legacy nil(同上 cache_hit 分支)。降级空串仅为防崩溃。
        try syncCompatibilityInterpretation(
            cached.interpretation,
            compatibilityHash: compatibilityHash,
            source: "prefetch_cache",
            provider: cached.provider ?? "",
            model: cached.model ?? ""
        )
        return (cached.interpretation, cached.promptVersion)
    }

    // MARK: - 跨语言翻译(D10.4/D10.5,S7)

    /// 跨语言查 24h AI 缓存:当前语言 miss 时探测其它语言的既有解读。
    ///
    /// 探测 `compatibility_paid` / `compatibility_free` 两键(现役生成写键;
    /// alias `compatibility` 是老 App 兼容路径不投入,与 cachedInterpretationIfFresh
    /// 的 legacy 读键不同源是有意的),先 paid 后 free——与 VM 按 entitlement
    /// 选 module 的顺序一致,命中的 module 即翻译请求该用的 module。
    ///
    /// 前置守卫:目标语言 free/paid 任一键已有行时**不跨语言**(返回 nil)——
    /// VM 的当前语言检查走 `cachedInterpretationIfFresh`(只读 legacy alias 键,
    /// 看不到现役写键),若不在此拦,用户以目标语言生成过之后重开 detail,
    /// 会命中**旧语言的行**并展示过期原文 + 多余的翻译提议(译文其实已在
    /// 缓存;点翻译经「先查后译」秒回,但展示事实是错的)。
    func cachedCrossLanguageInterpretationIfFresh(
        compatibilityHash: String
    ) async throws -> (module: String, language: String, text: String, promptVersion: Int)? {
        // readAll 单次批量(identity 只 resolve 一次;read 逐 module 各 resolve
        // 一次 = 多两次 health 网络往返)
        let currentLanguageModules = ["compatibility_paid", "compatibility_free"]
        let currentLanguageHits = try await interpretationReader.readAll(
            contentHash: compatibilityHash,
            modules: currentLanguageModules,
            language: AppLanguage.currentWire,
            maxAge: 24 * 3600
        )
        if !currentLanguageHits.isEmpty {
            AppLogger.app.info(
                "compat.crossLanguage.skip_current_language_hit compatibility_hash=\(compatibilityHash, privacy: .public)"
            )
            return nil
        }
        // 跨语言探测走模块优先批量版(paid 先于 free;identity 单次 resolve——
        // 2026-10-02 修复:此前逐模块调 readAllCrossLanguage,每次内部逐语言
        // 再各 resolve 一次 identity,一次 detail 打开最多 5 次 health 往返)
        if let hit = try await interpretationReader.readCrossLanguageByModulePriority(
            contentHash: compatibilityHash,
            modules: currentLanguageModules,
            maxAge: 24 * 3600
        ) {
            return (hit.module, hit.language, hit.row.interpretation, hit.row.promptVersion)
        }
        return nil
    }

    /// 翻译合盘解读(D10.4/D10.5):原文 → 目标语言,译文写入目标语言缓存键。
    ///
    /// 与 `runInterpretation` 共享请求构建口径(`PromptContextBuilder
    /// .buildCompatibility`,入参签名一致)——D10.1 缓存键对齐:译文落键后
    /// 任何设备以目标语言正常生成都会命中。**不消耗每日次数**(D10.1 翻译
    /// 不另收费;本地 counter 是生成配额,翻译绕过,无 refund 语义)。
    /// 失败显式抛错:409 STALE_SOURCE(原文版本过期,走正常重新生成)/
    /// 503 保真校验失败(可重试),不回退原文、不静默改走生成。
    func translateInterpretation(
        compatibilityHash: String,
        chartA: ChartPromptContext,
        chartB: ChartPromptContext,
        assessment: QualitativeAssessmentDTO,
        syncedFortune: [SyncedFortuneDTO],
        context: String,
        nameA: String,
        nameB: String,
        module: String,
        sourceLanguage: String,
        sourcePromptVersion: Int,
        sourceInterpretation: String
    ) async throws -> InterpretResponse {
        // 先查后译(D10.1):目标语言已有缓存(他设备生成/先前翻译)直接返回
        if let cached = try await interpretationReader.read(
            contentHash: compatibilityHash,
            module: module,
            maxAge: 24 * 3600
        ) {
            AppLogger.app.info(
                "compat.translate.cache_hit compatibility_hash=\(compatibilityHash, privacy: .public) module=\(module, privacy: .public)"
            )
            return InterpretResponse(
                interpretation: cached.interpretation,
                promptVersion: cached.promptVersion,
                cached: true,
                generatedAt: cached.generatedAt,
                provider: cached.provider ?? "",
                model: cached.model ?? "",
                language: cached.language ?? AppLanguage.currentWire
            )
        }

        let contextLabel = PromptContextBuilder.contextLabel(context)
        let promptContext = PromptContextBuilder.buildCompatibility(
            contextLabel: contextLabel,
            chartA: chartA,
            chartB: chartB,
            assessment: assessment,
            syncedFortune: syncedFortune,
            nameA: nameA,
            nameB: nameB
        )
        let req = InterpretRequest(
            contentHash: compatibilityHash,
            module: module,
            context: promptContext,
            targetDate: nil,
            question: nil,
            userLocalId: UserIdentity.userLocalId
        )
        let translateReq = TranslateRequest(
            base: req,
            sourceLanguage: sourceLanguage,
            sourcePromptVersion: sourcePromptVersion,
            sourceInterpretation: sourceInterpretation
        )
        AppLogger.app.info(
            "compat.translate.start compatibility_hash=\(compatibilityHash, privacy: .public) module=\(module, privacy: .public) source=\(sourceLanguage, privacy: .public)"
        )
        let resp = try await AppLogger.measure(
            AppLogger.networking,
            operation: "compatTranslate",
            context: [
                "compatibility_hash": compatibilityHash,
                "module": module,
            ]
        ) {
            try await self.apiClient.translate(request: translateReq)
        }

        // 禁词扫描(镜像 runInterpretation 第 3 步;后端同扫,纵深防御)
        let hits = ForbiddenWords.scan(resp.interpretation)
        if !hits.isEmpty {
            AppLogger.app.error(
                "compat.translate.forbidden compatibility_hash=\(compatibilityHash, privacy: .public) hits=\(hits.joined(separator: ","), privacy: .public)"
            )
            throw CompatibilityError.forbiddenWordsHit(words: hits)
        }

        // 写本地缓存(译文落目标语言键,与 runInterpretation 写入口径一致)
        try interpretStore.upsert(
            contentHash: compatibilityHash,
            module: module,
            promptVersion: resp.promptVersion,
            targetDate: nil,
            language: resp.language,
            provider: resp.provider,
            model: resp.model,
            interpretation: resp.interpretation,
            generatedAt: resp.generatedAt
        )
        try syncCompatibilityInterpretation(
            resp.interpretation,
            compatibilityHash: compatibilityHash,
            source: "translate",
            provider: resp.provider,
            model: resp.model
        )
        AppLogger.app.info(
            "compat.translate.ok compatibility_hash=\(compatibilityHash, privacy: .public) module=\(module, privacy: .public) source=\(sourceLanguage, privacy: .public) target=\(resp.language, privacy: .public)"
        )
        return resp
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

    /// errorDescription 是**用户可见文案**(2026-08-16:代码性错误不进 UI)。
    /// 「模式 B」等内部架构术语只进日志(orchestrator 各 throw 点已记
    /// compat.mode_b_missing_* 日志,含 a_hash)。
    var errorDescription: String? {
        switch self {
        case .modeBMissingPersonBChart:
            return String(localized: "合盘数据异常,请重试")
        case .modeBMissingPersonBInput:
            return String(localized: "合盘数据异常,请重试")
        case .forbiddenWordsHit:
            return String(localized: "解读包含不合规绝对结论,请重试")
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
