import Foundation
import StoreKit

/// PurchaseManager(购买流程入口)。
///
/// **两条路径共存**:
/// - `purchaseMockPath`:Mock 模式(`apiClient is MockAPIClient`),用 `mock_tx_<UUID>` 假 transactionId 走完后端 redeem 链路。dev/test 用,无需 Apple 沙盒。
/// - `purchaseStoreKitPath`:真路径,走 `Product.purchase() → VerificationResult<Transaction>`,需要 StoreKit Configuration 文件本地测试 或 ASC 真商品 + Apple 沙盒(M6 TestFlight)。
///
/// **防漏单**(M3b 关键):
/// `purchaseStoreKitPath` 中后端 redeem 失败时**不调 `transaction.finish()`**,保留 transaction,
/// 让下次启动的 `Transaction.updates` listener 自动续接 redeem。避免"用户付了钱但后端没收到"的资损场景。
///
/// 错误显式传播(对齐 CLAUDE.md 全局约束):不静默吞,失败抛 PurchaseError。
/// `.userCancelled` 是显式 case + `isSilent = true` 标记,Apple HIG 建议 IAP 取消不要打扰用户。
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
    /// - Returns: 写入后的 Entitlement
    /// - Throws: PurchaseError(用户取消静默 / 网络失败 / 验签失败 / 后端 redeem 失败等)
    func purchase(
        productId: String,
        contentHash: String,
        module: String
    ) async throws -> Entitlement {
        // 规则 2:函数入口日志。购买是付费关键路径,出问题必须可追溯。
        AppLogger.app.info("purchase.start product=\(productId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public)")

        // Mock 模式检测:沿用 useMockAPIClient 单一切换点(不引入 useMockStoreKit 独立标志)。
        // MockAPIClient = dev/test 路径;真后端路径走 StoreKit 真流程,StoreKit Configuration 缺失时 fail-fast。
        if apiClient is MockAPIClient {
            return try await purchaseMockPath(productId: productId, contentHash: contentHash, module: module)
        }
        return try await purchaseStoreKitPath(productId: productId, contentHash: contentHash, module: module)
    }

    // MARK: - Mock 路径(dev/test,不调 StoreKit)

    /// Mock 路径:用假 transactionId 走完后端 redeem 链路。
    /// 后端 M2b `apple_client.py` 在 env 缺失时挂 `MockAppleServerAPI`(返 mock info),redeem 会成功。
    private func purchaseMockPath(
        productId: String,
        contentHash: String,
        module: String
    ) async throws -> Entitlement {
        let userLocalId = UserIdentity.userLocalId
        let mockTransactionId = "mock_tx_\(UUID().uuidString.prefix(8))"

        AppLogger.app.info(
            "purchase.mock_start product=\(productId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public) tx=\(mockTransactionId, privacy: .public)"
        )

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
                "purchase.mock_redeem_failed error=\(String(describing: error), privacy: .public)"
            )
            throw PurchaseError.backendRedeemFailed(underlying: error)
        }

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
                "purchase.mock_local_write_failed error=\(String(describing: error), privacy: .public)"
            )
            throw PurchaseError.entitlementStoreFailed(underlying: error)
        }

        guard let entitlement = entitlementStore.getActive(
            contentHash: contentHash,
            module: module,
            userLocalId: userLocalId
        ) else {
            AppLogger.app.error(
                "purchase.mock_get_active_returned_nil tx=\(mockTransactionId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public)"
            )
            throw PurchaseError.entitlementStoreFailed(
                underlying: NSError(
                    domain: "PurchaseManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "upsert 成功但 getActive 返回 nil"]
                )
            )
        }
        AppLogger.app.info("purchase.mock_ok tx=\(mockTransactionId, privacy: .public) entitlement_transactionId=\(entitlement.transactionId, privacy: .public) isActive=\(entitlement.isActive, privacy: .public)")
        return entitlement
    }

    // MARK: - StoreKit 真路径(M3b)

    /// StoreKit 2 真购买流程。
    ///
    /// 流程:`Product.products(for:) → product.purchase() → VerificationResult<Transaction>
    /// → apiClient.redeem(transaction.id) → entitlementStore.upsert → transaction.finish()`。
    ///
    /// **防漏单顺序**:redeem 失败时**不调 `transaction.finish()`**,保留 transaction,
    /// 让 `Transaction.updates` listener 在下次启动续接 redeem(避免用户付钱但后端漏写)。
    ///
    /// **appAccountToken 不传**:v1 无账号系统,传 UUID(user_local_id) 给 Apple 反而给 v2 留映射债;
    /// 后端 user_local_id 字段已做用户绑定。v2 加账号时用 transactionId + originalPurchaseDate 反查迁移。
    private func purchaseStoreKitPath(
        productId: String,
        contentHash: String,
        module: String
    ) async throws -> Entitlement {
        let userLocalId = UserIdentity.userLocalId
        AppLogger.app.info("purchase.storekit.start product=\(productId, privacy: .public)")

        // 1. 取 Product(ASC 或本地 .storekit Configuration 提供)
        let products: [Product]
        do {
            products = try await Product.products(for: [productId])
        } catch {
            AppLogger.app.error("purchase.storekit.fetch_failed product=\(productId, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw PurchaseError.networkFailed(underlying: error)
        }
        guard let product = products.first else {
            AppLogger.app.error("purchase.storekit.product_not_found id=\(productId, privacy: .public)")
            throw PurchaseError.productNotFound(productId: productId)
        }

        // 2. 调起 purchase(不传 appAccountToken,见方法 doc)
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            AppLogger.app.error("purchase.storekit.system_error product=\(productId, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw PurchaseError.networkFailed(underlying: error)
        }

        // 3. 处理 PurchaseResult 三种 case
        let transaction: Transaction
        switch result {
        case .success(let verification):
            // VerificationResult:StoreKit 2 本地验签 JWS
            switch verification {
            case .verified(let tx):
                transaction = tx
            case .unverified(_, let error):
                AppLogger.app.error("purchase.storekit.verification_failed error=\(String(describing: error), privacy: .public)")
                throw PurchaseError.verificationFailed(message: "StoreKit 验签失败:\(error.localizedDescription)")
            }
        case .userCancelled:
            AppLogger.app.info("purchase.storekit.user_cancelled product=\(productId, privacy: .public)")
            throw PurchaseError.userCancelled
        case .pending:
            // Family Sharing ask-to-buy / 等待批准
            AppLogger.app.info("purchase.storekit.pending product=\(productId, privacy: .public)")
            throw PurchaseError.pending
        @unknown default:
            AppLogger.app.error("purchase.storekit.unknown_result product=\(productId, privacy: .public)")
            throw PurchaseError.verificationFailed(message: "未知 PurchaseResult case")
        }

        // 4. 调后端 redeem(transaction.id 是 UInt64,转 String 对齐后端 schema transaction_id TEXT)
        let transactionId = String(transaction.id)
        AppLogger.app.info("purchase.storekit.tx_received tx=\(transactionId, privacy: .public) product=\(productId, privacy: .public)")

        let redeemResp: EntitlementRedeemResponse
        do {
            redeemResp = try await apiClient.redeem(
                request: EntitlementRedeemRequest(
                    transactionId: transactionId,
                    productId: productId,
                    contentHash: contentHash,
                    module: module,
                    userLocalId: userLocalId
                )
            )
        } catch {
            AppLogger.app.error("purchase.storekit.redeem_failed tx=\(transactionId, privacy: .public) error=\(String(describing: error), privacy: .public)")
            // ⚠️ 防漏单:不调 transaction.finish(),保留 transaction 让 listener 续接。
            throw PurchaseError.backendRedeemFailed(underlying: error)
        }

        // 5. 写本地 SwiftData(镜像后端 entitlement 表)
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
            AppLogger.app.error("purchase.storekit.local_write_failed tx=\(transactionId, privacy: .public) error=\(String(describing: error), privacy: .public)")
            // 本地写入失败也不 finish,下次启动 listener 重试(后端已有 entitlement)
            throw PurchaseError.entitlementStoreFailed(underlying: error)
        }

        // 6. finish transaction(Apple 确认收到,只有 redeem + upsert 全成功才 finish)
        await transaction.finish()
        AppLogger.app.info("purchase.storekit.tx_finished tx=\(transactionId, privacy: .public)")

        // 7. 查回
        guard let entitlement = entitlementStore.getActive(
            contentHash: contentHash,
            module: module,
            userLocalId: userLocalId
        ) else {
            AppLogger.app.error(
                "purchase.storekit.get_active_returned_nil tx=\(transactionId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public)"
            )
            throw PurchaseError.entitlementStoreFailed(
                underlying: NSError(
                    domain: "PurchaseManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "upsert 成功但 getActive 返回 nil"]
                )
            )
        }
        AppLogger.app.info("purchase.storekit.ok tx=\(transactionId, privacy: .public) entitlement_transactionId=\(entitlement.transactionId, privacy: .public) isActive=\(entitlement.isActive, privacy: .public)")
        return entitlement
    }
}

