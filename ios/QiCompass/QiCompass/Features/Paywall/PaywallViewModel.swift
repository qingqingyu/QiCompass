import Foundation

/// PaywallView 的状态机(M3c)。
///
/// 流程:
/// - idle → 用户点 CTA
/// - purchasing → PurchaseManager.purchase() 进行中(CTA disabled + spinner)
/// - success → 写入 entitlement 成功 → onPurchaseSuccess 触发(sheet dismiss + 重调 _paid)
/// - failed(message) → 失败(message 显示给用户)
///
/// M3a/c Mock 模式:PurchaseManager.purchase() 不真调 StoreKit,
/// 直接写本地 SwiftData → 几乎不可能失败(除非 SwiftData 写入异常)。
/// M3b 接真 StoreKit 后,failed 可能来自 Apple 网络故障 / 用户取消 / 后端 redeem 失败。
@Observable
@MainActor
final class PaywallViewModel {
    enum State: Equatable {
        case idle
        case purchasing
        case success
        case failed(String)
    }

    var state: State = .idle

    private let contentHash: String
    private let module: String
    private let productId: String
    private let purchaseManager: PurchaseManager

    /// 购买成功回调(由 DeepAnalysisResultView 注入:dismiss sheet + 重新调 _paid)。
    var onPurchaseSuccess: (() -> Void)?

    init(
        contentHash: String,
        module: String,
        productId: String,
        purchaseManager: PurchaseManager,
        onPurchaseSuccess: (() -> Void)? = nil
    ) {
        self.contentHash = contentHash
        self.module = module
        self.productId = productId
        self.purchaseManager = purchaseManager
        self.onPurchaseSuccess = onPurchaseSuccess
    }

    func purchase() async {
        guard state != .purchasing else {
            // 规则 1:防重复点击的 silent return 改成 info 日志(便于排查 UI 双击)
            AppLogger.app.info("paywall.purchase.skip reason=already_purchasing")
            return
        }
        // 规则 2:函数入口日志(付费关键路径,Console 必须可追溯)
        // 技术坑:OSLogMessage 字符串插值是 lazy capture,instance property 必须先提到 local
        let productId = self.productId
        let contentHash = self.contentHash
        let module = self.module
        AppLogger.app.info("paywall.purchase.start product=\(productId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(module, privacy: .public)")
        state = .purchasing
        do {
            _ = try await purchaseManager.purchase(
                productId: productId,
                contentHash: contentHash,
                module: module
            )
            AppLogger.app.info("paywall.purchase.ok product=\(productId, privacy: .public)")
            state = .success
            onPurchaseSuccess?()
        } catch let error as PurchaseError {
            // PurchaseError 分类:userCancelled 静默回 .idle(Apple HIG 建议取消不打扰);
            // 其他显式显错(.networkFailed / .verificationFailed / .productNotFound / .pending /
            // .backendRedeemFailed / .entitlementStoreFailed)。
            if error.isSilent {
                AppLogger.app.info("paywall.purchase.silent_cancel product=\(productId, privacy: .public)")
                state = .idle
            } else {
                AppLogger.app.error(
                    "paywall.purchase.failed product=\(productId, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                // errorDescription 不为 nil(isSilent=false 时一定有值),兜底"购买失败"
                state = .failed(error.localizedDescription ?? "购买失败")
            }
        } catch {
            // 非 PurchaseError 系统级错误兜底
            AppLogger.app.error(
                "paywall.purchase.unknown_error product=\(productId, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            state = .failed(error.localizedDescription)
        }
    }
}
