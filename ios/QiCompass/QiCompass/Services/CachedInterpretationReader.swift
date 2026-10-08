import Foundation

/// 客户端读 AI 缓存的唯一入口 module。
///
/// 集中执行 ADR-0009 强约束:读 AI 缓存前必须 health 解析身份,只接受 provider/model 完全匹配的行,
/// nil 旧行永不命中。把这条约束的执行点从 N 个调用点收敛到 1 处:
/// - `DeepAnalysisOrchestrator.restoreCachedV1Modules`(批量,冷启动回填,不过期)
/// - `CompatibilityOrchestrator.runInterpretation` 内 cache 查询(24h)
/// - `CompatibilityOrchestrator.cachedInterpretationIfFresh`(瞬时显示,24h)
/// - `DailyFortuneOrchestrator.runInterpretation` 内 cache 查询(24h)
/// - `DailyFortuneOrchestrator.cachedInterpretationIfFresh`(瞬时显示,24h)
///
/// 不负责命中后的 module-specific sync 副作用(写 `CompatibilitySnapshot` / `DailyFortuneSnapshot`),
/// 因为 sync 类型不同无法合并,留在 caller。
///
/// 2026-10-01 新增第二职责:V1 模块(M0-M7)中毒缓存自愈(`purgeIfPoisoned`)——
/// 命中行过不了渲染层 JSON 校验(截断/契约破坏)即删行当 miss,镜像后端坏 JSON 自愈。
///
/// 错误显式传播:identity 解析失败或 SwiftData 读失败向上抛,不静默吞(CLAUDE.md 强约束)。
@MainActor
final class CachedInterpretationReader {
    private let identityResolver: AIIdentityResolver
    private let cacheStore: InterpretationCacheStore

    init(identityResolver: AIIdentityResolver, cacheStore: InterpretationCacheStore) {
        self.identityResolver = identityResolver
        self.cacheStore = cacheStore
    }

    /// 读 AI 缓存。
    /// - Parameters:
    ///   - contentHash: `ChartSnapshot.contentHash` 或 `CompatibilitySnapshot.compatibilityHash`
    ///   - module: `"bazi_deep"` / `"compatibility"` / `"daily_fortune"`,以及
    ///     M0-M7 模块名(`ModuleID.rawValue`,走 `purgeIfPoisoned` 中毒自愈)
    ///   - targetDate: 每日运势传 date,其他传 nil(默认)
    ///   - maxAge: 新鲜度上限,`nil` = 不过期(`DeepAnalysis` 瞬时显示用);其他传 `24 * 3600`
    /// - Returns: 命中的完整 `InterpretationCache`;miss / 过期 / 身份不匹配(cacheStore 内 filter)/
    ///     V1 模块中毒行(已删,见 `purgeIfPoisoned`)都返回 nil
    /// - Throws: identity 解析失败或 SwiftData 读失败向上抛
    ///
    /// i18n:language 由 `AppLanguage.currentWire` 自动注入(i18n 决策 10 方案 3:
    /// 查询缓存时用客户端 locale 推断)。调用方不需要传 language。
    func read(
        contentHash: String,
        module: String,
        targetDate: Date? = nil,
        maxAge: TimeInterval? = nil
    ) async throws -> InterpretationCache? {
        let identity = try await identityResolver.resolve()
        guard let cache = try cacheStore.getLatest(
            contentHash: contentHash,
            module: module,
            targetDate: targetDate,
            language: AppLanguage.currentWire,
            identity: identity
        ) else {
            return nil
        }
        if try purgeIfPoisoned(cache) {
            return nil
        }
        if let maxAge, cache.generatedAt.addingTimeInterval(maxAge) <= .now {
            return nil
        }
        return cache
    }

