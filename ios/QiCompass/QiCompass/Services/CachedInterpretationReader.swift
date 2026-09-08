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
    ///   - module: `"bazi_deep"` / `"compatibility"` / `"daily_fortune"`
    ///   - targetDate: 每日运势传 date,其他传 nil(默认)
    ///   - maxAge: 新鲜度上限,`nil` = 不过期(`DeepAnalysis` 瞬时显示用);其他传 `24 * 3600`
    /// - Returns: 命中的完整 `InterpretationCache`;miss / 过期 / 身份不匹配(cacheStore 内 filter)都返回 nil
    /// - Throws: identity 解析失败或 SwiftData 读失败向上抛
    ///
    /// i18n:language 由 `AppLanguage.current` 自动注入(i18n 决策 10 方案 3:
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
            language: AppLanguage.current,
            identity: identity
        ) else {
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
    ///   - language:**必传**目标语言代码。深度解析 v1 章固定 "zh"(写入口径:
    ///     `runV1Module` upsert 未传 language 恒落 "zh",i18n Slice 2 债;
    ///     读按 AppLanguage.current 查会让 en 用户每次冷启动必 miss → 自动续跑
    ///     反复烧全链 LLM。Slice 2 补 en deep 模板时读写一起迁移)
    /// - Returns:module 名 → 命中的 `InterpretationCache`
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
            if let maxAge, cache.generatedAt.addingTimeInterval(maxAge) <= .now {
                continue
            }
            hits[module] = cache
        }
        return hits
    }
}
