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
    ///
    /// M3a/c Mock 模式:跳过 StoreKit 2,但仍调后端 `/api/entitlement/redeem`。
    /// **不能跳过 redeem**:后端 M2a `/api/interpret` 步骤 2.5 会查后端 SQLite
    /// entitlement 表(防越狱),iOS 只写本地不同步后端会 403。
    /// M3b 接 StoreKit 时,把"构造 mockTransactionId"换成"拿 StoreKit Transaction.id"。
    func purchase(
        productId: String,
        contentHash: String,
        module: String
    ) async throws -> Entitlement {
        // 规则 2:函数入口日志。购买是付费关键路径,出问题必须可追溯。
        AppLogger.app.info("purchase.start product=\(productId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public)")

        let userLocalId = UserIdentity.userLocalId

        // ───── M3a/c Mock:跳过 StoreKit,但 mock 一个 transactionId ─────
        // M3b 替换:这里换成 Product.purchase() → VerificationResult<Transaction>
        //          拿 transaction.id 作为 transactionId
        let mockTransactionId = "mock_tx_\(UUID().uuidString.prefix(8))"

        AppLogger.app.info(
            "purchase.mock_start product=\(productId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public) tx=\(mockTransactionId, privacy: .public)"
        )

        // ───── 调后端 /api/entitlement/redeem(必须,后端要写 entitlement 表)─────
        // 后端 M2b AppleServerAPIClient 默认挂 MockAppleServerAPI(返 mock info),
        // 所以 redeem 会成功(不真调 Apple)。
        // M3b 接 StoreKit 时,这里改成 StoreKit Transaction.id + Product.purchase 真流程。
        let redeemResp: EntitlementRedeemResponse
        do {
            redeemResp = try await apiClient.redeem(
                request: EntitlementRedeemRequest(
                    transactionId: mockTransactionId,
                    productId: productId,
                    contentHash: contentHash,
                    module: module,
                    userLocalId: userLocalId
                )
            )
        } catch {
            AppLogger.app.error(
                "purchase.redeem_failed error=\(String(describing: error), privacy: .public)"
            )
            throw PurchaseError.backendRedeemFailed(underlying: error)
        }

        // ───── 写本地 SwiftData(镜像后端 entitlement 表)─────
        do {
            try await entitlementStore.upsert(
                transactionId: redeemResp.transactionId,
                productId: productId,
                contentHash: contentHash,
                module: module,
                userLocalId: userLocalId,
                purchasedAt: redeemResp.purchasedAt,
                originalPurchaseDate: redeemResp.originalPurchaseDate
            )
        } catch {
            AppLogger.app.error(
                "purchase.local_write_failed error=\(String(describing: error), privacy: .public)"
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
    case backendRedeemFailed(underlying: Error)
    // M3b 接手时再加 StoreKit 相关 case:
    // case storeKitPurchaseFailed(underlying: Error)
    // case appleVerificationFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .entitlementStoreFailed(let underlying):
            return "授权数据写入失败:\(underlying.localizedDescription)"
        case .backendRedeemFailed(let underlying):
            return "后端授权同步失败:\(underlying.localizedDescription)"
        }
    }
}
