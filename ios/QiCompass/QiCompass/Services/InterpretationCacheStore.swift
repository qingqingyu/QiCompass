import Foundation
import SwiftData

/// InterpretationCache SwiftData CRUD 封装(D2 客户端一级缓存)。
///
/// 缓存键四元组:`(contentHash, module, promptVersion, targetDate)`。
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

    /// 查询 bazi_deep/compatibility 的最新缓存。
    /// 取 targetDate == nil 且 promptVersion 最大的一条(方案 §4.5)。
    func getLatest(contentHash: String, module: String) throws -> InterpretationCache? {
        let desc = FetchDescriptor<InterpretationCache>(
            predicate: #Predicate {
                $0.contentHash == contentHash && $0.module == module
            }
        )
        let results = try context.fetch(desc)
        return results
            .filter { $0.targetDate == nil }
            .max(by: { $0.promptVersion < $1.promptVersion })
    }

    /// upsert:同四元组存在则更新 interpretation/generatedAt,不存在则新建。
    /// targetDate 用 nil-safe 比较(SwiftData #Predicate 对 Optional == Optional 不稳定,改 Swift 侧过滤)。
    func upsert(
        contentHash: String,
        module: String,
        promptVersion: Int,
        targetDate: Date?,
        interpretation: String,
        generatedAt: Date
    ) throws {
        let desc = FetchDescriptor<InterpretationCache>(
            predicate: #Predicate {
                $0.contentHash == contentHash
                && $0.module == module
                && $0.promptVersion == promptVersion
            }
        )
        let candidates = try context.fetch(desc)
        let existing = candidates.first { cache in
            if targetDate == nil && cache.targetDate == nil { return true }
            if let td = targetDate, let cd = cache.targetDate { return td == cd }
            return false
        }

        if let cache = existing {
            cache.interpretation = interpretation
            cache.generatedAt = generatedAt
        } else {
            let cache = InterpretationCache(
                contentHash: contentHash,
                module: module,
                promptVersion: promptVersion,
                targetDate: targetDate,
                interpretation: interpretation,
                generatedAt: generatedAt
            )
            context.insert(cache)
        }
        try context.save()
        AppLogger.persistence.info(
            "op=interpretationCache.upsert hash=\(contentHash, privacy: .public) module=\(module, privacy: .public) pv=\(promptVersion) targetDate=\(targetDate.map { String(describing: $0) } ?? "nil", privacy: .public)"
        )
    }
}
