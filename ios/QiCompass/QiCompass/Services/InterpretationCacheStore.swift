import Foundation
import SwiftData

/// InterpretationCache SwiftData CRUD 封装(D2 客户端一级缓存 + i18n 第 8 维度 language)。
///
/// 缓存键:`(contentHash, module, promptVersion, language, targetDate, provider, model)`。
/// SwiftData 不支持复合 unique index,查询按 Predicate + Swift 侧过滤。
/// bazi_deep/compatibility 的 targetDate == nil;daily_fortune 带 targetDate。
///
/// i18n language 维度:
/// - 老缓存 `language == nil` 视为 "zh"(对齐 Q13 决策:v1 之前所有缓存都是中文)
/// - 新缓存必填 language;查询时 cache.language ?? "zh" 与目标 language 比较
///
/// 错误显式传播:fetch/save 失败直接 throw。
@MainActor
final class InterpretationCacheStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// 只查询当前 provider/model/language 的最新缓存;legacy nil 身份永不命中。
    /// language 参数:目标语言代码("zh" / "en")。nil 视为 "zh"(向后兼容老调用,
    /// 后续 Orchestrator/Reader 应传入 AppLanguage.current)。
    func getLatest(
        contentHash: String,
        module: String,
        targetDate: Date?,
        language: String? = nil,
        identity: AIIdentity
    ) throws -> InterpretationCache? {
        let desc = FetchDescriptor<InterpretationCache>(
            predicate: #Predicate {
                $0.contentHash == contentHash && $0.module == module
            }
        )
        let results = try context.fetch(desc)
        let normalizedLanguage = language ?? "zh"
        let hit = results
            .filter { cache in
                let targetMatches: Bool
                if targetDate == nil && cache.targetDate == nil {
                    targetMatches = true
                } else if let targetDate, let cachedDate = cache.targetDate {
                    targetMatches = targetDate == cachedDate
                } else {
                    targetMatches = false
                }
                // language 维度:nil 老缓存视为 "zh"(i18n Q13 决策)
                let cacheLanguage = cache.language ?? "zh"
                let languageMatches = cacheLanguage == normalizedLanguage
                return targetMatches
                    && languageMatches
                    && cache.provider == identity.provider
                    && cache.model == identity.model
            }
            .max(by: { $0.promptVersion < $1.promptVersion })
        // 规则 2:hit/miss 业务分支日志
        AppLogger.persistence.info("op=interpretationCache.getLatest hash=\(contentHash, privacy: .public) module=\(module, privacy: .public) language=\(normalizedLanguage, privacy: .public) hit=\(hit != nil, privacy: .public) pv=\(hit?.promptVersion ?? -1)")
        return hit
    }

    /// upsert:同完整缓存键存在则更新 interpretation/generatedAt,不存在则新建。
    /// targetDate 用 nil-safe 比较(SwiftData #Predicate 对 Optional == Optional 不稳定,改 Swift 侧过滤)。
    /// language 参数:目标语言代码("zh" / "en")。nil 视为 "zh"(向后兼容老调用,
    /// 后续 Orchestrator 应传入 response.language 或 AppLanguage.current)。
    func upsert(
        contentHash: String,
        module: String,
        promptVersion: Int,
        targetDate: Date?,
        language: String? = nil,
        provider: String,
        model: String,
        interpretation: String,
        generatedAt: Date
    ) throws {
        let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["anthropic", "openai"].contains(normalizedProvider),
              !normalizedModel.isEmpty else {
            throw AIIdentityError.invalidHealthIdentity(
                provider: provider,
                model: model
            )
        }
        let normalizedLanguage = language ?? "zh"
        let desc = FetchDescriptor<InterpretationCache>(
            predicate: #Predicate {
                $0.contentHash == contentHash
                && $0.module == module
                && $0.promptVersion == promptVersion
            }
        )
        let candidates = try context.fetch(desc)
        let existing = candidates.first { cache in
            guard cache.provider == normalizedProvider,
                  cache.model == normalizedModel else { return false }
            // language 维度:nil 老缓存视为 "zh"
            let cacheLanguage = cache.language ?? "zh"
            guard cacheLanguage == normalizedLanguage else { return false }
            if targetDate == nil && cache.targetDate == nil { return true }
            if let td = targetDate, let cd = cache.targetDate { return td == cd }
            return false
        }

        if let cache = existing {
            cache.interpretation = interpretation
            cache.generatedAt = generatedAt
            cache.provider = normalizedProvider
            cache.model = normalizedModel
            cache.language = normalizedLanguage
        } else {
            let cache = InterpretationCache(
                contentHash: contentHash,
                module: module,
                promptVersion: promptVersion,
                language: normalizedLanguage,
                targetDate: targetDate,
                provider: normalizedProvider,
                model: normalizedModel,
                interpretation: interpretation,
                generatedAt: generatedAt
            )
            context.insert(cache)
        }
        try context.save()
        AppLogger.persistence.info(
            "op=interpretationCache.upsert hash=\(contentHash, privacy: .public) module=\(module, privacy: .public) pv=\(promptVersion) language=\(normalizedLanguage, privacy: .public) provider=\(normalizedProvider, privacy: .public) model=\(normalizedModel, privacy: .public) targetDate=\(targetDate.map { String(describing: $0) } ?? "nil", privacy: .public)"
        )
    }
}