    /// 批量读 AI 缓存(冷启动回填捌章用)。
    ///
    /// 与逐个调 `read` 的区别:**identity 只 resolve 一次**复用给全部 module 查询
    /// (resolver 无缓存、每次 resolve 都打 health 网络调用;捌章逐查 = 8 次往返,
    /// 批量收敛到 1 次)。ADR-0009 语义是「读缓存前的身份强校验」,同批查询共享
    /// 一次 resolve 不违反约束(身份漂移由写入时的 identity 维度自然隔离)。
    ///
    /// - Parameters:
    ///   - modules:module 名数组;命中才进结果字典,miss 不进(调用方以字典缺键判 miss)
    ///   - language:**必传**目标语言代码(调用方传 `AppLanguage.currentWire`,
    ///     与写入侧 upsert 的 `resp.language` 配对——后端按请求语言渲染,
    ///     两值一致;读写键错位会让 en 用户冷启动必 miss → 自动续跑烧 LLM)
    /// - Returns:module 名 → 命中的 `InterpretationCache`(V1 中毒行已删并当 miss,不进字典)
    /// - Throws:identity 解析失败或任一 SwiftData 读失败向上抛(整体失败,
    ///   不逐章吞——环境错误值得整体跳过回填而非装作部分命中)
    func readAll(
        contentHash: String,
        modules: [String],
        language: String,
        targetDate: Date? = nil,
        maxAge: TimeInterval? = nil
    ) async throws -> [String: InterpretationCache] {
        let identity = try await identityResolver.resolve()
        return try readAll(
            contentHash: contentHash,
            modules: modules,
            language: language,
            targetDate: targetDate,
            maxAge: maxAge,
            identity: identity
        )
    }

    /// 批量读核心(调用方传入已 resolve 的 identity;#8,2026-10-02 抽出:
    /// 跨语言读取按语言循环时复用同一 identity,不再每语言各打一次 health)。
    ///
    /// 链一致守卫(2026-10-08 第十五轮 #7):本地缓存键不含上游指纹,getLatest
    /// 只按**本模块**版本过滤——上游(如 M0)单侧 bump 后,下游旧版本行照常
    /// 命中 → 命书新旧混拼 + 这些章翻译恒 409(服务端链走查按新上游重建键)。
    /// 模块按传入序消费(M0→M7,生产者恒在消费者前):任一模块「服务端版本
    /// 已知且本地无当前版本命中」→ 其后模块全部跳过回填,链整段重算(服务端
    /// 新键自然 miss;下游既有行经重取自愈,不多烧 LLM)。「无命中」兼含
    /// 「从未生成」——该场景下游也未生成,跳过无副作用;「该章此前失败但
    /// 下游有行」的代价仅为下游重取(服务端缓存命中,零 LLM)。跨语言探测
    /// (includeStaleVersions=true)下「无命中」= 真无行,守卫同义成立。
    ///
    /// includeStaleVersions(十四轮外评 #5):跨语言探测传 true——prompt bump
    /// 后旧语言原文只在旧版本下,版本过滤会把探测源一并滤掉(设计降级路径
    /// 「翻译 → 409 STALE → quotaExempt 重生成」被旁路成普通生成扣额)。
    private func readAll(
        contentHash: String,
        modules: [String],
        language: String,
        targetDate: Date?,
        maxAge: TimeInterval?,
        identity: AIIdentity,
        includeStaleVersions: Bool = false
    ) throws -> [String: InterpretationCache] {
        var hits: [String: InterpretationCache] = [:]
        // 守卫只对 v1 链生效(modules 以 m0_structure 起头 = DeepAnalysis
        // 链式回填);合盘的「paid/free 任一命中」语义里 paid 常年缺席,
        // 前缀切断会误伤 free 行命中,不适用
        let isV1Chain = modules.first == "m0_structure"
        var chainCut = false
        for module in modules {
            guard !chainCut else { break }
            guard let cache = try latestHit(
                contentHash: contentHash,
                module: module,
                language: language,
                targetDate: targetDate,
                maxAge: maxAge,
                identity: identity,
                includeStaleVersions: includeStaleVersions
            ) else {
                // 版本已知却无当前版本行 = 上游已 bump 本地未跟上 → 下游行
                // 是旧上游驱动的,不再回填(版本未知 = 老后端,维持旧行为)
                if isV1Chain, identity.promptVersions[module] != nil {
                    chainCut = true
                }
                continue
            }
            hits[module] = cache
        }
        return hits
    }

    /// 单行读取(getLatest + 中毒自愈 + 新鲜度三步,#8 抽出为唯一实现):
    /// `readAll` 核心与 `readCrossLanguageByModulePriority` 共用——两套
    /// 循环各自内联这三步会漂移(改自愈口径漏一边)。
    private func latestHit(
        contentHash: String,
        module: String,
        language: String,
        targetDate: Date?,
        maxAge: TimeInterval?,
        identity: AIIdentity,
        includeStaleVersions: Bool = false
    ) throws -> InterpretationCache? {
        guard let cache = try cacheStore.getLatest(
            contentHash: contentHash,
            module: module,
            targetDate: targetDate,
            language: language,
            identity: identity,
            includeStaleVersions: includeStaleVersions
        ) else {
            return nil
        }
        if try purgeIfPoisoned(cache) {
            return nil
        }
        if let maxAge, cache.generatedAt.addingTimeInterval(maxAge) <= .now {
            return nil
        }
        return cache
    }

