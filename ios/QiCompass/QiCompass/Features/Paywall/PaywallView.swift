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

            if viewModel.isPurchaseIntercepted {
                // S07 时辰未知拦截态(D6):不展示价格、不展示购买按钮、不加载
                // StoreKit product(purchase 在 VM 层另有守卫,纵深防御)。
                // 水墨克制:一句话 + 占位入口,无红色警示;CTA 一期占位,S10 接线。
                HourUnknownGateNotice(
                    title: L10n.PaywallGate.title,
                    reason: L10n.PaywallGate.reason
                )
                Spacer(minLength: 0)
            } else {
                purchaseBody
            }
        }
        .padding(.horizontal, BaziTheme.Spacing.lg)
        .padding(.bottom, BaziTheme.Spacing.lg)
        .presentationBackground(BaziTheme.cardSurface)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .task { await viewModel.loadProduct() }
    }

    /// 正常付费墙(有时辰用户):与 S07 前现状完全一致(价格/按钮/购买链路零变化)。
    private var purchaseBody: some View {
        VStack(spacing: BaziTheme.Spacing.md) {
            // 水墨孤本(deep-p3):「解」印 + 标题 + 副题
            HStack(spacing: 14) {
                SealStamp(character: "解", size: 34, rotation: -4, stampDelay: 0.45)
                VStack(alignment: .leading, spacing: 5) {
                    Text("解锁余下\(NumeralBadge.numeral(viewModel.module.paidChapters.count))章")
                        .font(BaziFont.display(size: 19))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.ink)
                    Text("一次买断 · 全设备同步")
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, BaziTheme.Spacing.xs)

            // 章节清单:大写数字徽(锁定虚线圆)+ 章名 + dashed hairline 分隔
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.module.paidChapters.enumerated()), id: \.element) { idx, chapter in
                    HStack(spacing: 12) {
                        NumeralBadge(index: idx + 1, locked: true, size: 28)
                        Text(chapter)
                            .font(BaziFont.body(size: 14))
                            .foregroundStyle(BaziTheme.ink)
                        Spacer()
                    }
                    .padding(.vertical, 9)
                    if idx < viewModel.module.paidChapters.count - 1 {
                        Rectangle()
                            .fill(BaziTheme.hairlineDashed)
                            .frame(height: 0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            // 失败时显示错误文案(诊断 + UX:避免按钮恢复 idle 让用户以为"没反应")
            if case .failed(let message) = viewModel.state {
                errorCaption(message)
            }

            // CTA(Slice 5 决策:强制登录购买;Fix#3:登录 = exchange 完成,非仅 SIWA 成功)。
            // exchangeState(@Observable)驱动自动切按钮,不需要手动 dismiss / 跳转:
            // 购买按钮只在 qicompassUserId 落地后出现,与 PurchaseManager 的
            // isAuthenticated gate 同源,消灭"显示可购买、点了却报『请先登录』"死锁。
            // 防御:exchange 进行中 signOut 的竞态下,迟到的 .done 会与 .signedOut 并存,
            // 补 state 判据让该场景走登录区(正常流 .done 必然伴随 .signedIn,零行为变化)。
            if case .signedIn = env.accountManager.state, env.accountManager.exchangeState == .done {
                PrimaryCTAButton(
                    title: viewModel.displayPriceText,
                    loadingTitle: "处理中…",
                    isLoading: viewModel.state == .purchasing,
                    action: { Task { await viewModel.purchase() } }
                )
            } else if case .signedIn = env.accountManager.state {
                // SIWA 成功但账号未就绪(exchange 进行中 / 失败)
                switch env.accountManager.exchangeState {
                case .inFlight:
                    HStack(spacing: BaziTheme.Spacing.sm) {
                        ProgressView()
                            .tint(BaziTheme.ink)
                        Text("正在完成登录…")
                            .font(.caption)
                            .foregroundStyle(BaziTheme.inkMuted)
                    }
                    .frame(maxWidth: .infinity)
                    // 与 AppleSignInButton 同高,登录区切换时 sheet 布局不跳
                    .frame(height: 50)
                case .failed(let message):
                    // exchange 失败:显错 + 重新登录重试(SIWA 已授权过,重登通常无感)
                    VStack(spacing: BaziTheme.Spacing.sm) {
                        errorCaption(message)
                        AppleSignInButton(onResult: { result in
                            env.accountManager.handleAuthorization(result)
                        })
                        GoogleSignInButton {
                            env.accountManager.handleGoogleSignIn()
                        }
                    }
                case .idle, .done:
                    // 防御:signedIn 但 exchangeState 未定义(不变量破坏,正常不应出现)
                    signInPrompt
                }
            } else {
                // 未登录 / SIWA 失败(Fix#1:登录失败显式显错)
                signInPrompt
            }

            // 法律免责(DESIGN.md 反 AI slop + 命理类审核要求)
            Text("玄学娱乐,理性参考。\n购买即视为同意 Apple 标准用户协议。")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .multilineTextAlignment(.center)
                .tracking(1)
        }
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

    /// 未登录态的登录区(中性提示或登录失败显错 + 登录按钮)。
    private var signInPrompt: some View {
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
            GoogleSignInButton {
                env.accountManager.handleGoogleSignIn()
            }
        }
    }
}

// MARK: - S07 时辰未知拦截态组件(付费墙 / 深度解析整拦页 / 合盘对卡共用)

/// 水墨克制拦截表达(DESIGN.md:一句话 + 占位入口,无红色警示)。
///
/// 三处复用,文案由调用方按场景传入(`L10n.PaywallGate`):
/// - `PaywallView` 拦截态(无时辰·日柱确定 → 付费墙位置)
/// - `DeepAnalysisView` 日柱歧义整拦页(免费 2 章亦拦,不进内容页)
/// - `CompatibilityPairListView` 对级拦截卡(任一方无时辰 → 整对拦,免费亦拦)
struct HourUnknownGateNotice: View {
    let title: String
    let reason: String

    /// S10 接线注记:一期 CTA 是占位——点击仅轻提示(不 crash);S10 补时辰
    /// sheet 上线后把 Button action 换成打开 sheet 即闭环(D7 触点 3,转化最高位置)。
    @State private var showAddHourHint = false

    var body: some View {
        VStack(spacing: BaziTheme.Spacing.md) {
            // 「时」印:缺的不是钱,是时辰(朱印仅印章级小元素,符合 DESIGN.md 约束)
            SealStamp(character: "时", size: 34, rotation: -4, stampDelay: 0.2)
            Text(title)
                .font(BaziFont.display(size: 17))
                .tracking(2)
                .foregroundStyle(BaziTheme.ink)
                .multilineTextAlignment(.center)
            Text(reason)
                .font(BaziFont.caption(size: 11.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)

            // CTA 占位:capsule hairline chip 形态(占位不是可完成动作,不做实底 CTA)
            Button {
                HapticEngine.light()
                withAnimation(.easeOut(duration: 0.2)) { showAddHourHint = true }
            } label: {
                Text(L10n.PaywallGate.cta)
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.ink)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
            }
            if showAddHourHint {
                Text(L10n.PaywallGate.ctaHint)
                    .font(.caption2)
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BaziTheme.Spacing.md)
    }
}
