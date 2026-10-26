import Foundation
import StoreKit
import SwiftUI

// MARK: - 问事次数包购买墙(S4c C3)

/// AskPaywallView 的状态机(精简版 PaywallViewModel:无 hourUnknown 拦截、
/// 无章节清单、无本地 entitlement 写入)。购买成功即 dismiss(宿主
/// onPurchaseSuccess 关 sheet;余额已由 PurchaseManager 直写 askWallet,
/// 聊天页 onChange 自动收起 402 卡片),无 success 常驻态。
@Observable
@MainActor
final class AskPaywallViewModel {
    enum State: Equatable {
        case idle
        case purchasing
        case failed(String)
    }

    /// Product 加载状态(复用 PaywallViewModel 的嵌套枚举——同一状态机,
    /// 不另造同构)。加载失败仍允许购买(VM 兜底价,真购买时 StoreKit 自报)。
    var productState: PaywallViewModel.ProductState = .loading
    var state: State = .idle
    /// 恢复购买状态机(同上复用;消耗型诚实边界文案由 View 层呈现)
    var restoreState: PaywallViewModel.RestoreState = .idle

    private let purchaseManager: PurchaseManager
    /// 购买/恢复成功回调(典型:宿主关 sheet;余额回写已在 manager 完成)
    var onPurchaseSuccess: (() -> Void)?

    /// Product 加载失败兜底价(MONETIZATION.md §问事窗:$4.99 锚,命中
    /// 命书价 28%;各区域真价以 ASC 配置 + StoreKit displayPrice 为准)
    static let fallbackPrice = "$4.99"

    init(purchaseManager: PurchaseManager, onPurchaseSuccess: (() -> Void)? = nil) {
        self.purchaseManager = purchaseManager
        self.onPurchaseSuccess = onPurchaseSuccess
    }

    // MARK: 价格派生(与 PaywallViewModel 同口径)

    var rawPriceText: String {
        switch productState {
        case .loaded(let displayPrice): return displayPrice
        case .loading, .failed: return Self.fallbackPrice
        }
    }

    /// 大写润金(角分价 $4.99 → ChineseUpperPrice 返 nil,只显数字不造假)
    var chineseUpperPrice: String? {
        ChineseUpperPrice.priceString(from: rawPriceText)
    }

    var displayPriceText: String {
        L10n.AskPaywall.cta(price: rawPriceText)
    }

    // MARK: 动作

    func loadProduct() async {
        guard productState == .loading else { return }
        do {
            let products = try await Product.products(for: [AskPackProductID.pack15])
            if let product = products.first {
                productState = .loaded(displayPrice: product.displayPrice)
                AppLogger.app.info("askpaywall.product.loaded price=\(product.displayPrice, privacy: .public)")
            } else {
                productState = .failed
                AppLogger.app.error("askpaywall.product.not_found id=\(AskPackProductID.pack15, privacy: .public)")
            }
        } catch {
            productState = .failed
            AppLogger.app.error("askpaywall.product.load_failed error=\(String(describing: error), privacy: .public)")
        }
    }

