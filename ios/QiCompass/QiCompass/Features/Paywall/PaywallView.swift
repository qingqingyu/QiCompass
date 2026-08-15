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
    @EnvironmentObject private var env: AppEnvironment

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

            Text(viewModel.module.title)
                .zcoolPageTitle(size: 22)

            Text("解锁 \(viewModel.module.paidChapters.count) 章付费深度内容")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)

            // 章节预览(锁标 + 标题列表)
            VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
                ForEach(viewModel.module.paidChapters, id: \.self) { chapter in
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
                BaziTheme.cardSurface,
                in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                    .stroke(BaziTheme.hairline, lineWidth: 0.5)
            )

            Spacer()

            // 失败时显示错误文案(诊断 + UX:避免按钮恢复 idle 让用户以为"没反应")
            if case .failed(let message) = viewModel.state {
                errorCaption(message)
            }

            // CTA:已登录走 purchase,未登录走 AppleSignInButton(Slice 5 决策:强制登录购买)
            if env.accountManager.isLoggedIn {
                PrimaryCTAButton(
                    title: viewModel.displayPriceText,
                    loadingTitle: "处理中…",
                    isLoading: viewModel.state == .purchasing,
                    action: { Task { await viewModel.purchase() } }
                )
            } else {
                // 未登录:登录后 @Observable AccountManager 触发 view 重渲染,
                // 自动切回 PrimaryCTAButton;不需要手动 dismiss / 跳转。
                VStack(spacing: BaziTheme.Spacing.sm) {
                    // 登录失败显式显错(行为对齐 ProfileView accountSection .failed 分支:
                    // 显错 + 保留重试按钮;样式见 errorCaption)。
                    // 不渲染的话 SIWA 失败后 UI 无任何反馈,用户只看到按钮"没反应"。
                    if case .failed(let message) = env.accountManager.state {
                        errorCaption(message)
                    } else {
                        Text("登录后即可购买,已购内容跨设备同步")
                            .font(.caption)
                            .foregroundStyle(BaziTheme.inkMuted)
                            .multilineTextAlignment(.center)
                    }
                    AppleSignInButton(onResult: { result in
                        env.accountManager.handleAuthorization(result)
                    })
                }
            }

            // 法律免责(DESIGN.md 反 AI slop + 命理类审核要求)
            Text("玄学娱乐,理性参考。\n购买即视为同意 Apple 标准用户协议。")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, BaziTheme.Spacing.lg)
        .padding(.bottom, BaziTheme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task { await viewModel.loadProduct() }
    }

    /// 错误文案(购买失败 / 登录失败共用):caption + 凶色 + 居中。
    /// 颜色用 shenshaInauspicious(与 ProfileView 的 destructive 不同,
    /// 跟本 sheet 内既有购买失败文案保持一致)。
    private func errorCaption(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(BaziTheme.shenshaInauspicious)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}
