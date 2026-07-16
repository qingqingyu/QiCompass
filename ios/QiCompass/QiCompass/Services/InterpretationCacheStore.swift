import Foundation
import SwiftData

/// InterpretationCache SwiftData CRUD 封装(D2 客户端一级缓存)。
///
/// 缓存键:`(contentHash, module, promptVersion, targetDate, provider, model)`。
/// SwiftData 不支持复合 unique index,查询按 Predicate + Swift 侧过滤。
/// bazi_deep/compatibility 的 targetDate == nil;daily_fortune 带 targetDate。
///
/// 错误显式传播:fetch/save 失败直接 throw。
@MainActor
final class InterpretationCacheStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// 只查询当前 provider/model 的最新缓存;legacy nil 身份永不命中。
    func getLatest(
        contentHash: String,
        module: String,
        targetDate: Date?,
        identity: AIIdentity
    ) throws -> InterpretationCache? {
        let desc = FetchDescriptor<InterpretationCache>(
            predicate: #Predicate {
                $0.contentHash == contentHash && $0.module == module
            }
        )
        let results = try context.fetch(desc)
        return results
            .filter { cache in
                let targetMatches: Bool
                if targetDate == nil && cache.targetDate == nil {
                    targetMatches = true
                } else if let targetDate, let cachedDate = cache.targetDate {
                    targetMatches = targetDate == cachedDate
                } else {
                    targetMatches = false
                }
                return targetMatches
                    && cache.provider == identity.provider
                    && cache.model == identity.model
            }
            .max(by: { $0.promptVersion < $1.promptVersion })
    }

    /// upsert:同完整缓存键存在则更新 interpretation/generatedAt,不存在则新建。
    /// targetDate 用 nil-safe 比较(SwiftData #Predicate 对 Optional == Optional 不稳定,改 Swift 侧过滤)。
    func upsert(
        contentHash: String,
        module: String,
        promptVersion: Int,
        targetDate: Date?,
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
            if targetDate == nil && cache.targetDate == nil { return true }
            if let td = targetDate, let cd = cache.targetDate { return td == cd }
            return false
        }

        if let cache = existing {
            cache.interpretation = interpretation
            cache.generatedAt = generatedAt
            cache.provider = normalizedProvider
            cache.model = normalizedModel
        } else {
            let cache = InterpretationCache(
                contentHash: contentHash,
                module: module,
                promptVersion: promptVersion,
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
            "op=interpretationCache.upsert hash=\(contentHash, privacy: .public) module=\(module, privacy: .public) pv=\(promptVersion) provider=\(normalizedProvider, privacy: .public) model=\(normalizedModel, privacy: .public) targetDate=\(targetDate.map { String(describing: $0) } ?? "nil", privacy: .public)"
        )
    }
}