    // MARK: - 跨语言查找(D10.5,S7)

    /// 跨语言探测:按「当前语言之外的全部注册语言」查缓存,取**命中模块数最多**
    /// 的语言(并列取 `AppLanguage.allCases` 序,确定性)。
    ///
    /// 用途:切语言后当前语言缓存 miss 时,找到其它语言的既有解读 → 先显示
    /// 原文,L3/F1(修订 D10.5)起打开即自动翻译,失败才出提示条重试。
    /// 中毒行同 `readAll` 口径删除当 miss;过期语义同 `maxAge` 参数。
    ///
    /// #8(2026-10-02):**identity 只 resolve 一次**——此前逐语言调 `readAll`,
    /// 每语言各 resolve 一次(= 一次 `/api/health` 往返;三语下当前语言
    /// 未命中时白多 2 次,离线时还没尝试生成就先抛错)。同批共享 resolve
    /// 不违反 ADR-0009(身份漂移由写入时的 identity 维度隔离,见 `readAll`
    /// 注释)。
    ///
    /// - Parameter rowIsValid:可选行级过滤(命中但不满足的行**不参与**该语言
    ///   的候选计数,行保留不删)——每日运势用它跳过不满足 v4 五段契约的
    ///   坏行、继续尝试其它语言(此前只看「最优语言」那一行,坏行直接判
    ///   无源)。nil = 不过滤。
    /// - Returns:命中语言 + module 名 → 缓存行;任何语言都无命中 → nil
    /// - Throws:identity 解析失败或 SwiftData 读失败向上抛
    func readAllCrossLanguage(
        contentHash: String,
        modules: [String],
        targetDate: Date? = nil,
        maxAge: TimeInterval? = nil,
        rowIsValid: ((InterpretationCache) -> Bool)? = nil
    ) async throws -> (language: String, hits: [String: InterpretationCache])? {
        let identity = try await identityResolver.resolve()
        let otherLanguages = AppLanguage.allCases
            .map(\.rawValue)
            .filter { $0 != AppLanguage.currentWire }
        var best: (language: String, hits: [String: InterpretationCache])?
        for language in otherLanguages {
            var hits = try readAll(
                contentHash: contentHash,
                modules: modules,
                language: language,
                targetDate: targetDate,
                maxAge: maxAge,
                identity: identity,
                // 旧版源行放行(十四轮外评 #5):跨语言探测的目的是找「可翻译
                // 的既有原文」,bump 前的旧版行正是翻译降级路径的源;命中后
                // 提交翻译,后端 STALE 门控 409 → quotaExempt 重生成,链路闭环。
                includeStaleVersions: true
            )
            if let rowIsValid {
                hits = hits.filter { rowIsValid($0.value) }
            }
            if hits.isEmpty { continue }
            if let currentBest = best {
                if hits.count > currentBest.hits.count {
                    best = (language, hits)
                } else if hits.count == currentBest.hits.count,
                          maxPromptVersion(in: hits) > maxPromptVersion(in: currentBest.hits) {
                    // Bug4(2026-10-06 review 核实):命中数平手时按行内 promptVersion
                    // 高者优先。daily 单模块场景两语言命中数恒 1,修复前按
                    // allCases 序选源——PROMPT_VERSIONS bump 后旧版(v1)源会压过
                    // 有效(v2)源,翻译必 409 STALE_SOURCE 落穿重生成:本可翻译
                    // (保「换语言结论不变」)的另一语言源被掩蔽,切语言内容漂移。
                    // 多模块(deep)下计数仍为主序,版本只裁决平手,行为兼容。
                    best = (language, hits)
                }
            } else {
                best = (language, hits)
            }
        }
        return best
    }

    /// 行集内最高 promptVersion(Bug4 平手裁决用;调用前已过滤空集,
    /// 空集返回 0 仅为闭包完备)。
    private func maxPromptVersion(in hits: [String: InterpretationCache]) -> Int {
        hits.values.map(\.promptVersion).max() ?? 0
    }

