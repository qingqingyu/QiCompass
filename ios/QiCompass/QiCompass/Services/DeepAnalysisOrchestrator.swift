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
    /// - Parameter alias: 命盘展示别名("我自己" / "妈妈" / "男友"),默认"我自己" 向后兼容。
    ///   v2 PR1 起由调用方传入(BirthFormView 表单顶部 TextField 收集)。
    func runCalculation(request: BaziCalculateRequest, alias: String = "我自己") async throws -> BaziResponse {
        // 规则 2:函数入口日志(网络调用内部已通过 AppLogger.measure 覆盖 start/ok/failed)
        AppLogger.app.info("deep.runCalculation.start birth=\(request.birthDatetime, privacy: .public) tz=\(request.timezone, privacy: .public) gender=\(request.gender, privacy: .public) place=\(request.placeName ?? "nil", privacy: .public) lon=\(request.longitude, privacy: .public)")
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

        AppLogger.app.info("calc.ok contentHash=\(response.contentHash, privacy: .public) pillars=\(response.pillars.year.ganZhi, privacy: .public)/\(response.pillars.month.ganZhi, privacy: .public)/\(response.pillars.day.ganZhi, privacy: .public)/\(response.pillars.hour.ganZhi, privacy: .public)")

        // 存档(失败 throw → chartFailed,不提示"命盘已保存")
        _ = try chartStore.upsert(response: response, request: request)

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
                    // i18n TODO(Slice 2):bazi_deep 未实现英文翻译,
                    // 缓存暂时走 default language="zh"(InterpretationCacheStore.upsert 默认值)。
                    // Slice 2 补齐 bazi_deep 翻译后改 language: resp.language
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
            // maxAge=nil 不过期(DeepAnalysis 瞬时显示,§4.5 v1 简化)
            guard let cache = try await interpretationReader.read(
                contentHash: contentHash,
                module: module
            ) else {
                return nil
            }
            return (cache.interpretation, cache.promptVersion)
        } catch {
            AppLogger.persistence.error(
                "interpretationReader.read failed hash=\(contentHash, privacy: .public) module=\(module, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            throw error
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
    /// 注:M4/M5 的用户输入通过 m4Input / m5Input tuple 传入,VM 在 Stage 8
    /// 通过 HealthInputForm / WealthInputForm sheet 收集后传入。
    ///
    /// - Parameters:
    ///   - response:排盘响应(必须含 meta / tenGodWeights / usefulGodCandidates,
    ///     即 Stage 1+ 后端完整 schema;gender 从 response.meta.gender 取,
    ///     不再依赖 request 参数,与 backend chart_builder.build_v1_chart() 一致)
    ///   - module:v1 module 名(m0_structure ~ m7_manual)
    ///   - parentFingerprint:M0 输出的 structure_fingerprint;M1-M7 必填,M0 传 nil
    ///   - m4Input:M4 健康模块用户输入(age + concern);仅 m4_health 传非 nil
    ///   - m5Input:M5 财富模块用户输入(assets + preference);仅 m5_wealth 传非 nil
    func runV1Module(
        response: BaziResponse,
        module: String,
        parentFingerprint: String? = nil,
        m4Input: (age: Int, concern: String)? = nil,
        m5Input: (assets: String, preference: String)? = nil
    ) async throws -> InterpretResponse {
        // P1 #3 修复:入参契约前置校验(对齐 backend Pydantic model_validator)。
        // 客户端层先拦,给清晰错误而非依赖网络 422 往返(对齐 CLAUDE.md 错误显式传播)。
        try Self.validateV1ModuleInputs(
            module: module,
            parentFingerprint: parentFingerprint,
            m4Input: m4Input,
            m5Input: m5Input
        )

        AppLogger.app.info("deep.runV1Module.start contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) hasParent=\(parentFingerprint != nil, privacy: .public)")

        // 次数检查(全局池 "bazi_deep";每模块独立消耗)
        let counterModule = "bazi_deep"
        guard counter.tryConsume(module: counterModule) else {
            let nextReset = counter.nextResetDate()
            AppLogger.app.warning("deep.runV1Module.daily_limit_reached contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) nextReset=\(nextReset.description, privacy: .public)")
            throw DeepAnalysisError.dailyLimitReached(nextReset: nextReset, remaining: 0)
        }

        var shouldRefundOnFailure = true

        do {
            // 构造 chart JSON(v1 §1 schema,与 backend chart_builder.build_v1_chart 对齐)
            let chartJSON = try PromptContextBuilder.buildV1ChartJSON(response: response)

            // 构造 context:每 module 的占位符见 backend prompts.py REQUIRED_FIELDS
            // M7 不需要 chart(模板不读),但传入无害(后端不强制校验)
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
            // M1-M7 的链式字段(main_axis/core_loop/innate/defensive/threshold/
            // ideal_life_structure/one_leverage/switch_actions/environment_checklist/
            // leverage)由 VM 在调用前塞入 context(从上游模块 JSON 输出提取)
            // 本函数不负责组装这些字段(VM 知道依赖图,orchestrator 不重复实现)

            let req = InterpretRequest(
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
                m5Preference: m5Input?.preference
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

            if resp.cached {
                counter.refund(module: counterModule)
                shouldRefundOnFailure = false
            }

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
                    provider: resp.provider,
                    model: resp.model,
                    interpretation: resp.interpretation,
                    generatedAt: resp.generatedAt
                )
            }

            return resp
        } catch let error as PromptContextError {
            // chart 构建失败(meta 缺失 / gan_zhi 异常 / JSON 序列化失败)→ 退款 + 显式抛错
            if shouldRefundOnFailure {
                counter.refund(module: counterModule)
            }
            AppLogger.app.error("interpret.v1.prompt_context_failed contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        } catch {
            // AI / 本地缓存失败 → 退款(重试不消耗)
            if shouldRefundOnFailure {
                counter.refund(module: counterModule)
            }
            AppLogger.app.error("interpret.v1.pipeline_failed contentHash=\(response.contentHash, privacy: .public) module=\(module, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw error
        }
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
        m5Input: (assets: String, preference: String)?
    ) throws {
        // parent_fingerprint 契约:M0 不需要,M1-M7 必填
        let isM0 = (module == "m0_structure")
        if !isM0 && parentFingerprint == nil {
            throw DeepAnalysisError.invalidV1ModuleInput(
                "module=\(module) 必须传 parentFingerprint(M0 产出的 structure_fingerprint)"
            )
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
enum DeepAnalysisError: Error, LocalizedError {
    /// 每日次数已达上限。nextReset: 本地午夜;remaining: 剩余次数(0)。
    case dailyLimitReached(nextReset: Date, remaining: Int)
    /// v1 prompt 系统模块入参契约违反(Stage 7b 引入)。
    /// 客户端层显式拦截,避免依赖后端 422 往返。
    case invalidV1ModuleInput(String)

    var errorDescription: String? {
        switch self {
        case .dailyLimitReached:
            return "今日机缘已尽,明日再来"
        case .invalidV1ModuleInput(let message):
            return message
        }
    }
}
