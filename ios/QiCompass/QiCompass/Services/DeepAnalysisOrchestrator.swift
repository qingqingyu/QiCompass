import Foundation

/// 深度解析编排器:组合 apiClient + store + counter + PromptContextBuilder。
///
/// 分两阶段(方案 §三数据流):
/// - 阶段 1 `runCalculation`:排盘 → 存档 ChartSnapshot。失败 throw → `.chartFailed`
/// - 阶段 2 `runInterpretation`:次数检查 → /api/interpret → 存本地缓存。
///   AI 失败 ≠ 排盘失败,独立 throw(由 VM 转 `.interpretFailed`,排盘已存档可见)。
///
/// 关键解耦(方案 §一):
/// - 排盘成功立即存档 + 进 ready;AI 子状态独立
/// - 命中后端缓存 cached=True → refund(不消耗每日次数)
/// - AI 失败 → refund(重试不消耗)
/// - 存档失败也 throw(不提示"命盘已保存")
@MainActor
final class DeepAnalysisOrchestrator {
    private let apiClient: APIClient
    private let chartStore: ChartSnapshotStore
    private let interpretStore: InterpretationCacheStore
    private let counter: DailyReadCounter
    private let interpretationReader: CachedInterpretationReader
    private let userLinkStore: UserSnapshotLinkStore

    init(
        apiClient: APIClient,
        chartStore: ChartSnapshotStore,
        interpretStore: InterpretationCacheStore,
        counter: DailyReadCounter,
        interpretationReader: CachedInterpretationReader,
        userLinkStore: UserSnapshotLinkStore
    ) {
        self.apiClient = apiClient
        self.chartStore = chartStore
        self.interpretStore = interpretStore
        self.counter = counter
        self.interpretationReader = interpretationReader
        self.userLinkStore = userLinkStore
    }

    // MARK: - 阶段 1:排盘 + 存档

