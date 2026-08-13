import Foundation

/// 客户端读 AI 缓存的唯一入口 module。
///
/// 集中执行 ADR-0009 强约束:读 AI 缓存前必须 health 解析身份,只接受 provider/model 完全匹配的行,
/// nil 旧行永不命中。把这条约束的执行点从 N=5 个调用点收敛到 1 处:
/// - `DeepAnalysisOrchestrator.localCachedInterpretation`(瞬时显示,不过期)
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
}
