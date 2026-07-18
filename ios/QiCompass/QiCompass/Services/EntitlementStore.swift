import Foundation
import SwiftData

/// Entitlement SwiftData 查询 wrapper(M3a)。
///
/// 对齐后端 `EntitlementStore` (`backend/app/entitlement/store.py`)语义:
/// - `getActive(contentHash:module:userLocalId:)`:查命盘维度的 active 授权
/// - `upsert(...)`:写入(M3a/c Mock 用 + M3b 真购买流程也用)
/// - `deactivate(transactionId:)`:M3a/c 不实际调用(M3b 接 Server Notifications 时用)
///
/// 所有方法 `@MainActor`(SwiftData ModelContext 默认 MainActor 隔离)。
/// 错误显式传播:SwiftData 抛出 → 调用方 catch → 转 UserFacingError 给 UI。
@MainActor
final class EntitlementStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// 查命盘维度的 active entitlement(用于 /api/interpret 客户端拦截 + UI 锁标判断)。
    ///
    /// 一个 (content_hash, module, user_local_id) 可能有多笔(用户改生辰重购),
    /// 任意一笔 active 即视为有权。取最近一笔(purchasedAt DESC LIMIT 1)。
    ///
    /// - Returns: 命中 active → Entitlement;未命中 → nil
    func getActive(
        contentHash: String,
        module: String,
        userLocalId: String
    ) -> Entitlement? {
        var descriptor = FetchDescriptor<Entitlement>(
            predicate: #Predicate {
                $0.contentHash == contentHash
                    && $0.module == module
                    && $0.userLocalId == userLocalId
                    && $0.isActive == true
            },
            sortBy: [SortDescriptor(\.purchasedAt, order: .reverse)]
        )
        // LIMIT 1:fetch 后取 first
        descriptor.fetchLimit = 1
        do {
            let results = try modelContext.fetch(descriptor)
            return results.first
        } catch {
            AppLogger.persistence.error(
                "op=entitlementStore.getActive failed error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// 写入 entitlement(M3a/c Mock + M3b 真购买都用此入口)。
    ///
    /// 幂等:同 transactionId 已存在则覆盖(对齐后端 INSERT OR IGNORE 语义;
    /// SwiftData 没有 OR IGNORE,用 fetch + 更新或新建)。
    ///
    /// - Throws: SwiftData 写入失败(不吞,向上抛)
    func upsert(
        transactionId: String,
        productId: String,
        contentHash: String,
        module: String,
        userLocalId: String,
        purchasedAt: Date,
        originalPurchaseDate: Date
    ) throws {
        // 先查同 transactionId 是否已存在(幂等)
        let existing = try _findByTransactionId(transactionId)
        if let existing = existing {
            // 已存在 → 更新 isActive = true(可能之前被 deactivate 过,重新激活)
            existing.productId = productId
            existing.contentHash = contentHash
            existing.module = module
            existing.userLocalId = userLocalId
            existing.purchasedAt = purchasedAt
            existing.originalPurchaseDate = originalPurchaseDate
            existing.isActive = true
        } else {
            // 新建
            let entitlement = Entitlement(
                transactionId: transactionId,
                productId: productId,
                contentHash: contentHash,
                module: module,
                userLocalId: userLocalId,
                purchasedAt: purchasedAt,
                originalPurchaseDate: originalPurchaseDate,
                isActive: true
            )
            modelContext.insert(entitlement)
        }
        try modelContext.save()
    }

    /// 标记 entitlement 为 inactive(退款/撤销)。
    ///
    /// M3a/c 阶段不实际调用(后端 M2c webhook 处理退款)。
    /// M3b 接 Apple Server Notifications 时可能用(若 iOS 端要主动同步)。
    ///
    /// - Returns: True = 实际更新了行;False = tx 不存在或已 inactive(幂等)
    @discardableResult
    func deactivate(transactionId: String) -> Bool {
        do {
            guard let entitlement = try _findByTransactionId(transactionId) else {
                return false
            }
            guard entitlement.isActive else {
                return false  // 已 inactive,幂等
            }
            entitlement.isActive = false
            try modelContext.save()
            return true
        } catch {
            AppLogger.persistence.error(
                "op=entitlementStore.deactivate failed tx=\(transactionId, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// 按 transactionId 查单条(内部 helper)。
    private func _findByTransactionId(_ transactionId: String) throws -> Entitlement? {
        var descriptor = FetchDescriptor<Entitlement>(
            predicate: #Predicate { $0.transactionId == transactionId }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}
