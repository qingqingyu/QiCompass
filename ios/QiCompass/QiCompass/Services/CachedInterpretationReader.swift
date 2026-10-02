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
        var hits: [String: InterpretationCache] = [:]
        for module in modules {
            guard let cache = try cacheStore.getLatest(
                contentHash: contentHash,
                module: module,
                targetDate: targetDate,
                language: language,
                identity: identity
            ) else {
                continue
            }
            if try purgeIfPoisoned(cache) {
                continue
            }
            if let maxAge, cache.generatedAt.addingTimeInterval(maxAge) <= .now {
                continue
            }
            hits[module] = cache
        }
        return hits
    }

    // MARK: - 跨语言查找(D10.5,S7)

    /// 跨语言探测:按「当前语言之外的全部注册语言」查缓存,取**命中模块数最多**
    /// 的语言(并列取 `AppLanguage.allCases` 序,确定性)。
    ///
    /// 用途:切语言后当前语言缓存 miss 时,找到其它语言的既有解读 → 先显示
    /// 原文,L3/F1(修订 D10.5)起打开即自动翻译,失败才出提示条重试。
    /// 中毒行同 `readAll` 口径删除当 miss;过期语义同 `maxAge` 参数。
    ///
    /// - Returns:命中语言 + module 名 → 缓存行;任何语言都无命中 → nil
    /// - Throws:identity 解析失败或 SwiftData 读失败向上抛
    func readAllCrossLanguage(
        contentHash: String,
        modules: [String],
        targetDate: Date? = nil,
        maxAge: TimeInterval? = nil
    ) async throws -> (language: String, hits: [String: InterpretationCache])? {
        let otherLanguages = AppLanguage.allCases
            .map(\.rawValue)
            .filter { $0 != AppLanguage.currentWire }
        var best: (language: String, hits: [String: InterpretationCache])?
        for language in otherLanguages {
            let hits = try await readAll(
                contentHash: contentHash,
                modules: modules,
                language: language,
                targetDate: targetDate,
                maxAge: maxAge
            )
            if hits.isEmpty { continue }
            if best == nil || hits.count > best!.hits.count {
                best = (language, hits)
            }
        }
        return best
    }

    /// 跨语言探测(模块优先版,2026-10-02 修复):按 `modules` 顺序在
    /// 「其它语言」里逐模块探测,先命中先返回。
    ///
    /// 与逐模块调 `readAllCrossLanguage` 的结果逐例相等(单模块探测下
    /// 「命中模块数最多」退化为首个命中语言,语言序同为 `allCases` 序),
    /// 但 **identity 只 resolve 一次**:合盘 cross-language 查询若逐模块
    /// 调 `readAllCrossLanguage`,每次内部又逐语言调 `readAll`——每次
    /// resolve 都是一次 `/api/health` 往返,一次 detail 打开最多 5 次;
    /// 收敛到 1 次后行为不变(同批共享 resolve 不违反 ADR-0009,见
    /// `readAll` 注释)。
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
            for language in otherLanguages {
                guard let cache = try cacheStore.getLatest(
                    contentHash: contentHash,
                    module: module,
                    targetDate: targetDate,
                    language: language,
                    identity: identity
                ) else { continue }
                if try purgeIfPoisoned(cache) { continue }
                if let maxAge, cache.generatedAt.addingTimeInterval(maxAge) <= .now {
                    continue
                }
                return (module, language, cache)
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
