import Foundation
import StoreKit

/// 付费 module 枚举(M4 抽出):集中管理深度解析 / 合盘两个付费场景的差异字段。
///
/// - productId:Apple StoreKit SKU(M3b PurchaseManager.purchase 用)
/// - entitlementModule:后端 redeem 的 module 字段(bazi_deep / compatibility,不含 _free/_paid 后缀)
/// - title:UI 标题(深度命书 / 合盘解读)
/// - paidChapters:付费章节列表(PaywallView 锁标显示)
/// - fallbackPrice:Product 加载失败时的兜底价格(MONETIZATION.md §商品 SKU 中国区估)
enum PaywallModule {
    case deepAnalysis
    case compatibility

    /// Apple StoreKit product id
    var productId: String {
        switch self {
        case .deepAnalysis: return AppleProductID.deepAnalysisSingle
        case .compatibility: return AppleProductID.compatibilitySingle
        }
    }

    /// 后端 entitlement module 字段(传 redeem,不含 _free/_paid 后缀)
    var entitlementModule: String {
        switch self {
        case .deepAnalysis: return EntitlementModule.baziDeep
        case .compatibility: return EntitlementModule.compatibility
        }
    }

    /// UI 标题
    var title: String {
        switch self {
        case .deepAnalysis: return "深度命书"
        case .compatibility: return "合盘解读"
        }
    }

    /// 付费章节列表
    var paidChapters: [String] {
        switch self {
        // 2026-08-23 对齐 bazi_deep_paid v5(8 章命书框架,prompts.py
        // 2026-08-15 晚重构;此前锁标还写老 5 章,少承诺多交付但与产品脱节)
        case .deepAnalysis: return ["命盘", "日元", "五行", "格局倾向",
                                    "事业与财富", "婚姻感情", "学习成长", "身体健康"]
        // 五行共振改造(S1):第一章「爱情深度」→「五行共振」,与锁标 previewChapters 对齐
        case .compatibility: return ["五行共振", "合作事业", "财运合拍", "流年同步"]
        }
    }

    /// 价格加载失败 fallback(MONETIZATION.md §商品 SKU 中国区估)
    var fallbackPrice: String {
        switch self {
        case .deepAnalysis: return "¥128"
        case .compatibility: return "¥88"
        }
    }
}

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

    let module: PaywallModule
    private let contentHash: String
    private let purchaseManager: PurchaseManager

    /// S07 时辰未知拦截判据(单一事实源 = chart 存档 payload,由调用方从
    /// `BaziResponse.hourUnknownGate` 传入,VM/View 不重复推断)。默认 `.hourKnown`
    /// = 老调用点(每日运势历史解锁等)零改动,行为与现状完全一致。
    let hourUnknownGate: HourUnknownGate

    /// S10「我确实不知道」静默态(单一事实源 = 存档 payload `isHourSilenced`,
    /// 由调用方传入;默认 false = 老调用点零改动)。拦截页文案降中性(D7 第 4 条:
    /// 不再主动提示,入口保留)。
    let hourUnknownSilenced: Bool

    /// S10 补时辰触点(D7 触点 3,转化最高位置):拦截态 CTA → 打开补时辰 sheet。
    /// 由宿主注入(典型:dismiss 付费墙 + 打开 AddHourSheet);nil = 无宿主注入
    /// → CTA 不渲染(不可完成动作不展示按钮)。
    let onAddHour: (() -> Void)?

    /// 购买成功回调(由调用方注入:dismiss sheet + 重新调 _paid)。
    var onPurchaseSuccess: (() -> Void)?

    /// S07:付费墙是否处于拦截态(无时辰用户——不展示价格/不触发 purchase)。
    /// 日柱确定与日柱歧义的无时辰用户在此同形态(后者正常到不了付费墙,
    /// 传入只是防御;两类用户的分层拦截在内容页闸门完成,见 slice 文档)。
    var isPurchaseIntercepted: Bool {
        hourUnknownGate != .hourKnown
    }

    init(
        module: PaywallModule,
        contentHash: String,
        purchaseManager: PurchaseManager,
        hourUnknownGate: HourUnknownGate = .hourKnown,
        hourUnknownSilenced: Bool = false,
        onAddHour: (() -> Void)? = nil,
        onPurchaseSuccess: (() -> Void)? = nil
    ) {
        self.module = module
        self.contentHash = contentHash
        self.purchaseManager = purchaseManager
        self.hourUnknownGate = hourUnknownGate
        self.hourUnknownSilenced = hourUnknownSilenced
        self.onAddHour = onAddHour
        self.onPurchaseSuccess = onPurchaseSuccess
    }

    /// 加载 Product(显示动态价格)。sheet onAppear 时调,失败时走 fallback。
    ///
    /// S07:拦截态**不加载 StoreKit product**(D6 拦购买三件套之一)——
    /// productState 停留 `.loading`(拦截态 UI 不消费价格,恒走占位布局)。
    func loadProduct() async {
        guard !isPurchaseIntercepted else {
            let entitlementModule = module.entitlementModule
            AppLogger.app.info(
                "paywall.product.skip reason=hour_unknown_intercepted module=\(entitlementModule, privacy: .public)"
            )
            return
        }
        guard productState == .loading else { return }
        // 闭包捕获 instance property 需先提到 local(对齐 purchase() 风格)
        let productId = module.productId
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

    /// CTA 文案(加载完显示真价,加载中/失败 fallback,文案随 module 切换)。
    var displayPriceText: String {
        let price: String
        switch productState {
        case .loaded(let displayPrice):
            price = displayPrice
        case .loading, .failed:
            price = module.fallbackPrice
        }
        return "解锁\(module.title)(\(price))"
    }

    func purchase() async {
        // S07 拦截态守卫(纵深防御):拦截态 UI 不渲染购买按钮,此处保证
        // `PurchaseManager.purchase` 全程不可达(路径断言见 PaywallHourUnknownGateTests)。
        // 拦截发生在 purchase 之前,entitlement/purchase 判据零改动(D6)。
        guard !isPurchaseIntercepted else {
            let entitlementModule = module.entitlementModule
            let contentHash = self.contentHash
            AppLogger.app.warning(
                "paywall.purchase.skip reason=hour_unknown_intercepted module=\(entitlementModule, privacy: .public) content_hash=\(contentHash, privacy: .public)"
            )
            return
        }
        guard state != .purchasing else {
            // 规则 1:防重复点击的 silent return 改成 info 日志(便于排查 UI 双击)
            AppLogger.app.info("paywall.purchase.skip reason=already_purchasing")
            return
        }
        // 规则 2:函数入口日志(付费关键路径,Console 必须可追溯)
        // 技术坑:OSLogMessage 字符串插值是 lazy capture,instance property 必须先提到 local
        let productId = module.productId
        let entitlementModule = module.entitlementModule
        let contentHash = self.contentHash
        AppLogger.app.info("paywall.purchase.start product=\(productId, privacy: .public) content_hash=\(contentHash, privacy: .public) module=\(entitlementModule, privacy: .public)")
        state = .purchasing
        do {
            _ = try await purchaseManager.purchase(
                productId: productId,
                contentHash: contentHash,
                module: entitlementModule
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
            // 非 PurchaseError 系统级错误兜底:人话文案(原始 error 已记日志,不进 UI)
            AppLogger.app.error(
                "paywall.purchase.unknown_error product=\(productId, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            state = .failed("购买未完成,请重试")
        }
    }
}
