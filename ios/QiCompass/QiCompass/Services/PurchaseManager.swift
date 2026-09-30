import Foundation
import StoreKit

/// PurchaseManager(购买流程入口)。
///
/// **两条路径共存**:
/// - `purchaseMockPath`:Mock 模式(`apiClient is MockAPIClient`),用 `mock_tx_<UUID>` 假 transactionId 走完后端 redeem 链路。dev/test 用,无需 Apple 沙盒。
/// - `purchaseStoreKitPath`:真路径,走 `Product.purchase() → VerificationResult<Transaction>`,需要 StoreKit Configuration 文件本地测试 或 ASC 真商品 + Apple 沙盒(M6 TestFlight)。
///
/// **防漏单**(M3b 关键,2026-09-29 兑现闭环):
/// `purchaseStoreKitPath` 中后端 redeem 失败 / 本地写入失败时**不调 `transaction.finish()`**,
/// 且把原始购买上下文(productId/contentHash/module)按 transactionId 落 `PendingRedeemStore`
/// (消耗型交易本体不带 content_hash,续接 redeem 只能靠失败时点记住)。
/// 下次启动(或交易重投递时)`Transaction.updates` listener 按记录续接 redeem,
/// 成功才清记录 + finish;无记录且本地无 active entitlement 的交易**不 finish**,
/// 保留给对应模块付费墙的「恢复购买」。避免"用户付了钱但后端没收到"的资损场景。
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
    /// (b) unfinished transaction 续接:purchaseStoreKitPath redeem/本地写失败时不 finish
    ///     且落 pending 记录 → listener 按原始上下文续接 redeem(见 handleRedeemContinuation)
    /// (c) 无上下文交易(ask-to-buy 批准后送达等):不 finish,保留给对应模块
    ///     付费墙的「恢复购买」——恢复时绑定用户当前正看的盘(接受的产品语义)
    ///
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
        // 已退款交易无续接价值,清 pending 记录防 listener 复活它
        PendingRedeemStore.remove(txId: txId)
        await tx.finish()
        AppLogger.app.info("purchase.storekit.revocation_handled tx=\(txId, privacy: .public)")
    }

    /// unfinished transaction 续接(防漏单闭环,2026-09-29 修复)。
    ///
    /// 消耗型交易 finish 即从队列永久消失——付过钱的交易只能在「已确认兑现
    /// 或已退款」时才 finish,任何分支都不得无条件 finish:
    /// 1. 有 pending 记录(主路径 redeem/本地写失败时落档)→ 按原始
    ///    contentHash/module 续接 redeem(module 仍以交易自身 SKU 反查为准,
    ///    不信记录),成功才清记录 + finish(先清后 finish:反序的崩溃窗口
    ///    会留永不兑现的死记录);失败(网络等)保留,下次重投递
    ///    再续;403 ENTITLEMENT_ERROR(已绑其他上下文/已退款)→ 价值已在他处
    ///    兑现,清记录 + finish 收尾,防每启动重试死循环;
    /// 2. 本地已有该 transactionId 的 active entitlement → 主路径已完成,
    ///    只是 finish 漏调 → 补 finish;
    /// 3. 两者皆无(ask-to-buy 批准后送达 / restorePurchases 跨 SKU 跳过的
    ///    交易)→ **不 finish**,保留给对应模块付费墙的「恢复购买」(与
    ///    restorePurchases 的保留承诺一致;旧实现无条件 finish,被跳过的
    ///    交易在下次启动被直接吞掉——钱付了,权益没了)。
    private func handleRedeemContinuation(_ tx: Transaction) async {
        let txId = String(tx.id)

        // 1) pending 记录续接:用失败时点记住的原始上下文调 redeem(幂等,
        //    后端同 transactionId 已 active 时校验一致直接返回)
        if let pending = PendingRedeemStore.get(txId: txId) {
            // module 以交易自身 SKU 反查为准(与 restorePurchases 同判据);
            // 记录与 SKU 映射不一致(SKU 表变更等)→ 记录不可信,作废走 2/3
            guard Self.module(forProductID: tx.productID) == pending.module else {
                PendingRedeemStore.remove(txId: txId)
                AppLogger.app.error("purchase.storekit.continuation_module_conflict tx=\(txId, privacy: .public) product=\(tx.productID, privacy: .public) pending_module=\(pending.module, privacy: .public)")
                await finishIfRecorded(tx, txId: txId)
                return
            }
            do {
                let redeemResp = try await apiClient.redeem(
                    request: EntitlementRedeemRequest(
                        transactionId: txId,
                        productId: tx.productID,
                        contentHash: pending.contentHash,
                        module: pending.module,
                        userLocalId: UserIdentity.userLocalId
                    )
                )
                try await entitlementStore.upsert(
                    transactionId: redeemResp.transactionId,
                    productId: tx.productID,
                    contentHash: pending.contentHash,
                    module: pending.module,
                    userLocalId: UserIdentity.userLocalId,
                    userId: UserIdentity.isAuthenticated ? UserIdentity.currentUserId : nil,
                    purchasedAt: redeemResp.purchasedAt,
                    originalPurchaseDate: redeemResp.originalPurchaseDate
                )
                // 先清记录后 finish:反序的崩溃窗口(finish 后未及 remove)会留
                // 下永不兑现的死记录——已 finish 的消耗型交易不再重投递,没人
                // 再清它;先清后崩则重投递走判据 2(本地 active 已写)补 finish。
                PendingRedeemStore.remove(txId: txId)
                await tx.finish()
                AppLogger.app.info("purchase.storekit.continuation_redeemed tx=\(txId, privacy: .public) module=\(pending.module, privacy: .public)")
            } catch let apiError as APIError {
                // 403 ENTITLEMENT_ERROR = 交易已绑其他 content_hash/module 或已
                // 退款:价值已在他处兑现,清记录 + finish 收尾(其余错误保留待续)
                if case .backendError(let code, _, _) = apiError, code == "ENTITLEMENT_ERROR" {
                    PendingRedeemStore.remove(txId: txId)
                    await tx.finish()
                    AppLogger.app.info("purchase.storekit.continuation_bound_elsewhere tx=\(txId, privacy: .public)")
                } else {
                    AppLogger.app.error("purchase.storekit.continuation_redeem_failed tx=\(txId, privacy: .public) error=\(String(describing: apiError), privacy: .public)")
                }
            } catch {
                // 不 finish:交易与记录都保留,下次启动/恢复购买再续
                AppLogger.app.error("purchase.storekit.continuation_redeem_failed tx=\(txId, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
            return
        }

        // 2) 本地已有 active entitlement → 主路径已完成,补 finish
        // 3) 无上下文可续 → 不 finish,保留给对应模块付费墙的「恢复购买」
        await finishIfRecorded(tx, txId: txId)
    }

    /// 判据 2/3 共用兜底:本地已兑现(transactionId 命中 active entitlement)
    /// → 补 finish;未兑现 → **不 finish**,保留给对应模块付费墙的「恢复购买」。
    private func finishIfRecorded(_ tx: Transaction, txId: String) async {
        if entitlementStore.getActive(transactionId: txId) != nil {
            await tx.finish()
            AppLogger.app.info("purchase.storekit.continuation_finished tx=\(txId, privacy: .public)")
        } else {
            AppLogger.app.info("purchase.storekit.continuation_deferred tx=\(txId, privacy: .public)")
        }
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

        // 2026-09-27 匿名购买:登录不再是购买前置(App Store 审核风险 + 登录步流失),
        // 未登录直接匿名购买(entitlement 落 user_id NULL,登录后由 backfill/claim 补绑);
        // 登录态照旧绑账号维度。鉴权可选由后端 redeem 支持(get_current_user_id)。
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
        // 登录态绑账号维度;匿名(2026-09-27)userId 为 nil,entitlement 走
        // user_local_id 维度(安装 UUID,与后端 backfill/claim 匹配维度一致)。
        let userId = UserIdentity.isAuthenticated ? UserIdentity.currentUserId : nil
        let mockTransactionId = "mock_tx_\(UUID().uuidString.prefix(8))"

        AppLogger.app.info(
            "purchase.mock_start product=\(productId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public) tx=\(mockTransactionId, privacy: .public) signed_in=\(userId != nil, privacy: .public)"
        )

        let redeemResp: EntitlementRedeemResponse
        do {
            redeemResp = try await apiClient.redeem(
                request: EntitlementRedeemRequest(
                    transactionId: mockTransactionId,
                    productId: productId,
                    contentHash: contentHash,
                    module: module,
                    userLocalId: UserIdentity.userLocalId
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
    /// **appAccountToken 决策(2026-09-27 匿名购买修订)**:登录态传
    /// `UUID(qicompass_user.id)`(后端 uuid.uuid4 格式,Apple 后台记
    /// "transaction ↔ user" 映射);**匿名购买不传**(无服务端 user 可映射,
    /// StoreKit 空 options 是合法调用形态)。登录态解析失败(Keychain 数据
    /// 损坏)→ throw verificationFailed(不 fallback 随机 UUID,避免破坏映射)。
    private func purchaseStoreKitPath(
        productId: String,
        contentHash: String,
        module: String
    ) async throws -> Entitlement {
        // 登录态绑账号维度;匿名 userId 为 nil(redeem 落 user_id NULL)。
        let userId = UserIdentity.isAuthenticated ? UserIdentity.currentUserId : nil
        // appAccountToken 仅登录态有(匿名传 nil → purchase options 为空数组)。
        var appAccountToken: UUID? = nil
        if let userId {
            guard let parsed = UUID(uuidString: userId) else {
                AppLogger.app.error("purchase.storekit.appAccountToken_parse_failed userId=\(userId.prefix(8), privacy: .public) — 非 UUID 格式,Keychain 数据损坏")
                throw PurchaseError.verificationFailed(message: String(localized: "账号凭证异常,请重新登录后再试"))
            }
            appAccountToken = parsed
        }
        AppLogger.app.info("purchase.storekit.start product=\(productId, privacy: .public) signed_in=\(userId != nil, privacy: .public)")

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

        // 2. 调起 purchase(appAccountToken 仅登录态;匿名 → 空 options)
        let result: Product.PurchaseResult
        do {
            result = try await product.purchase(
                options: appAccountToken.map { [.appAccountToken($0)] } ?? []
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
                throw PurchaseError.verificationFailed(message: String(localized: "购买验证失败,请重试"))
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
            throw PurchaseError.verificationFailed(message: String(localized: "购买未完成,请重试"))
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
                    userLocalId: UserIdentity.userLocalId
                )
            )
        } catch {
            AppLogger.app.error("purchase.storekit.redeem_failed tx=\(transactionId, privacy: .public) error=\(String(describing: error), privacy: .public)")
            // ⚠️ 防漏单:不调 transaction.finish(),且落 pending 记录(原始
            // contentHash/module)让 listener 按原上下文续接 redeem——消耗型
            // 交易本体不带 content_hash,不记就永远无法自动续接。
            PendingRedeemStore.set(
                txId: transactionId,
                .init(productId: productId, contentHash: contentHash, module: module))
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
            // 本地写入失败也不 finish + 落 pending 记录:listener 续接时 redeem
            // 幂等命中(后端已有 entitlement)+ 重试本地写入
            PendingRedeemStore.set(
                txId: transactionId,
                .init(productId: productId, contentHash: contentHash, module: module))
            throw PurchaseError.entitlementStoreFailed(underlying: error)
        }

        // 6. finish transaction(Apple 确认收到,只有 redeem + upsert 全成功才 finish)
        // 先清 pending 记录后 finish(崩溃窗口推理与 handleRedeemContinuation 成功
        // 路径同源):本 tx 若曾失败落档,此刻价值已兑现,记录必须随之清掉——
        // 已 finish 的消耗型交易不再重投递,留着就是永不回收的死记录
        // (P2 卫生修复 2026-09-30:失败后同 tx 重试成功的场景曾把记录永久遗留)
        PendingRedeemStore.remove(txId: transactionId)
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

    // MARK: - 恢复购买(2026-09-27)

    /// 恢复购买结果。
    enum RestoreOutcome: Equatable {
        /// 恢复了 N 笔(对当前 contentHash/module 生效)
        case restored(Int)
        /// 扫描完成但无可恢复交易
        case nothingFound
    }

    /// 恢复购买(App Store 语义 + 消耗型语义的诚实组合)。
    ///
    /// **商品是消耗型**(MONETIZATION.md:21,per-命盘购买),Apple 的
    /// `currentEntitlements` 永不含消耗型、已 finish 的消耗型也从
    /// `Transaction.all` 消失——本方法做三件事:
    /// 1. `AppStore.sync()`:让系统重投递未完成交易(ask-to-buy 批准 /
    ///    中断购买),用户取消是静默合法路径;
    /// 2. 扫 `Transaction.all` 里本 app 两个 SKU 的未 revoke verified 交易:
    ///    **只处理 SKU 对应 module 与当前付费墙 module 一致**的(2026-09-28
    ///    跨 SKU 修复,见循环内 guard),逐笔 redeem(登录态自动带 JWT,匿名走
    ///    user_local_id)→ 本地 upsert → finish。后端 403(交易已绑其他命盘/
    ///    module 不符/已退款)静默跳过(不 finish 不计数——那笔交易属于别的盘
    ///    或别的模块,不是「本盘可恢复」);
    /// 3. 登录态补跑 `synchronizeFromBackend`(跨设备/重装场景真正的恢复
    ///    通道——消耗型跨设备本来就只能靠自家账号,不靠 Apple)。
    ///
    /// 诚实边界(文案已对齐):匿名 + 重装/换机 → `.nothingFound`(消耗型
    /// 固有语义,绑定账号是唯一出路)。
    ///
    /// - Parameters:
    ///   - contentHash: 当前付费墙对应的命盘 hash(未完成交易缺命盘上下文,
    ///     绑定到用户当前正看的盘——「恢复我正在看的东西」是接受的产品语义)
    ///   - module: `bazi_deep` / `compatibility`
    /// - Throws: PurchaseError(AppStore.sync 网络/取消静默 / redeem 网络失败)
    func restorePurchases(contentHash: String, module: String) async throws -> RestoreOutcome {
        // Mock 路径:不碰 StoreKit(单测宿主无 .storekit 配置),只查本地镜像。
        // Mock 语义:本地有当前盘 entitlement = 已恢复;无 = 未找到。
        if apiClient is MockAPIClient {
            let userId = UserIdentity.isAuthenticated ? UserIdentity.currentUserId : nil
            let existing = entitlementStore.getActive(
                contentHash: contentHash,
                module: module,
                userLocalId: UserIdentity.userLocalId,
                userId: userId
            )
            return existing != nil ? .restored(1) : .nothingFound
        }

        AppLogger.app.info("purchase.restore.start content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public)")

        // 1. AppStore.sync:可能弹 Apple ID 认证;用户取消 → 静默(对齐 userCancelled 语义)
        do {
            try await AppStore.sync()
        } catch {
            // 取消属用户侧合法退出,静默交回 idle;其余按网络失败显错
            if let skError = error as? SKError, skError.code == .paymentCancelled {
                AppLogger.app.info("purchase.restore.sync_user_cancelled")
                throw PurchaseError.userCancelled
            }
            AppLogger.app.error("purchase.restore.sync_failed error=\(String(describing: error), privacy: .public)")
            throw PurchaseError.networkFailed(underlying: error)
        }

        // 2. 扫本 app SKU 的历史交易(消耗型:只有未 finish 的会出现)
        let productIds: Set<String> = [
            AppleProductID.deepAnalysisSingle,
            AppleProductID.compatibilitySingle,
        ]
        var restoredCount = 0
        var lastRedeemError: Error?
        for await result in Transaction.all {
            guard case .verified(let tx) = result else { continue }
            guard productIds.contains(tx.productID) else { continue }
            guard tx.revocationDate == nil else { continue }

            // 2026-09-28 跨 SKU 修复:module 按交易自身 productID 反查(对齐后端
            // PRODUCT_MODULE_MAP),不用付费墙 ambient module——否则深度解析的
            // 未 finish 交易会在合盘付费墙恢复时被兑成合盘权益并 finish(),
            // 消耗型绑定不可逆,深度解析的钱永久兑错。其他 module 的交易跳过:
            // **不 finish 不计数**,保留给对应模块付费墙恢复(2026-09-29 起
            // listener 对无 pending 记录的交易同样不 finish,该承诺两端一致,
            // 被跳过的交易不会在下次启动被 listener 吞掉)。
            guard Self.module(forProductID: tx.productID) == module else {
                AppLogger.app.info(
                    "purchase.restore.tx_skipped_other_module tx=\(String(tx.id), privacy: .public) product=\(tx.productID, privacy: .public) ambient_module=\(module, privacy: .public)"
                )
                continue
            }

            let txId = String(tx.id)
            do {
                let redeemResp = try await apiClient.redeem(
                    request: EntitlementRedeemRequest(
                        transactionId: txId,
                        productId: tx.productID,
                        contentHash: contentHash,
                        module: module,
                        userLocalId: UserIdentity.userLocalId
                    )
                )
                try await entitlementStore.upsert(
                    transactionId: redeemResp.transactionId,
                    productId: tx.productID,
                    contentHash: contentHash,
                    module: module,
                    userLocalId: UserIdentity.userLocalId,
                    userId: UserIdentity.isAuthenticated ? UserIdentity.currentUserId : nil,
                    purchasedAt: redeemResp.purchasedAt,
                    originalPurchaseDate: redeemResp.originalPurchaseDate
                )
                // 先清记录后 finish(与 handleRedeemContinuation 成功路径同序):
                // 反序崩溃窗口留死记录;先清后崩则重投递走判据 2(本地已写)补 finish
                PendingRedeemStore.remove(txId: txId)
                await tx.finish()
                restoredCount += 1
                AppLogger.app.info("purchase.restore.tx_recovered tx=\(txId, privacy: .public) product=\(tx.productID, privacy: .public)")
            } catch let apiError as APIError {
                // 403 ENTITLEMENT_ERROR = 交易已绑其他 content_hash/module 或已退款:
                // 属于「别的盘」的历史交易,静默跳过(不 finish、不计数)
                if case .backendError(let code, _, _) = apiError, code == "ENTITLEMENT_ERROR" {
                    AppLogger.app.info("purchase.restore.tx_skipped_bound_elsewhere tx=\(txId, privacy: .public)")
                    continue
                }
                lastRedeemError = apiError
                AppLogger.app.error("purchase.restore.tx_redeem_failed tx=\(txId, privacy: .public) error=\(String(describing: apiError), privacy: .public)")
            } catch {
                lastRedeemError = error
                AppLogger.app.error("purchase.restore.tx_failed tx=\(txId, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }

        // 3. 登录态补跑后端同步(跨设备/重装的真正恢复通道;失败不阻断,内部已记日志)
        if UserIdentity.isAuthenticated {
            await entitlementStore.synchronizeFromBackend(apiClient: apiClient)
        }

        // 计数口径:本地已有当前盘 entitlement(同步带回)也算恢复成功
        if restoredCount == 0, UserIdentity.isAuthenticated,
           entitlementStore.getActive(
               contentHash: contentHash,
               module: module,
               userLocalId: UserIdentity.userLocalId
           ) != nil {
            restoredCount += 1
        }

        if restoredCount == 0, let lastRedeemError {
            // 一笔都没恢复且存在真实网络错误 → 显错(不是「未找到」)
            throw PurchaseError.backendRedeemFailed(underlying: lastRedeemError)
        }
        AppLogger.app.info("purchase.restore.ok restored=\(restoredCount, privacy: .public)")
        return restoredCount > 0 ? .restored(restoredCount) : .nothingFound
    }

    /// Apple SKU → entitlement module(对齐后端 `PRODUCT_MODULE_MAP`,双端各一份:
    /// 后端是权威校验,iOS 用它过滤 restore 扫描,防止跨 SKU redeem)。
    private static func module(forProductID productID: String) -> String? {
        switch productID {
        case AppleProductID.deepAnalysisSingle: return EntitlementModule.baziDeep
        case AppleProductID.compatibilitySingle: return EntitlementModule.compatibility
        default: return nil
        }
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

    var errorDescription: String? {
        switch self {
        case .entitlementStoreFailed:
            // redeem 已成功(钱已付、后端已有 entitlement),仅本地 SwiftData 写失败。
            // 已落 pending 记录:listener/下次启动按原始上下文续接(redeem 幂等
            // 命中 + 重试本地写入);若设备等不到自动续接,重新登录触发
            // synchronizeFromBackend 从后端拉回,文案指向它。
            return String(localized: "购买已成功,本地记录保存失败,请退出登录后重新登录恢复")
        case .backendRedeemFailed:
            // 后端 redeem 失败:未 finish + 已落 pending 记录,不会丢钱;
            // listener/下次启动自动续接 redeem,重新购买前可先稍候重试
            return String(localized: "购买验证失败,请稍后重试")
        case .userCancelled:
            // 静默:Apple HIG 建议 IAP 取消不要打扰用户
            return nil
        case .networkFailed:
            return String(localized: "网络连接失败,请检查网络后重试")
        case .verificationFailed(let message):
            return message
        case .productNotFound:
            return String(localized: "商品暂不可用,请稍后再试")
        case .pending:
            return String(localized: "购买请求已提交,等待批准后生效")
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

// MARK: - 防漏单 pending 记录(2026-09-29)

/// 购买链路失败(redeem / 本地写)时按 transactionId 落档的原始购买上下文。
///
/// listener 续接 redeem 需要后端契约的 content_hash/module,而消耗型交易
/// 本体不带这些信息——只能在失败时点记住、成功兑现后清掉。UserDefaults
/// 足够承载:记录极小、生命周期短(成功即清)、单设备维度(消耗型 unfinished
/// 交易只会在购买设备上重投递),无需进 SwiftData schema。
enum PendingRedeemStore {
    private static let storageKey = "qicompass.pending_redeems.v1"

    struct Record: Codable, Equatable {
        let productId: String
        let contentHash: String
        let module: String
    }

    static func get(txId: String) -> Record? {
        all()[txId]
    }

    /// 落档(**保留首条**,P2 卫生修复 2026-09-30):同 txId 已有**不同**上下文的
    /// 记录时不覆盖——首条对应的 redeem 可能已在他处兑现到一半(客户端超时但
    /// 后端已提交),被顶掉后 listener 拿新 hash 续接会撞 ENTITLEMENT_ERROR 走
    /// 「清记录 + finish」收尾,首条对应的本地 entitlement 从此无人补写。
    /// 同上下文重写 = 幂等,照常落。冲突显式记日志(不静默吞)。
    static func set(txId: String, _ record: Record) {
        var entries = all()
        if let existing = entries[txId], existing != record {
            AppLogger.app.error(
                "purchase.pending_redeem.conflict_keep_first tx=\(txId, privacy: .public) existing_hash=\(existing.contentHash, privacy: .public) incoming_hash=\(record.contentHash, privacy: .public)"
            )
            return
        }
        entries[txId] = record
        persist(entries, context: "set tx=\(txId)")
    }

    static func remove(txId: String) {
        var entries = all()
        guard entries.removeValue(forKey: txId) != nil else { return }
        persist(entries, context: "remove tx=\(txId)")
    }

    private static func all() -> [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return [:]
        }
        do {
            return try JSONDecoder().decode([String: Record].self, from: data)
        } catch {
            // 存储损坏(极小概率):显式记日志后按空表处理——不 crash 不静默,
            // 后续 set 会整体覆写,损坏自愈
            AppLogger.app.error("purchase.pending_redeem.decode_failed error=\(String(describing: error), privacy: .public)")
            return [:]
        }
    }

    private static func persist(_ entries: [String: Record], context: String) {
        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            // 编码失败(Record 全 String,理论上不可达):显式报错,不静默吞
            AppLogger.app.error("purchase.pending_redeem.encode_failed context=\(context, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }
}
