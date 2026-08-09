import Foundation
import StoreKit

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

    /// Product 加载状态(T3):sheet 弹出即触发 loadProduct,加载完成刷新价格文案。
    /// 加载失败仍允许 purchase(用 AppleProductID 硬编码 id 兜底,真购买时再让 StoreKit 自己报错)。
    enum ProductState: Equatable {
        case loading
        case loaded(displayPrice: String)  // Product.displayPrice 已本地化(按用户 App Store 区域)
        case failed  // 加载失败,UI 走 fallback
    }

    var state: State = .idle
    var productState: ProductState = .loading

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

    /// 加载 Product(显示动态价格)。sheet onAppear 时调,失败时走 fallback。
    func loadProduct() async {
        guard productState == .loading else { return }
        // 闭包捕获 instance property 需先提到 local(对齐 purchase() 风格)
        let productId = self.productId
        do {
            let products = try await Product.products(for: [productId])
            if let product = products.first {
                productState = .loaded(displayPrice: product.displayPrice)
                AppLogger.app.info("paywall.product.loaded id=\(productId, privacy: .public) price=\(product.displayPrice, privacy: .public)")
            } else {
                productState = .failed
                AppLogger.app.error("paywall.product.not_found id=\(productId, privacy: .public)")
            }
        } catch {
            productState = .failed
            AppLogger.app.error("paywall.product.load_failed id=\(productId, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }

    /// CTA 文案(加载完显示真价,加载中/失败 fallback ¥128,MONETIZATION.md §商品 SKU 中国区估)。
    /// TODO(M4): 合盘参数化 module,深度命书 vs 合盘文案区分。
    var displayPriceText: String {
        switch productState {
        case .loaded(let price):
            return "解锁深度命书(\(price))"
        case .loading, .failed:
            return "解锁深度命书(¥128)"
        }
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
                // PurchaseError.localizedDescription 由 errorDescription 提供,isSilent=false 时一定有值
                state = .failed(error.localizedDescription)
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