    /// 排盘 → 存档 ChartSnapshot。任一失败 throw(→ `.chartFailed`)。
    ///
    /// - Parameter alias: 命盘展示别名("我自己" / "妈妈" / "男友"),默认值走 L10n
    ///   (2026-09-23 起 EN 界面默认 "Me",不再夹中文)。v2 PR1 起由调用方传入
    ///   (BirthFormView 表单顶部 TextField 收集),默认值仅防御性兜底。
    func runCalculation(request: BaziCalculateRequest, alias: String = L10n.BirthForm.aliasDefault) async throws -> BaziResponse {
        // 规则 2:函数入口日志(网络调用内部已通过 AppLogger.measure 覆盖 start/ok/failed)
        AppLogger.app.info("deep.runCalculation.start birth=\(request.birthDatetime, privacy: .public) tz=\(request.timezone, privacy: .public) gender=\(request.gender, privacy: .public) place=\(request.placeName ?? "nil", privacy: .public) lon=\(request.longitude, privacy: .public)")
        let response = try await calculateAndArchive(request: request)

        // 写 UserSnapshotLink 标记归属(alias 由调用方传入,默认"我自己")。
        // 不写 link 会让合盘 / 每日运势查不到本命盘(它们都按 UserSnapshotLink 取列表)。
        // upsert 按 (userId, snapshotHash) 去重:同盘重排不重复 insert,但 alias 会更新。
        //
        // 降级策略(避免 UX 不一致):ChartSnapshot 已存档 → 视为排盘成功。
        // link 写入失败时不 throw(否则 UI 看到 chartFailed 但盘已落库,重排会去重),
        // 改为显式 error 日志,便于运维追踪合盘查不到盘的根因。link 不写入不影响 Chart
        // 重排(下次重排 chartStore.upsert 命中,link upsert 重试)。
        do {
            _ = try userLinkStore.upsert(
                userId: UserIdentity.userLocalId,
                snapshotHash: response.contentHash,
                alias: alias
            )
        } catch {
            // 不吞错:显式 error 日志,运维可据 traceId 定位合盘空列表根因。
            AppLogger.persistence.error(
                "op=deepAnalysis.runCalculation userLink.upsert.failed contentHash=\(response.contentHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }

        return response
    }

    /// S10 补时辰重算:calculate + 存档,**不写 UserSnapshotLink**。
    ///
    /// link 语义由调用方(`AddHourViewModel.submit`)决定:老盘有 link → 按**原 alias**
    /// 补写新 link(编辑场景隔离,名字不丢);老盘无 link(合盘临时人隐式落地的盘,
    /// D6 红线「临时人不建 link」)→ 新盘同样不建。因此不能复用 `runCalculation`
    /// (它会无条件以默认 alias 写 link,把临时人洗成正式命盘)。
    ///
    /// 新 content_hash ≠ 老 hash 的闭环断言在调用方(那里持有老 hash);
    /// 此处只负责网络 + 存档,失败照常 throw。
    func runAddHourRecalculation(request: BaziCalculateRequest) async throws -> BaziResponse {
        AppLogger.app.info("deep.runAddHourRecalculation.start birth=\(request.birthDatetime, privacy: .public) tz=\(request.timezone, privacy: .public) hourKnown=\(request.hourKnown, privacy: .public)")
        return try await calculateAndArchive(request: request)
    }

    /// 排盘 + 存档共用核心(runCalculation / runAddHourRecalculation 两条路径共享)。
    private func calculateAndArchive(request: BaziCalculateRequest) async throws -> BaziResponse {
        let response = try await AppLogger.measure(
            AppLogger.networking,
            operation: "calculateBazi",
            context: [
                "birth": request.birthDatetime,
                "gender": request.gender,
                "timezone": request.timezone,
                "place": request.placeName ?? "nil",
            ]
        ) {
            try await self.apiClient.calculateBazi(request: request)
        }

        // 取消检查(2026-09-08 排盘可取消):网络层可能吞掉取消信号(如 mock 替身
        // try? sleep),被取消的任务不得继续落档——用户已取消,半程产物不进库,
        // 后续 link 写入同因本检查抛出而短路。
        try Task.checkCancellation()

        // S05:柱缺失(时辰未知/S02 歧义)→ 日志位「—」,不猜干支
        AppLogger.app.info("calc.ok contentHash=\(response.contentHash, privacy: .public) pillars=\(response.pillars.year?.ganZhi ?? "—", privacy: .public)/\(response.pillars.month?.ganZhi ?? "—", privacy: .public)/\(response.pillars.day?.ganZhi ?? "—", privacy: .public)/\(response.pillars.hour?.ganZhi ?? "—", privacy: .public)")

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
        // 规则 2:函数入口日志
        AppLogger.app.info("deep.runInterpretation.start contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public)")
        // 次数检查(全局池口径,固定基础名;_free / _paid 共享每日 10 次)
        let counterModule = "bazi_deep"
        guard counter.tryConsume(module: counterModule) else {
            // 规则 1:抛错前打 warning(用户预期行为,非系统错误,但需要监控)
            // 注意:OSLogMessage 的字符串插值是 lazy capture,instance property
            // (counter.nextResetDate())必须先提到 local 变量
            let nextReset = counter.nextResetDate()
            AppLogger.app.warning("deep.runInterpretation.daily_limit_reached contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) nextReset=\(nextReset.description, privacy: .public)")
            throw DeepAnalysisError.dailyLimitReached(
                nextReset: nextReset,
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
                userLocalId: UserIdentity.userLocalId,
                contextToken: response.contextToken(forModule: module)
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
                    // i18n(2026-09-23 review P0-2):改存 resp.language(后端
                    // 实际渲染语言),读写键与 restore 侧配对。注意:本路径的
                    // bazi_deep 系列 en 模板未落地(prompts/en/ 只有 M0-M7+
                    // compat+daily,en 请求在后端渲染层即 500,到不了此写入),
                    // 今天 resp.language 恒 "zh";存 resp.language 是为 en 模板
                    // 落地后写入口径即自动正确(对齐 v1/compat/daily)。
                    language: resp.language,
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

    /// 批量恢复 v1 模块本地缓存(2026-09-08 断点续跑:冷启动回填已完成章)。
    ///
    /// maxAge=nil 不过期(命书章文本确定性,与 D2「瞬时显示」口径一致)。
    /// language 读 `AppLanguage.currentWire`:与写入口径配对(`runV1Module`
    /// upsert 存 `resp.language`,后端渲染语言与请求语言一致,二值相等)——
    /// 读写键必须同批迁移,否则 en 用户每次冷启动必 miss → 自动续跑反复
    /// 烧全链 LLM(2026-09-23 review P0-2 收口)。
    /// 返回值含「版本迁移重生成集」(2026-10-08 第十六轮外评 #1):被链
    /// 一致守卫跳过、本地仍有任意版本行的章,重算非用户过错,调用方生成
    /// 时豁免本地每日次数(防 M0 升版 → 整链重算扣满 10 次/日,已购内容
    /// 当天不可见)。
    /// 错误处理:identity 解析失败(离线)或 SwiftData 读失败原样上抛;
    /// 调用方(VM hydrateAndResume)记日志后跳过自动续跑,不打断 UI。
    func restoreCachedV1Modules(
        contentHash: String,
        modules: [String]
    ) async throws -> V1ChainRestoreOutcome {
        let outcome = try await interpretationReader.readAllForRestore(
            contentHash: contentHash,
            modules: modules,
            language: AppLanguage.currentWire
        )
        AppLogger.app.info(
            "deep.restoreCachedV1Modules hash=\(contentHash, privacy: .public) queried=\(modules.count) hits=\(outcome.hits.count) migrationRegen=\(outcome.migrationRegenModules.count)"
        )
        return outcome
    }

    /// 跨语言恢复(D10.5,S7):当前语言 miss 的模块,探测其它注册语言的
    /// 既有解读(命中模块数最多的语言)。调用方先显示原文再自动翻译(L3/F1)。
    func restoreCrossLanguageV1Modules(
        contentHash: String,
        modules: [String]
    ) async throws -> (language: String, hits: [String: InterpretationCache])? {
        try await interpretationReader.readAllCrossLanguage(
            contentHash: contentHash,
            modules: modules
        )
    }

    /// 老盘 token 失效重签(附八拍板②,失效期入口):章节 403 落
    /// `.contextTokenExpired` 时,VM 在 403 摄入点经此触发
    /// `ChartSnapshotStore.refreshContextTokens`——静默重排换新 token,
    /// hash 断言在 store 内。快照读失败 / decode 失败 / 排盘失败 →
    /// **显式留痕后按 nil 返回**,不 throw(重签是 best-effort 恢复,
    /// nil = 维持既有 403 出口;但 SwiftData/网络失败必须留日志——静默
    /// 吞掉违反 CLAUDE.md 错误显式传播,快照写入坏了会无线索)。
    func refreshChartContextTokens(contentHash: String) async -> BaziResponse? {
        let snapshot: ChartSnapshot
        do {
            guard let found = try chartStore.get(contentHash: contentHash) else {
                AppLogger.persistence.warning(
                    "op=deepOrchestrator.refreshChartContextTokens snapshot_missing hash=\(contentHash, privacy: .public) — 理论不可达(response 在档必有快照),维持既有 403 出口"
                )
                return nil
            }
            snapshot = found
        } catch {
            AppLogger.persistence.error(
                "op=deepOrchestrator.refreshChartContextTokens snapshot_read_failed hash=\(contentHash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
        do {
            return try await chartStore.refreshContextTokens(
                snapshot: snapshot, apiClient: apiClient)
        } catch {
            AppLogger.app.error(
                "op=deepOrchestrator.refreshChartContextTokens resign_failed hash=\(contentHash, privacy: .public) error=\(String(describing: error), privacy: .public) — 维持既有 403 出口"
            )
            return nil
        }
    }

    // MARK: - 阶段 2 v1:v1 prompt 系统模块化调用(Stage 7b)

    /// v1 prompt 系统单模块调用入口(M0-M7 链式调用每次调一个 module)。
    ///
    /// 与老 `runInterpretation`(单文本态 module)并存,服务 v1 链式调用架构:
    /// 1. M0 调用(无 parent_fingerprint)→ 返回 JSON 含 structure_fingerprint
    /// 2. VM 解析 M0 JSON 提取 structure_fingerprint / main_axis / core_loop
    /// 3. M1 调用(带 parentFingerprint)→ 返回 JSON 含 innate / defensive / one_leverage
    /// 4. M2-M7 按依赖图链式注入
    ///
    /// 计费策略(Stage 7b 默认,Stage 7c 接入 UI 时用户可调整):
    /// - 每模块独立消耗 1 次每日配额(走 counter 池 "bazi_deep")
    /// - 命中后端缓存 → refund(同老逻辑)
    /// - 失败 → refund(重试不消耗)
    ///
    /// 注:M4/M5 的用户输入通过 m4Input / m5Input tuple 传入,VM 在阅读页
    /// 页内表单(ChapterReadingInputForm)收集后传入。
    ///
    /// - Parameters:
    ///   - response:排盘响应(必须含 meta / tenGodWeights / usefulGodCandidates,
    ///     即 Stage 1+ 后端完整 schema;gender 从 response.meta.gender 取,
    ///     不再依赖 request 参数,与 backend chart_builder.build_v1_chart() 一致)
    ///   - module:v1 module 名(m0_structure ~ m7_manual)
    ///   - parentFingerprint:M0 输出的 structure_fingerprint;M1-M7 必填,M0 传 nil
    ///   - m4Input:M4 健康模块用户输入(age + concern);仅 m4_health 传非 nil
    ///   - m5Input:M5 财富模块用户输入(assets + preference);仅 m5_wealth 传非 nil
    ///   - chainFields:本模块必带的链式字段(main_axis/core_loop/innate/…,
    ///     值为上游模块 JSON 输出的序列化字符串)。VM 从 v1ChainFields 按
    ///     `ModuleID.requiredChainFields` 取出传入;M0 传空。
    ///     2026-09-25 接线:此前只发 structure_fingerprint,m1/m2/m5/m6/m7
    ///     真机必 422"prompt 渲染缺字段"(backend REQUIRED_FIELDS 校验)。
    func runV1Module(
        response: BaziResponse,
        module: String,
        parentFingerprint: String? = nil,
        m4Input: (age: Int, concern: String)? = nil,
        m5Input: (assets: String, preference: String)? = nil,
        chainFields: [String: String] = [:],
        quotaExempt: Bool = false
    ) async throws -> InterpretResponse {
        // P1 #3 修复:入参契约前置校验(对齐 backend Pydantic model_validator)。
        // 客户端层先拦,给清晰错误而非依赖网络 422 往返(对齐 CLAUDE.md 错误显式传播)。
        try Self.validateV1ModuleInputs(
            module: module,
            parentFingerprint: parentFingerprint,
            m4Input: m4Input,
            m5Input: m5Input,
            chainFields: chainFields
        )

        AppLogger.app.info("deep.runV1Module.start contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) hasParent=\(parentFingerprint != nil, privacy: .public)")

        // 次数检查(全局池 "bazi_deep";每模块独立消耗)。
        // quotaExempt(L4/F5,2026-10-01):语言切换引发的 STALE_SOURCE 降级
        // 重生成豁免——原文是旧 prompt 版本,非用户过错,不烧当日配额;
        // 豁免路径无消费故同样跳过 refund(退未消费的额度 = 白送配额)。
        // 扣/退逻辑收口 InterpretQuotaLedger(2026-10-07:三 orchestrator
        // 手写同款已开始漂移)。
        var ledger = InterpretQuotaLedger(
            counter: counter, module: "bazi_deep", hashForLog: response.contentHash
        )
        try ledger.consume(quotaExempt: quotaExempt, logLabel: "deep.runV1Module")

        do {
            let req = try Self.buildV1Request(
                response: response,
                module: module,
                parentFingerprint: parentFingerprint,
                m4Input: m4Input,
                m5Input: m5Input,
                chainFields: chainFields
            )

            let resp = try await AppLogger.measure(
                AppLogger.networking,
                operation: "interpret.v1",
                context: [
                    "content_hash": response.contentHash,
                    "module": module,
                ]
            ) {
                try await self.apiClient.interpret(request: req)
            }

            AppLogger.app.info("interpret.v1.ok contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) pv=\(resp.promptVersion) cached=\(resp.cached)")

            // F1(2026-10-02 修复):cached 命中只退**实际扣过**的额度。
            // quotaExempt 路径没走 tryConsume,不看豁免标志直接 refund
            // = 每章白送 1 次(L4 降级重生成 × 8 章 = 一张盘 +8)。
            ledger.settleCacheHit(cached: resp.cached)

            // 存本地缓存(每 module 独立,Stage 3 后端 CacheKey 已支持 parent_hash /
            // user_input_hash 隔离;iOS 端 InterpretationCacheStore 的 module 是 String,
            // 直接复用,无需 migration)
            try await AppLogger.measure(
                AppLogger.persistence,
                operation: "interpretationCache.v1.upsert",
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
                    // i18n(2026-09-23 review P0-2):v1 模块 en 全链 T1 已落地,
                    // 改存 resp.language(后端实际渲染语言)——写恒落默认 "zh"
                    // 会把 en 正文标 zh 存档(T5 切语言串台),且 en 用户冷启动
                    // 回填必 miss → 自动续跑反复烧全链 LLM。restoreCachedV1Modules
                    // 读侧已同批改 currentWire,读写键配对。对齐 compat/daily 修法。
                    language: resp.language,
                    provider: resp.provider,
                    model: resp.model,
                    interpretation: resp.interpretation,
                    generatedAt: resp.generatedAt
                )
            }

            return resp
        } catch let error as PromptContextError {
            // chart 构建失败(meta 缺失 / gan_zhi 异常 / JSON 序列化失败)→ 退款 + 显式抛错
            ledger.refundOnFailure()
            AppLogger.app.error("interpret.v1.prompt_context_failed contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        } catch {
            // AI / 本地缓存失败 → 退款(重试不消耗)
            ledger.refundOnFailure()
            AppLogger.app.error("interpret.v1.pipeline_failed contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// 翻译单个 v1 模块(D10.4,S7):原文 → 目标语言,译文写入目标语言缓存键。
    ///
    /// 与 `runV1Module` 共享 `buildV1Request`(D10.1 缓存键对齐的关键:翻译
    /// 请求的 context / parent_fingerprint / m4_* / m5_* 与目标语言下正常生成
    /// 会发的**逐字段相等**——译文落键后任何设备以目标语言请求 /api/interpret
    /// 都命中这份译文)。
    ///
    /// 计费:翻译**不消耗每日次数、不 refund**(D10.1:翻译不另收费;本地
    /// counter 池语义是「生成」配额,翻译绕过)。付费 module 的 entitlement
    /// 由后端同一道检查(403 照抛);VM 侧已有 locked 守卫前置拦截。
    ///
    /// 失败显式抛错(后端 STALE_SOURCE 409 = 原文版本过期,调用方应走正常
    /// 重新生成;保真校验失败 503 = 可重试),不回退原文、不静默改走生成。
    func translateV1Module(
        response: BaziResponse,
        module: String,
        parentFingerprint: String? = nil,
        m4Input: (age: Int, concern: String)? = nil,
        m5Input: (assets: String, preference: String)? = nil,
        chainFields: [String: String] = [:],
        sourceLanguage: String,
        sourcePromptVersion: Int,
        sourceInterpretation: String
    ) async throws -> InterpretResponse {
        try Self.validateV1ModuleInputs(
            module: module,
            parentFingerprint: parentFingerprint,
            m4Input: m4Input,
            m5Input: m5Input,
            chainFields: chainFields
        )
        let req = try Self.buildV1Request(
            response: response,
            module: module,
            parentFingerprint: parentFingerprint,
            m4Input: m4Input,
            m5Input: m5Input,
            chainFields: chainFields
        )
        let translateReq = TranslateRequest(
            base: req,
            sourceLanguage: sourceLanguage,
            sourcePromptVersion: sourcePromptVersion,
            sourceInterpretation: sourceInterpretation
        )
        AppLogger.app.info(
            "deep.translateV1Module.start contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) source=\(sourceLanguage, privacy: .public)"
        )
        let resp = try await AppLogger.measure(
            AppLogger.networking,
            operation: "interpret.translate",
            context: [
                "content_hash": response.contentHash,
                "module": module,
            ]
        ) {
            try await self.apiClient.translate(request: translateReq)
        }
        try await AppLogger.measure(
            AppLogger.persistence,
            operation: "interpretationCache.translate.upsert",
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
                // 译文落目标语言键(后端 resp.language = 目标语言)——与
                // runV1Module 写入口径一致,读写键配对
                language: resp.language,
                provider: resp.provider,
                model: resp.model,
                interpretation: resp.interpretation,
                generatedAt: resp.generatedAt
            )
        }
        AppLogger.app.info(
            "deep.translateV1Module.ok contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) cached=\(resp.cached, privacy: .public) source=\(sourceLanguage, privacy: .public) target=\(resp.language, privacy: .public)"
        )
        return resp
    }

    /// v1 module 请求构建(生成 runV1Module 与翻译 translateV1Module 共用)。
    ///
    /// D10.1「请求体 = 内容按目标语言请求 /api/interpret 时会发的那份」——
    /// 两个消费方跑同一构建器,禁止各自拼装(键漂移 = 译文缓存永不命中且不报错)。
    /// chart JSON 按 v1 §1 schema(与 backend chart_builder.build_v1_chart 对齐);
    /// 链式字段只合并不组装(VM 知道依赖图)。
    private static func buildV1Request(
        response: BaziResponse,
        module: String,
        parentFingerprint: String?,
        m4Input: (age: Int, concern: String)?,
        m5Input: (assets: String, preference: String)?,
        chainFields: [String: String]
    ) throws -> InterpretRequest {
        let chartJSON = try PromptContextBuilder.buildV1ChartJSON(response: response)
        var context: [String: AnyCodableJSON] = [
            "chart": AnyCodableJSON(chartJSON),
        ]
        if let parentFingerprint {
            context["structure_fingerprint"] = AnyCodableJSON(parentFingerprint)
        }
        if let m4Input {
            context["age"] = AnyCodableJSON(m4Input.age)
            context["current_concern"] = AnyCodableJSON(m4Input.concern)
        }
        if let m5Input {
            context["assets_summary"] = AnyCodableJSON(m5Input.assets)
            context["preference"] = AnyCodableJSON(m5Input.preference)
        }
        for (key, value) in chainFields {
            context[key] = AnyCodableJSON(value)
        }
        return InterpretRequest(
            contentHash: response.contentHash,
            module: module,
            context: context,
            targetDate: nil,
            question: nil,
            userLocalId: UserIdentity.userLocalId,
            parentFingerprint: parentFingerprint,
            m4Age: m4Input?.age,
            m4CurrentConcern: m4Input?.concern,
            m5AssetsSummary: m5Input?.assets,
            m5Preference: m5Input?.preference,
            contextToken: response.contextToken(forModule: module)
        )
    }

    /// v1 module 入参契约校验(对齐 backend Pydantic model_validator)。
    /// 客户端层先拦,避免无效组合走网络往返返 422。
    ///
    /// 校验规则(对齐 backend app/models/interpret.py):
    /// - M0(m0_structure)不需要 parent_fingerprint;M1-M7 必填
    /// - M4(m4_health)必填 m4Input(age + concern);其他 module 必须为 nil
    /// - M5(m5_wealth)必填 m5Input(assets + preference);其他 module 必须为 nil
    private static func validateV1ModuleInputs(
        module: String,
        parentFingerprint: String?,
        m4Input: (age: Int, concern: String)?,
        m5Input: (assets: String, preference: String)?,
        chainFields: [String: String] = [:]
    ) throws {
        // parent_fingerprint 契约:M0 不需要,M1-M7 必填
        let isM0 = (module == "m0_structure")
        if !isM0 && parentFingerprint == nil {
            throw DeepAnalysisError.invalidV1ModuleInput(
                "module=\(module) 必须传 parentFingerprint(M0 产出的 structure_fingerprint)"
            )
        }

        // 链式字段契约(2026-09-25 对称补全):本模块必带字段(main_axis 等)
        // 必须随 chainFields 传入。VM 守卫已拦 .pending,此处是纵深防御——
        // 防未来非 VM 调用方/守卫回归时白发注定 422 的请求(对齐 P1 #3 前置校验)。
        if let moduleID = ModuleID(rawValue: module) {
            let missing = moduleID.requiredChainFields.filter { chainFields[$0] == nil }
            if !missing.isEmpty {
                throw DeepAnalysisError.invalidV1ModuleInput(
                    "module=\(module) 缺链式字段 \(missing.joined(separator: ","))(应随 chainFields 传入,值来自上游模块输出)"
                )
            }
        }

        // M4 入参契约:必须传 m4Input,其他 module 不应传
        let isM4 = (module == "m4_health")
        if isM4 && m4Input == nil {
            throw DeepAnalysisError.invalidV1ModuleInput(
                "module=m4_health 必须传 m4Input(age + concern)"
            )
        }
        if !isM4 && m4Input != nil {
            throw DeepAnalysisError.invalidV1ModuleInput(
                "module=\(module) 不应传 m4Input(仅 m4_health 使用)"
            )
        }

        // M5 入参契约:必须传 m5Input,其他 module 不应传
        let isM5 = (module == "m5_wealth")
        if isM5 && m5Input == nil {
            throw DeepAnalysisError.invalidV1ModuleInput(
                "module=m5_wealth 必须传 m5Input(assets + preference)"
            )
        }
        if !isM5 && m5Input != nil {
            throw DeepAnalysisError.invalidV1ModuleInput(
                "module=\(module) 不应传 m5Input(仅 m5_wealth 使用)"
            )
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
}

// MARK: - DeepAnalysisError

/// 深度解析领域错误。
/// errorDescription 是**用户可见文案**(2026-08-16:代码性错误不进 UI);
/// invalidV1ModuleInput 的契约违反详情留在 associated value,由 VM 各 catch
/// 的 AppLogger(String(describing: error))记录。
enum DeepAnalysisError: Error, LocalizedError {
    /// 每日次数已达上限。nextReset: 本地午夜;remaining: 剩余次数(0)。
    case dailyLimitReached(nextReset: Date, remaining: Int)
    /// v1 prompt 系统模块入参契约违反(Stage 7b 引入)。
    /// 客户端层显式拦截,避免依赖后端 422 往返。
    case invalidV1ModuleInput(String)
    /// L5/F3:跨语言译文未过 v4 五段契约(后端保真校验失守的客户端兜底,
    /// 坏译文不落缓存——毒化会静默卡到次日,见 S6 缓存自愈背景)。
    case translatedContentInvalid

    var errorDescription: String? {
        switch self {
        case .dailyLimitReached:
            return "今日机缘已尽,明日再来"
        case .invalidV1ModuleInput:
            return "解读生成失败,请重试"
        case .translatedContentInvalid:
            return "翻译失败,请重试"
        }
    }
}
