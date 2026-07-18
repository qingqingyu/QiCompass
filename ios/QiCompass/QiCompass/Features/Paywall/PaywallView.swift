import SwiftUI

/// 购买弹窗(底部 sheet + grabber)。
///
/// M3c 决策(用户拍板):底部 sheet `.presentationDetents([.medium])`,
/// 而非全屏 sheet(避免与 OnboardingView 视觉重复)。
///
/// 视觉:遵守 DESIGN.md 宋瓷极简美学(无金色 / 无磨砂玻璃),
/// 锁标用 `lock.fill` + `inkMuted`,CTA 用朱砂红 PrimaryCTAButton。
///
/// 价格:M3c 硬编码 ¥128(中国区 Price Tier 60 估算,MONETIZATION.md §商品 SKU);
/// M3b 接 StoreKit 后改用 `Product.displayPrice`(App Store Connect 真价)。
struct PaywallView: View {
    @State private var viewModel: PaywallViewModel

    /// 5 章付费内容标题(对齐后端 BAZI_DEEP_PAID_TEMPLATE 章节)
    private let paidChapters = ["财运", "爱情", "健康", "六亲", "晚年"]

    init(viewModel: PaywallViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(spacing: BaziTheme.Spacing.md) {
            // grabber(底部 sheet 标识)
            Capsule()
                .fill(BaziTheme.inkMuted.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, BaziTheme.Spacing.sm)

            Text("深度命书")
                .zcoolPageTitle(size: 22)

            Text("解锁 5 章付费深度内容")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)

            // 章节预览(锁标 + 标题列表)
            VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
                ForEach(paidChapters, id: \.self) { chapter in
                    HStack(spacing: BaziTheme.Spacing.sm) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(BaziTheme.inkMuted)
                        Text(chapter)
                            .font(.body)
                            .foregroundStyle(BaziTheme.ink)
                        Spacer()
                    }
                }
            }
            .padding(BaziTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                BaziTheme.cardBackground,
                in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                    .stroke(BaziTheme.cardBorder, lineWidth: 0.5)
            )

            Spacer()

            // CTA(M3c 用 PrimaryCTAButton,M3b 接真 StoreKit 后 loading 态会真生效)
            PrimaryCTAButton(
                title: "解锁深度命书(¥128)",
                loadingTitle: "处理中…",
                isLoading: viewModel.state == .purchasing,
                action: { Task { await viewModel.purchase() } }
            )

            // 法律免责(DESIGN.md 反 AI slop + 命理类审核要求)
            Text("玄学娱乐,理性参考。\n订阅即视为同意 Apple 标准用户协议。")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, BaziTheme.Spacing.lg)
        .padding(.bottom, BaziTheme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
