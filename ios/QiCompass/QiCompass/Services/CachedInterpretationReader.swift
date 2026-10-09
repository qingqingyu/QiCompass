import Foundation

/// V1 链回填读结果(`readAllForRestore`,2026-10-08 第十六轮外评 #1)。
struct V1ChainRestoreOutcome {
    /// 命中 module 名 → 缓存行(与 `readAll` 同口径:中毒行已删当 miss)
    let hits: [String: InterpretationCache]
    /// 版本迁移重生成集:被链一致守卫跳过回填、且本地存在任意版本行的模块。
    /// 这些章的重算由服务端 prompt 版本 bump 强制(用户无过错),调用方
    /// `runV1Module` 应传 `quotaExempt: true` 豁免本地每日次数;章成功落
    /// 当前版本行后由调用方出集(一次性豁免)。
    let migrationRegenModules: Set<String>
}

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
        return try readAllCore(
            contentHash: contentHash,
            modules: modules,
            language: language,
            targetDate: targetDate,
            maxAge: maxAge,
            identity: identity
        ).hits
    }

    /// V1 链回填读(2026-10-08 第十六轮外评 #1):`readAll` 的回填专用形态,
    /// 额外返回**版本迁移重生成集**——被链一致守卫跳过回填、且本地存在任意
    /// 版本行(中毒行经 latestHit 口径先行清除)的模块。这些模块的重算是
    /// 服务端 prompt 版本 bump 强制的(用户无过错):调用方重生成时应豁免
    /// 本地每日次数,否则 M0 升版 → 整链重算逐章扣本地池(付费盘 2 张 =
    /// 16 次 > 10 次/日),已购内容当天达限不可见。首次生成(本地无任何行)
    /// 不进集合,照常计费。
    func readAllForRestore(
        contentHash: String,
        modules: [String],
        language: String,
        targetDate: Date? = nil,
        maxAge: TimeInterval? = nil
    ) async throws -> V1ChainRestoreOutcome {
        let identity = try await identityResolver.resolve()
        return try readAllCore(
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
    /// 链一致守卫(2026-10-08 第十五轮 #7;十六轮改**依赖图切断**——houduan
    /// `transitiveDependents` 机制 + neirong 版本迁移集,撞车消解融合;
    /// 十七轮 #3 补**清单外上游**缺行检查):
    /// 本地缓存键不含上游指纹,getLatest 只按**本模块**版本过滤——上游
    /// (如 M0)单侧 bump 后,下游旧版本行照常命中 → 命书新旧混拼 + 这些章
    /// 翻译恒 409(服务端链走查按新上游重建键)。守卫只切断缺行模块的
    /// **传递依赖方**(`ModuleID.transitiveDependents`,镜像后端
    /// `_V1_SOURCE_WALK_DEPS` 的血统含 m0——M1-M7 的 parent_fingerprint
    /// 恒取自 M0,m7 声明依赖虽不含 m0 也在传递闭包内):旧「列表序前缀
    /// 一刀切」会误伤不依赖缺失章的下游(如 M4 缺行时 M5-M7 全被跳过
    /// ——M4 不在任何模块的依赖里,本不必断;离线可读/跨语言可译的行白丢)。
    /// 缺行判定含**不在本次清单里的上游**(十七轮 #3):上游可能处于
    /// .dailyLimitReached / .contextTokenExpired / .fetching / .pending 等
    /// 不可回填态而不进清单,但「不在清单」≠「有当前版本行」——只看清单
    /// 内模块时,M0 升版重生成 429 达限后重进页面,M1-M7 旧行会被恢复成
    /// 旧链(混拼 + 翻译 409)。对「清单内模块的依赖 ∪ {m0} − 清单」逐一
    /// 查行,缺行则其传递依赖方同款切断。
    /// 跨语言探测(includeStaleVersions=true)下「无命中」= 真无行,
    /// 守卫同义成立(行判定同样放行旧版行——旧版源正是可翻译的探测源);
    /// 该模式下迁移集不计算(调用方只消费 hits,十七轮 #7:省掉白做的
    /// hasAnyVersionRow 查询)。
    ///
    /// includeStaleVersions(十四轮外评 #5):跨语言探测传 true——prompt bump
    /// 后旧语言原文只在旧版本下,版本过滤会把探测源一并滤掉(设计降级路径
    /// 「翻译 → 409 STALE → quotaExempt 重生成」被旁路成普通生成扣额)。
    private func readAllCore(
        contentHash: String,
        modules: [String],
        language: String,
        targetDate: Date?,
        maxAge: TimeInterval?,
        identity: AIIdentity,
        includeStaleVersions: Bool = false
    ) throws -> V1ChainRestoreOutcome {
        var hits: [String: InterpretationCache] = [:]
        var migrationRegen: Set<String> = []
        // 守卫只对 v1 链模块集生效(清单内全部是 M0-M7 = DeepAnalysis 链式
        // 回填;含同会话部分清单)。合盘/每日/老 module 名不在 ModuleID 集,
        // 不适用——合盘的「paid/free 任一命中」语义里 paid 常年缺席,依赖
        // 切断会误伤 free 行命中。判定用 allSatisfy 而非「first == m0」:
        // 后者会让部分清单静默绕过守卫,#7 的混拼场景在同会话 Tab 重挂下
        // 复现(重启才自愈)。
        let isV1Chain = modules.allSatisfy { ModuleID(rawValue: $0) != nil }
        // 版本缺行模块的传递依赖方集(切断范围;版本未知 = 老后端守卫关闭)
        var cutModules = Set<ModuleID>()
        // 清单外血统上游缺行检查(十七轮 #3,见函数注释):依赖 ∪ {m0} −
        // 清单;行判定与主循环同模式(回填只认当前版本行/跨语言任意版本行)
        if isV1Chain {
            var externalDeps = Set<ModuleID>([.m0])
            for module in modules {
                if let id = ModuleID(rawValue: module) {
                    externalDeps.formUnion(id.dependencies)
                }
            }
            let listed = Set(modules.compactMap(ModuleID.init(rawValue:)))
            externalDeps.subtract(listed)
            for dep in externalDeps
            where identity.promptVersions[dep.rawValue] != nil {
                let hasRow = try latestHit(
                    contentHash: contentHash, module: dep.rawValue,
                    language: language, targetDate: targetDate,
                    maxAge: nil, identity: identity,
                    includeStaleVersions: includeStaleVersions
                ) != nil
                if !hasRow {
                    // 跨语言救援(十八轮外评 #2,仅回填模式):本语言整行
                    // 缺席 + 其它语言有既有行 = 跨语言状态(该章经原文行
                    // 显示/翻译流接管),血统锚点是原文行——parent_hash 由
                    // structure_fingerprint 派生、语言无关。此时切断下游会把
                    // 它们**已有当前语言行**误判血统过期 → 标迁移豁免免费
                    // 重生成(白烧 LLM),而正确行为是照常回填 + 本章交随后的
                    // 跨语言探测。版本迁移场景(本语言有旧版行)不触发救援,
                    // 切断维持。探测模式不救援:下游行要当翻译源,服务端链
                    // 走查按同语言上游行核验,缺上游行的「源」翻译必 409,
                    // 本地切断正是那个前置的镜像。
                    if !includeStaleVersions,
                       try !hasAnyVersionRow(
                           contentHash: contentHash, module: dep.rawValue,
                           language: language, targetDate: targetDate,
                           identity: identity
                       ),
                       try hasRowInOtherLanguage(
                           contentHash: contentHash, module: dep.rawValue,
                           language: language, targetDate: targetDate,
                           identity: identity
                       ) {
                        continue
                    }
                    cutModules.formUnion(dep.transitiveDependents)
                    // 缺行的清单外上游自身若有任意版本行,同样进迁移集
                    // (回填模式):它此后重算非用户过错,否则同会话跨
                    // UTC 零点恢复时其重跑会被计费
                    if !includeStaleVersions,
                       try hasAnyVersionRow(
                           contentHash: contentHash, module: dep.rawValue,
                           language: language, targetDate: targetDate,
                           identity: identity
                       ) {
                        migrationRegen.insert(dep.rawValue)
                    }
                }
            }
        }
        for module in modules {
            if let id = ModuleID(rawValue: module), isV1Chain,
               cutModules.contains(id) {
                // 血统过期跳过:上游自身缺当前版本行,本模块是其传递依赖方,
                // 既有行是旧上游驱动的,不回填;本地有任意版本行 → 记入
                // 版本迁移重生成集(重算非用户过错,调用方豁免本地次数;
                // 跨语言模式不算迁移集,见函数注释)
                if !includeStaleVersions,
                   try hasAnyVersionRow(
                    contentHash: contentHash, module: module,
                    language: language, targetDate: targetDate,
                    identity: identity
                   ) {
                    migrationRegen.insert(module)
                }
                continue
            }
            guard let cache = try latestHit(
                contentHash: contentHash,
                module: module,
                language: language,
                targetDate: targetDate,
                maxAge: maxAge,
                identity: identity,
                includeStaleVersions: includeStaleVersions
            ) else {
                // 版本已知却无当前版本行 = 自身已 bump 本地未跟上(或从未
                // 生成)→ 传递依赖方将被切断;本地有任意版本行 → 迁移重生成
                // (从未生成无行,照常计费)。跨语言救援(十八轮 #2,仅回填
                // 模式,判据与清单外上游分支同款):本语言整行缺席 + 其它
                // 语言有既有行 → 翻译流接管本章,不切断不豁免。
                if isV1Chain, let id = ModuleID(rawValue: module),
                   identity.promptVersions[module] != nil {
                    if !includeStaleVersions,
                       try !hasAnyVersionRow(
                        contentHash: contentHash, module: module,
                        language: language, targetDate: targetDate,
                        identity: identity
                       ),
                       try hasRowInOtherLanguage(
                        contentHash: contentHash, module: module,
                        language: language, targetDate: targetDate,
                        identity: identity
                       ) {
                        continue
                    }
                    cutModules.formUnion(id.transitiveDependents)
                    if !includeStaleVersions,
                       try hasAnyVersionRow(
                        contentHash: contentHash, module: module,
                        language: language, targetDate: targetDate,
                        identity: identity
                       ) {
                        migrationRegen.insert(module)
                    }
                }
                continue
            }
            hits[module] = cache
        }
        return V1ChainRestoreOutcome(
            hits: hits, migrationRegenModules: migrationRegen
        )
    }

    /// 该 (盘, 模块, 语言) 本地是否存在**任意版本**的缓存行(中毒行口径与
    /// latestHit 一致:先清后查)。「版本迁移重生成」判据用——M0 自身 bump
    /// 后旧版行仍在库;m1-m7 自身版本未变但血统过期,当前版本行仍在库;
    /// 从未生成的模块无行(照常计费)。
    private func hasAnyVersionRow(
        contentHash: String,
        module: String,
        language: String,
        targetDate: Date?,
        identity: AIIdentity
    ) throws -> Bool {
        try latestHit(
            contentHash: contentHash,
            module: module,
            language: language,
            targetDate: targetDate,
            maxAge: nil,
            identity: identity,
            includeStaleVersions: true
        ) != nil
    }

    /// 该 (盘, 模块) 在**其它注册语言**下是否有任意版本缓存行(跨语言救援
    /// 判据,十八轮外评 #2):与 `hasAnyVersionRow` 同口径(latestHit +
    /// includeStaleVersions + 中毒行先清后查)。查到的行正是随后跨语言探测
    /// (`readAllCrossLanguage`)会命中的源——两者口径一致,救援放行的章
    /// 探测必有源,翻译流(原文显示 → 自动翻译)接管。
    private func hasRowInOtherLanguage(
        contentHash: String,
        module: String,
        language: String,
        targetDate: Date?,
        identity: AIIdentity
    ) throws -> Bool {
        for other in AppLanguage.allCases.map(\.rawValue)
        where other != language {
            if try latestHit(
                contentHash: contentHash,
                module: module,
                language: other,
                targetDate: targetDate,
                maxAge: nil,
                identity: identity,
                includeStaleVersions: true
            ) != nil {
                return true
            }
        }
        return false
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
            var hits = try readAllCore(
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
            ).hits
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
