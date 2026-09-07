import Foundation
import SwiftData

/// Entitlement SwiftData 查询 wrapper(M3a + Slice 3 双轨查询)。
///
/// 对齐后端 `EntitlementStore` (`backend/app/entitlement/store.py`)语义:
/// - `getActive(contentHash:module:userLocalId:userId:)`:双轨查命盘维度 active 授权
///   (userId 优先,userLocalId 兜底)
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
    /// **双轨策略**(Slice 3,对齐后端 store.get_active):
    /// - 已登录(userId != nil)→ 优先按 userId 查(跨设备 / 重装 / 退登回登场景)
    /// - userId 未命中或未传 → 兜底按 userLocalId 查(老数据 / 未登录购买场景)
    /// - 一个 (content_hash, module, user_*) 可能有多笔(用户改生辰重购),
    ///   任意一笔 active 即视为有权。取最近一笔(purchasedAt DESC LIMIT 1)。
    ///
    /// - Returns: 命中 active → Entitlement;未命中 → nil
    func getActive(
        contentHash: String,
        module: String,
        userLocalId: String,
        userId: String? = nil
    ) -> Entitlement? {
        AppLogger.persistence.info("op=entitlementStore.getActive.start content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public) has_user_id=\(userId != nil, privacy: .public)")

        // 双轨优先:userId(登录用户)
        if let userId {
            var descriptor = FetchDescriptor<Entitlement>(
                predicate: #Predicate {
                    $0.contentHash == contentHash
                        && $0.module == module
                        && $0.userId == userId
                        && $0.isActive == true
                },
                sortBy: [SortDescriptor(\.purchasedAt, order: .reverse)]
            )
            descriptor.fetchLimit = 1
            do {
                if let hit = try modelContext.fetch(descriptor).first {
                    AppLogger.persistence.info("op=entitlementStore.getActive.ok hit=true source=userId tx=\(hit.transactionId, privacy: .public)")
                    return hit
                }
            } catch {
                AppLogger.persistence.error(
                    "op=entitlementStore.getActive userId_query_failed error=\(String(describing: error), privacy: .public)"
                )
                // 不 return,继续走 userLocalId 兜底(降级,避免完全查不到)
            }
        }

        // 兜底:userLocalId(老数据 / 未登录购买)
        var descriptor = FetchDescriptor<Entitlement>(
            predicate: #Predicate {
                $0.contentHash == contentHash
                    && $0.module == module
                    && $0.userLocalId == userLocalId
                    && $0.isActive == true
            },
            sortBy: [SortDescriptor(\.purchasedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        do {
            let hit = try modelContext.fetch(descriptor).first
            AppLogger.persistence.info("op=entitlementStore.getActive.ok hit=\(hit != nil, privacy: .public) source=userLocalId tx=\(hit?.transactionId ?? "nil", privacy: .public)")
            return hit
        } catch {
            AppLogger.persistence.error(
                "op=entitlementStore.getActive userLocalId_query_failed error=\(String(describing: error), privacy: .public)"
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
        userId: String? = nil,
        purchasedAt: Date,
        originalPurchaseDate: Date
    ) throws {
        // 规则 2:函数入口日志(付费授权写入是付费链路关键路径)
        AppLogger.persistence.info("op=entitlementStore.upsert.start tx=\(transactionId, privacy: .public) product=\(productId, privacy: .public) module=\(module, privacy: .public) has_user_id=\(userId != nil, privacy: .public)")
        // 先查同 transactionId 是否已存在(幂等)
        let existing = try _findByTransactionId(transactionId)
        if let existing = existing {
            // 已存在 → 更新 isActive = true(可能之前被 deactivate 过,重新激活)
            existing.productId = productId
            existing.contentHash = contentHash
            existing.module = module
            existing.userLocalId = userLocalId
            existing.userId = userId ?? existing.userId  // 不覆盖已有 userId(避免 backfill 后被清空)
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
                userId: userId,
                purchasedAt: purchasedAt,
                originalPurchaseDate: originalPurchaseDate,
                isActive: true
            )
            modelContext.insert(entitlement)
        }
        try modelContext.save()
        AppLogger.persistence.info("op=entitlementStore.upsert.ok tx=\(transactionId, privacy: .public) is_new=\(existing == nil, privacy: .public)")
    }

    /// 标记 entitlement 为 inactive(退款/撤销)。
    ///
    /// M3a/c 阶段不实际调用(后端 M2c webhook 处理退款)。
    /// M3b 接 Apple Server Notifications 时可能用(若 iOS 端要主动同步)。
    ///
    /// - Returns: True = 实际更新了行;False = tx 不存在或已 inactive(幂等)
    @discardableResult
    func deactivate(transactionId: String) -> Bool {
        // 规则 2:函数入口日志(退款/撤销路径)
        AppLogger.persistence.info("op=entitlementStore.deactivate.start tx=\(transactionId, privacy: .public)")
        do {
            guard let entitlement = try _findByTransactionId(transactionId) else {
                AppLogger.persistence.info("op=entitlementStore.deactivate.skip tx_not_found")
                return false
            }
            guard entitlement.isActive else {
                AppLogger.persistence.info("op=entitlementStore.deactivate.skip already_inactive")
                return false  // 已 inactive,幂等
            }
            entitlement.isActive = false
            try modelContext.save()
            AppLogger.persistence.info("op=entitlementStore.deactivate.ok tx=\(transactionId, privacy: .public)")
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

    // MARK: - Slice 6:登录后批量同步(跨设备 / 重装 / 退登回登)

    /// 从后端批量拉当前 user 的全部 entitlement 写入本地 SwiftData。
    ///
    /// 触发时机:`AppEnvironment.accountManager.onSignedIn` 回调里调,登录成功后立即同步,
    /// 让新设备 / 重装 / 退登回登场景的购买记录能跟随 Apple 账号回到本地。
    ///
    /// 合并策略:
    /// - 远端 active → 本地 upsert(同 tx 覆盖;新 tx 插入)
    /// - 远端 inactive → 本地若存在同 tx 且 active,deactivate(同步退款状态)
    /// - 本地有但远端无 → 不动(可能刚买未 sync 上,稍后 push 或下次 sync 再校对)
    ///
    /// **错误处理**:失败不阻断 onSignedIn 链路(对齐 SyncManager 现有模式),记日志,
    /// 下次 App 启动 onAppear 时 syncManager.pull() 再次触发本方法重试。
    func synchronizeFromBackend(apiClient: APIClient) async {
        AppLogger.app.info("entitlementStore.syncFromBackend.start")
        let remoteEntitlements: [EntitlementListItemDTO]
        do {
            let resp = try await apiClient.entitlementList()
            remoteEntitlements = resp.entitlements
        } catch {
            AppLogger.app.error(
                "entitlementStore.syncFromBackend.fetch_failed error=\(String(describing: error), privacy: .public)"
            )
            return
        }

        var upsertedCount = 0
        var deactivatedCount = 0
        for item in remoteEntitlements {
            // upsert(active + inactive 都写,本地需要知道退款状态)
            do {
                try upsert(
                    transactionId: item.transactionId,
                    productId: item.productId,
                    contentHash: item.contentHash,
                    module: item.module,
                    userLocalId: item.userLocalId,
                    userId: item.userId,
                    purchasedAt: item.purchasedAt,
                    originalPurchaseDate: item.originalPurchaseDate
                )
                upsertedCount += 1
            } catch {
                AppLogger.persistence.error(
                    "entitlementStore.syncFromBackend.upsert_failed tx=\(item.transactionId, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                continue
            }

            // upsert 会强制 isActive=true,但远端可能 inactive → 手动 deactivate 校准
            if !item.isActive {
                if deactivate(transactionId: item.transactionId) {
                    deactivatedCount += 1
                }
            }
        }

        // 最终 save 仅 defense-in-depth(upsert/deactivate 内部已各 save 一次)。
        // 正常路径下无未提交变更,save 是 no-op;异常路径下兜底持久化。
        do {
            try modelContext.save()
        } catch {
            AppLogger.persistence.error(
                "entitlementStore.syncFromBackend.final_save_failed error=\(String(describing: error), privacy: .public)"
            )
        }

        let activeRemote = remoteEntitlements.filter(\.isActive).count
        AppLogger.app.info(
            "entitlementStore.syncFromBackend.ok remote_total=\(remoteEntitlements.count, privacy: .public) remote_active=\(activeRemote, privacy: .public) upserted=\(upsertedCount, privacy: .public) deactivated=\(deactivatedCount, privacy: .public)"
        )
    }
}