// MARK: - PurchaseError

enum PurchaseError: LocalizedError {
    // M3a/c 已有
    case entitlementStoreFailed(underlying: Error)
    case backendRedeemFailed(underlying: Error)

    // M3b 新增
    case userCancelled
    case networkFailed(underlying: Error)
    case verificationFailed(message: String)
    case productNotFound(productId: String)
    case pending

    var errorDescription: String? {
        switch self {
        case .entitlementStoreFailed(let underlying):
            return "授权数据写入失败:\(underlying.localizedDescription)"
        case .backendRedeemFailed(let underlying):
            return "后端授权同步失败:\(underlying.localizedDescription)"
        case .userCancelled:
            // 静默:Apple HIG 建议 IAP 取消不要打扰用户
            return nil
        case .networkFailed(let underlying):
            return "网络连接失败,请检查网络后重试:\(underlying.localizedDescription)"
        case .verificationFailed(let message):
            return message
        case .productNotFound(let productId):
            return "商品配置异常(\(productId)),请联系客服"
        case .pending:
            return "购买请求已提交,等待批准后生效"
        }
    }

    /// 是否应该静默(不显错误 UI)。
    /// `.userCancelled` 静默;`.pending` 不静默但应有正向提示(等待批准)。
    var isSilent: Bool {
        switch self {
        case .userCancelled: return true
        default: return false
        }
    }
}