    func purchase() async {
        guard state != .purchasing else {
            AppLogger.app.info("askpaywall.purchase.skip reason=already_purchasing")
            return
        }
        AppLogger.app.info("askpaywall.purchase.start")
        state = .purchasing
        do {
            let balance = try await purchaseManager.purchaseAskPack()
            AppLogger.app.info("askpaywall.purchase.ok balance=\(balance, privacy: .public)")
            state = .idle  // 成功即 dismiss(无 success 常驻态)
            onPurchaseSuccess?()
        } catch let error as PurchaseError {
            if error.isSilent {
                AppLogger.app.info("askpaywall.purchase.silent_cancel")
                state = .idle
            } else {
                AppLogger.app.error("askpaywall.purchase.failed error=\(String(describing: error), privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        } catch {
            AppLogger.app.error("askpaywall.purchase.unknown_error error=\(String(describing: error), privacy: .public)")
            state = .failed(String(localized: "购买未完成,请重试"))
        }
    }

    func restoreAsk() async {
        guard restoreState != .restoring else { return }
        AppLogger.app.info("askpaywall.restore.start")
        restoreState = .restoring
        do {
            switch try await purchaseManager.restoreAskPurchases() {
            case .restored:
                AppLogger.app.info("askpaywall.restore.ok")
                restoreState = .restored
                onPurchaseSuccess?()
            case .nothingFound:
                AppLogger.app.info("askpaywall.restore.nothing_found")
                restoreState = .nothingFound
            }
        } catch let error as PurchaseError {
            if error.isSilent {
                AppLogger.app.info("askpaywall.restore.silent_cancel")
                restoreState = .idle
            } else {
                AppLogger.app.error("askpaywall.restore.failed error=\(String(describing: error), privacy: .public)")
                restoreState = .failed(error.localizedDescription)
            }
        } catch {
            AppLogger.app.error("askpaywall.restore.unknown_error error=\(String(describing: error), privacy: .public)")
            restoreState = .failed(String(localized: "恢复失败,请稍后重试"))
        }
    }
}

/// 问事次数包购买墙(轻量墙:印章头 + 润金行 + 说明 + CTA + 恢复 + 法律注)。
/// 视觉语言与 PaywallView 同源(水墨孤本:焦墨 CTA、hairline、朱红仅印章);
/// 差异:无章节清单(次数包非内容解锁),价格行尾注是「消耗型 · 用完为止」。
struct AskPaywallView: View {
    @State private var viewModel: AskPaywallViewModel

    init(viewModel: AskPaywallViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: BaziTheme.Spacing.md) {
                // 印章头(「问」印 + 标题 + 副题,同 PaywallView 布局)
                HStack(spacing: 14) {
                    SealStamp(character: "问", size: 34, rotation: -4, stampDelay: 0.45)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.AskPaywall.title)
                            .font(BaziFont.display(size: 19))
                            .tracking(2)
                            .foregroundStyle(BaziTheme.ink)
                        Text(L10n.AskPaywall.subtitle)
                            .font(BaziFont.caption(size: 10.5))
                            .tracking(2)
                            .foregroundStyle(BaziTheme.inkMuted)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, BaziTheme.Spacing.xs)

                priceRow

                // 说明行:消耗型语义的诚实告知(退款扣回口径与后端 webhook 一致)
                Text(L10n.AskPaywall.note)
                    .font(BaziFont.caption(size: 10.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if case .failed(let message) = viewModel.state {
                    Text(message)
                        .font(BaziFont.caption(size: 10.5))
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                PrimaryCTAButton(
                    title: viewModel.displayPriceText,
                    loadingTitle: String(localized: "处理中…"),
                    isLoading: viewModel.state == .purchasing,
                    action: { Task { await viewModel.purchase() } }
                )

                restoreSection

                // 法律免责(与 PaywallView 同文;次数包消耗型语义已在上方说明行)
                Text("玄学娱乐,理性参考。\n购买即视为同意 Apple 标准用户协议。")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                    .multilineTextAlignment(.center)
                    .tracking(1)
            }
            .padding(.top, BaziTheme.Spacing.md)
            .padding(.horizontal, BaziTheme.Spacing.lg)
            .padding(.bottom, BaziTheme.Spacing.lg)
        }
        .presentationBackground(BaziTheme.cardSurface)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task { await viewModel.loadProduct() }
    }

    // MARK: 润金行(PricePlate 的次数包变体;不改共享组件——PaywallLayoutTests
    // 锁定其形态,且「买断制 · 不含订阅」尾注对消耗型不成立)

    private var priceRow: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VText(phrase: String(localized: "润金"), size: 9.5, tracking: 3, color: BaziTheme.inkMutedSecondary)
            if let upperPrice = viewModel.chineseUpperPrice {
                Text(upperPrice)
                    .font(BaziFont.display(size: 21, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Text(viewModel.rawPriceText)
                    .font(BaziFont.numeric(size: 19, weight: .medium))
                    .foregroundStyle(BaziTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 8)
            Text(L10n.AskPaywall.priceNote)
                .font(BaziFont.caption(size: 9.5))
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .padding(.vertical, BaziTheme.Spacing.cmd)
        .overlay(alignment: .top) {
            Rectangle().fill(BaziTheme.hairline).frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(BaziTheme.hairline).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("价格 \(viewModel.rawPriceText),\(L10n.AskPaywall.priceNote)")
    }

    // MARK: 恢复购买(同 PaywallView.restoreSection 形态)

    @ViewBuilder
    private var restoreSection: some View {
        VStack(spacing: BaziTheme.Spacing.sm) {
            Button {
                HapticEngine.light()
                Task { await viewModel.restoreAsk() }
            } label: {
                Text(viewModel.restoreState == .restoring ? String(localized: "恢复中…") : String(localized: "恢复购买"))
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
            }
            .disabled(viewModel.state == .purchasing || viewModel.restoreState == .restoring)

            switch viewModel.restoreState {
            case .restored:
                Text("已恢复购买")
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMuted)
            case .nothingFound:
                Text("未找到可恢复的购买")
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMuted)
            case .failed(let message):
                Text(message)
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.shenshaInauspicious)
                    .multilineTextAlignment(.center)
            case .idle, .restoring:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
    }
}