    /// 跨语言探测(模块优先版,2026-10-02 修复;2026-10-07 第五轮 review 补
    /// 版本裁决):按 `modules` 顺序在「其它语言」里逐模块探测,同 module
    /// 命中多语言时**版本高者优先,平手保 `allCases` 语言序**(确定性)。
    ///
    /// 与逐模块调 `readAllCrossLanguage` 行为对齐(Bug4 平手裁决同款,合盘
    /// 双键单模块场景即其等价形态):修复前先命中先返回,PROMPT_VERSIONS
    /// bump 后旧版源(如 zh v1 行)会压过另一语言的有效行(v4)→ 翻译必
    /// 409 STALE_SOURCE 落穿重生成,本可翻译保结论的源被掩蔽,切语言内容
    /// 漂移。identity 只 resolve 一次(合盘 cross-language 查询若逐模块调
    /// `readAllCrossLanguage`,每次内部又逐语言调 `readAll`——每次 resolve
    /// 都是一次 `/api/health` 往返,一次 detail 打开最多 5 次;同批共享
    /// resolve 不违反 ADR-0009,见 `readAll` 注释)。行读取走共享
    /// `latestHit`(与 `readAll` 同一套 getLatest/自愈/新鲜度口径)。
    ///
    /// - Returns:命中的 module 名 + 语言 + 缓存行;全部 miss → nil
    /// - Throws:identity 解析失败或 SwiftData 读失败向上抛
    func readCrossLanguageByModulePriority(
        contentHash: String,
        modules: [String],
        targetDate: Date? = nil,
        maxAge: TimeInterval? = nil
    ) async throws -> (module: String, language: String, row: InterpretationCache)? {
        let identity = try await identityResolver.resolve()
        let otherLanguages = AppLanguage.allCases
            .map(\.rawValue)
            .filter { $0 != AppLanguage.currentWire }
        for module in modules {
            var best: (language: String, row: InterpretationCache)?
            for language in otherLanguages {
                guard let cache = try latestHit(
                    contentHash: contentHash,
                    module: module,
                    language: language,
                    targetDate: targetDate,
                    maxAge: maxAge,
                    identity: identity
                ) else { continue }
                // 版本高者胜出;平手(<=)保先到的语言序,与 readAllCrossLanguage
                // 的 Bug4 裁决同款
                if let current = best,
                   cache.promptVersion <= current.row.promptVersion {
                    continue
                }
                best = (language, cache)
            }
            if let best {
                return (module, best.language, best.row)
            }
        }
        return nil
    }

    // MARK: - V1 模块中毒缓存自愈(2026-10-01)

    /// V1 深度模块(M0-M7)中毒缓存检测 + 删除,镜像后端 `_validate_v1_module_json` +
    /// `_invalidate_poisoned_cache`(backend/app/api/interpret.py)。
    ///
    /// 背景:2026-09-27 真机 m1 被 max_tokens=1024 拦腰截断,半截 JSON 入双层缓存。
    /// 后端侧当时已补「命中坏 JSON → 删除 → 落穿重生成」+ pv 1→2 失效缓存,但 iOS
    /// 侧无对应机制:深度模块缓存不过期(maxAge=nil)+ 本地命中短路不再请求后端 +
    /// promptVersion 只能从响应学得 → **pv bump 永远够不到本地已缓存的存量中毒行**,
    /// 阅读页 parse 失败退散文 = JSON 裸奔(第一章短压线完整、第二章截断的分裂现象)。
    ///
    /// 判据:直接复用渲染层 `ChapterContent.parse`(nil = 非 JSON / 顶层非对象 /
    /// 无可渲染节点),与后端校验天然同口径且只严不宽。命中即删行返回 true,调用方
    /// 按 miss 处理 → 上层断点续跑自动以当前 pv 重新生成、写回干净行。
    ///
    /// 护栏(不可放宽):仅 module ∈ ModuleID(M0-M7)生效。合盘/每日/bazi_deep 的
    /// 输出契约是散文,parse 必失败——不按 ModuleID 圈定会误清全部正常缓存。
    ///
    /// - Returns:true = 中毒行已删(调用方按 miss 处理)
    private func purgeIfPoisoned(_ cache: InterpretationCache) throws -> Bool {
        guard ModuleID(rawValue: cache.module) != nil else { return false }
        guard ChapterContent.parse(cache.interpretation) == nil else { return false }
        try cacheStore.delete(cache)
        return true
    }
}
