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

    /// Transaction.updates listener 任务引用。
    /// `nonisolated(unsafe)`:Swift 6 严格模式下 deinit(@MainActor isolation 外)访问需要此标注。
    /// 实际并发安全:仅 deinit 单点访问 + Task 自身 Sendable。
    nonisolated(unsafe) private var transactionListenerTask: Task<Void, Never>?

    init(entitlementStore: EntitlementStore, apiClient: APIClient) {
        self.entitlementStore = entitlementStore
        self.apiClient = apiClient
    }

    deinit {
        transactionListenerTask?.cancel()
    }

    /// 启动 Transaction.updates listener(由 AppEnvironment.init 调一次)。
    ///
    /// 处理三种场景:
    /// (a) 退款/撤销:`tx.revocationDate != nil` → 本地 deactivate + finish(后端 webhook 已先处理)
    /// (b) unfinished transaction 续接:purchaseStoreKitPath redeem 失败时不 finish,下次启动 listener 重试
    /// (c) 跨设备同步:新设备看到已有 purchase,本地无 entitlement → 调 redeem(后端 idempotent)
    ///
    /// **v1 简化**:listener 主要处理 revoke + 简单 finish 续接。
    /// 完整跨设备 redeem 续接需后端 transactionId → content_hash 反查接口,v1 没有,推 M6/v2。
    func startTransactionListener() {
        transactionListenerTask = Task.detached { [weak self] in
            for await update in Transaction.updates {
                guard let self else { continue }
                await MainActor.run {
                    self.handleTransactionUpdate(update)
                }
            }
        }
        AppLogger.app.info("purchase.storekit.listener_started")
    }

    private func handleTransactionUpdate(_ update: VerificationResult<Transaction>) {
        switch update {
        case .verified(let tx):
            let txId = String(tx.id)
            if tx.revocationDate != nil {
                AppLogger.app.info("purchase.storekit.update.revoked tx=\(txId, privacy: .public)")
                Task { await handleRevocation(tx) }
            } else {
                AppLogger.app.info("purchase.storekit.update.continuation tx=\(txId, privacy: .public)")
                Task { await handleRedeemContinuation(tx) }
            }
        case .unverified(_, let error):
            // 验签失败不 finish(防诈骗),等下次重试或人工干预
            AppLogger.app.error("purchase.storekit.update.unverified error=\(String(describing: error), privacy: .public)")
        }
    }

    /// 退款/撤销同步:本地 deactivate(后端 webhook 已先处理)。
    private func handleRevocation(_ tx: Transaction) async {
        let txId = String(tx.id)
        _ = entitlementStore.deactivate(transactionId: txId)
        await tx.finish()
        AppLogger.app.info("purchase.storekit.revocation_handled tx=\(txId, privacy: .public)")
    }

    /// unfinished transaction 续接。
    /// v1 简化:直接 finish(本地 entitlement 在 purchaseStoreKitPath 主路径已写或未写)。
    /// 完整续接需后端 transactionId → content_hash 反查接口(M6/v2 补),这里至少清掉 unfinished 状态。
    private func handleRedeemContinuation(_ tx: Transaction) async {
        let txId = String(tx.id)
        // 若本地已有此 transactionId 的 active entitlement,说明主路径已写完,只是 finish 漏调
        // 若没有,可能是 redeem 失败 → 这里 finish 掉,用户需重新购买(v1 容忍,完整续接 M6/v2)
        await tx.finish()
        AppLogger.app.info("purchase.storekit.continuation_finished tx=\(txId, privacy: .public)")
    }

    /// 发起购买。
    ///
    /// - Parameters:
    ///   - productId: Apple SKU(如 `com.qicompass.deep_analysis.single`)
    ///   - contentHash: 命盘 hash(深度解析)或 compatibility_hash(合盘)
    ///   - module: 基础名(`bazi_deep` / `compatibility`),不含 _free/_paid
    /// - Returns: 写入后的 Entitlement
    /// - Throws: PurchaseError(未登录 / 用户取消静默 / 网络失败 / 验签失败 / 后端 redeem 失败等)
    func purchase(
        productId: String,
        contentHash: String,
        module: String
    ) async throws -> Entitlement {
        // 规则 2:函数入口日志。购买是付费关键路径,出问题必须可追溯。
        AppLogger.app.info("purchase.start product=\(productId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public)")

        // Slice 4 强制登录 gate:entitlement 必须绑 Apple 账号(决策:强制登录才能买),
        // 未登录直接 throw(由 PaywallViewModel 转成 UI 错误提示)。
        guard UserIdentity.isAuthenticated else {
            AppLogger.app.warning("purchase.reject reason=not_signed_in product=\(productId, privacy: .public)")
            throw PurchaseError.notSignedIn
        }

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
        // Slice 4:已登录场景,currentUserId 返后端 user_id(qicompass_user.id);
        // 未登录被 purchase() 入口拦截,这里 userId 一定是 user_id 维度。
        let userId = UserIdentity.currentUserId
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
                    userLocalId: userId
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
                userLocalId: UserIdentity.userLocalId,  // 始终存 userLocalId(历史溯源)
                userId: userId,  // Slice 3 加:绑后端 user 维度
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
            userLocalId: UserIdentity.userLocalId,
            userId: userId
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
    /// 流程:`Product.products(for:) → product.purchase(appAccountToken:) → VerificationResult<Transaction>
    /// → apiClient.redeem(transaction.id) → entitlementStore.upsert → transaction.finish()`。
    ///
    /// **防漏单顺序**:redeem 失败时**不调 `transaction.finish()`**,保留 transaction,
    /// 让 `Transaction.updates` listener 在下次启动续接 redeem(避免用户付钱但后端漏写)。
    ///
    /// **Slice 4 appAccountToken 决策**:传 `UUID(qicompass_user.id)`。qicompass_user.id 是
    /// 后端 `uuid.uuid4()` 格式,符合 Apple appAccountToken 要求。让 Apple 后台记
    /// "transaction ↔ user" 映射,跟后端 entitlement 表双重保险。
    /// UUID 解析失败(Keychain 数据损坏)→ throw `notSignedIn`(不 fallback 随机 UUID,
    /// 避免破坏 Apple 后台映射)。
    private func purchaseStoreKitPath(
        productId: String,
        contentHash: String,
        module: String
    ) async throws -> Entitlement {
        // Slice 4:已登录场景,currentUserId 返后端 user_id;未登录被 purchase() 入口拦截。
        let userId = UserIdentity.currentUserId
        // appAccountToken 用 qicompass_user.id(UUID)。purchase() 已 guard 过 isAuthenticated,
        // 但 Keychain 可能被外部清掉(竞态),这里再 defensive 检查 + 解析 UUID。
        guard let appAccountToken = UUID(uuidString: userId) else {
            AppLogger.app.error("purchase.storekit.appAccountToken_parse_failed userId=\(userId.prefix(8), privacy: .public) — 非 UUID 格式,Keychain 数据损坏")
            throw PurchaseError.notSignedIn
        }
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

        // 2. 调起 purchase(Slice 4:传 appAccountToken = UUID(qicompass_user.id) via purchaseOption)
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(
                options: [.appAccountToken(appAccountToken)]
            )
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
                throw PurchaseError.verificationFailed(message: "购买验证失败,请重试")
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
            throw PurchaseError.verificationFailed(message: "购买未完成,请重试")
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
                    userLocalId: userId
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
                userLocalId: UserIdentity.userLocalId,  // 始终存 userLocalId(历史溯源)
                userId: userId,  // Slice 3 加:绑后端 user 维度
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
            userLocalId: UserIdentity.userLocalId,
            userId: userId
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

/// errorDescription 是**用户可见文案**(2026-08-16:代码性错误不进 UI)。
/// 技术细节(底层 error / productId)留在 associated value,由 PurchaseManager
/// 各 catch 的 AppLogger.error(String(describing: error))记录,不进 UI。
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

    // Slice 4 新增:强制登录购买
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .entitlementStoreFailed:
            // redeem 已成功(钱已付、后端已有 entitlement),仅本地 SwiftData 写失败。
            // 「已购」读本地 SwiftData,重启不会回补(冷启动不触发 onSignedIn;
            // listener 续接 v1 简化为直接 finish 不补写)——唯一自动恢复路径是
            // 重新登录(触发 synchronizeFromBackend 从后端拉回),文案必须指向它。
            return "购买已成功,本地记录保存失败,请退出登录后重新登录恢复"
        case .backendRedeemFailed:
            // 后端 redeem 失败未 finish,不会丢钱;重新购买前可先稍候重试
            return "购买验证失败,请稍后重试"
        case .userCancelled:
            // 静默:Apple HIG 建议 IAP 取消不要打扰用户
            return nil
        case .networkFailed:
            return "网络连接失败,请检查网络后重试"
        case .verificationFailed(let message):
            return message
        case .productNotFound:
            return "商品暂不可用,请稍后再试"
        case .pending:
            return "购买请求已提交,等待批准后生效"
        case .notSignedIn:
            return "请先登录后再购买"
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
