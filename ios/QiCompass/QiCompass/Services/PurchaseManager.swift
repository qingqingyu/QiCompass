import Foundation

/// PurchaseManager(购买流程入口)。
///
/// **M3a/c 阶段(Mock 模式)**:
/// 不调 StoreKit,直接写一条 Mock Entitlement 进 SwiftData。
/// 让 iOS 端能跑通"购买 → entitlement 写入 → _paid 解锁"完整链路。
///
/// **M3b 接手时**(用户配好 .storekit Configuration File):
/// 替换 `purchase(...)` 内部为真 StoreKit 2 流程:
/// 1. `Product.products(for: [productId])` 拿 Product
/// 2. `product.purchase()` → `VerificationResult<Transaction>`
/// 3. 调 `apiClient.redeem(request:)` 同步到后端
/// 4. 后端返 `EntitlementRedeemResponse` → 写 SwiftData
/// 5. `Transaction.finish()`
///
/// 错误显式传播(对齐 CLAUDE.md 全局约束):不静默吞,失败抛 PurchaseError。
@MainActor
final class PurchaseManager {
    private let entitlementStore: EntitlementStore
    private let apiClient: APIClient

    init(entitlementStore: EntitlementStore, apiClient: APIClient) {
        self.entitlementStore = entitlementStore
        self.apiClient = apiClient
    }

    /// 发起购买。
    ///
    /// - Parameters:
    ///   - productId: Apple SKU(如 `com.qicompass.deep_analysis.single`)
    ///   - contentHash: 命盘 hash(深度解析)或 compatibility_hash(合盘)
    ///   - module: 基础名(`bazi_deep` / `compatibility`),不含 _free/_paid
    /// - Returns: 写入后的 Entitlement(M3a/c Mock 直接查回)
    /// - Throws: PurchaseError
    func purchase(
        productId: String,
        contentHash: String,
        module: String
    ) async throws -> Entitlement {
        // 规则 2:函数入口日志。购买是付费关键路径,出问题必须可追溯。
        AppLogger.app.info("purchase.start product=\(productId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public)")

        let userLocalId = UserIdentity.userLocalId

        // ───── M3a/c Mock 模式 ─────
        // 不调 StoreKit,直接构造 mock transactionId + 写 SwiftData
        // M3b 替换:把这块换成 StoreKit 2 真流程(见类注释)
        let mockTransactionId = "mock_tx_\(UUID().uuidString.prefix(8))"
        let now = Date()

        AppLogger.app.info(
            "purchase.mock_write product=\(productId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public) tx=\(mockTransactionId, privacy: .public)"
        )

        // M3a/c:跳过 apiClient.redeem(后端 Mock 模式)
        // M3b 改为:
        //   let resp = try await apiClient.redeem(request: EntitlementRedeemRequest(
        //       transactionId: <StoreKit transactionId>, productId: productId,
        //       contentHash: contentHash, module: module, userLocalId: userLocalId))
        //   try await entitlementStore.upsert(
        //       transactionId: resp.transactionId, ...,
        //       purchasedAt: resp.purchasedAt, originalPurchaseDate: resp.originalPurchaseDate)
        //   await transaction.finish()  // StoreKit Transaction
        do {
            try await entitlementStore.upsert(
                transactionId: mockTransactionId,
                productId: productId,
                contentHash: contentHash,
                module: module,
                userLocalId: userLocalId,
                purchasedAt: now,
                originalPurchaseDate: now
            )
        } catch {
            AppLogger.app.error(
                "purchase.mock_write_failed error=\(String(describing: error), privacy: .public)"
            )
            throw PurchaseError.entitlementStoreFailed(underlying: error)
        }

        // 查回刚写的
        guard let entitlement = entitlementStore.getActive(
            contentHash: contentHash,
            module: module,
            userLocalId: userLocalId
        ) else {
            // 规则 1:抛错前打 error 日志(原有 fatalError 没打 structured log)
            AppLogger.app.error(
                "purchase.get_active_returned_nil tx=\(mockTransactionId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public)"
            )
            throw PurchaseError.entitlementStoreFailed(
                underlying: NSError(
                    domain: "PurchaseManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "upsert 成功但 getActive 返回 nil"]
                )
            )
        }
        AppLogger.app.info("purchase.ok tx=\(mockTransactionId, privacy: .public) entitlement_transactionId=\(entitlement.transactionId, privacy: .public) isActive=\(entitlement.isActive, privacy: .public)")
        return entitlement
    }
}

// MARK: - PurchaseError

enum PurchaseError: LocalizedError {
    case entitlementStoreFailed(underlying: Error)
    // M3b 接手时再加 StoreKit 相关 case:
    // case storeKitPurchaseFailed(underlying: Error)
    // case appleVerificationFailed(message: String)
    // case backendRedeemFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .entitlementStoreFailed(let underlying):
            return "授权数据写入失败:\(underlying.localizedDescription)"
        }
    }
}
