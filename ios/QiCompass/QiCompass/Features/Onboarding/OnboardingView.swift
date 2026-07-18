import SwiftUI

/// 首启动 onboarding sheet(DESIGN.md §现代东方极简 · 宋瓷气质)。
///
/// 2026-07-18 重写方向(用户决策):**克制安静 + 东方质感**。
/// - 文案从"工程师腔"改为"用户腔":不堆术语,讲"对你意味着什么"
/// - 视觉砍掉 4 行 bullet 圆点 → 改 3 行"留白叙事"(无圆点,主+副两行)
/// - 印章作为视觉记忆点(Welcome + Start),中间两页只留标题 + 留白
/// - 不在 onboarding 提付费(让用户进入 App 后自己发现锁标)
///
/// 4 页滑动:
/// 1. 欢迎页(印章「玄」+ 产品名 + 一句话定调)
/// 2. 立场页(不是算命软件 — 3 条留白叙事)
/// 3. 隐私页(数据归属 — 3 条留白叙事)
/// 4. 开始页(印章「始」+ CTA)
///
/// 首启动由 RootTabView 检测 `@AppStorage("hasSeenOnboarding") = false` 弹出。
/// 完成后设 true,后续启动不再弹。Sheet 禁止下滑 dismiss(必须点 CTA)。
struct OnboardingView: View {
    /// 完成回调(由 RootTabView 设 hasSeenOnboarding = true)。
    let onComplete: () -> Void

    @State private var currentPage = 0

    var body: some View {
        TabView(selection: $currentPage) {
            WelcomePage().tag(0)
            StancePage().tag(1)
            PrivacyPage().tag(2)
            StartPage(onComplete: onComplete).tag(3)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))
        .background(BaziTheme.paper)
        .tint(BaziTheme.cinnabar)
        .onAppear {
            // 首启 onboarding 呈现的入口日志,用于排查"没弹"问题
            AppLogger.app.info("OnboardingView.onAppear 首启动引导呈现")
        }
        .onChange(of: currentPage) { _, newPage in
            // 翻页日志:排查"卡在第 N 页 / 用户中途退出"等问题
            let pageNames = ["Welcome", "Stance", "Privacy", "Start"]
            let name = newPage < pageNames.count ? pageNames[newPage] : "Unknown"
            AppLogger.app.info("OnboardingView 翻页 currentPage=\(newPage, privacy: .public) name=\(name, privacy: .public)")
        }
    }
}

// MARK: - Shared: 朱砂印章

/// 朱砂印章:淡底圆 + 朱砂细圈 + Songti SC 单字。
/// 用作 Welcome / Start 页的视觉记忆点(DESIGN.md §现代东方极简装饰核心)。
/// 细圈 0.5pt hairline 与 DESIGN.md §Border 一致,不加阴影。
private struct SealStamp: View {
    let character: String
    var size: CGFloat = 96

    var body: some View {
        ZStack {
            Circle()
                .fill(BaziTheme.cinnabarSoft)
                .frame(width: size, height: size)
            Circle()
                .stroke(BaziTheme.cinnabar.opacity(0.35), lineWidth: 0.5)
                .frame(width: size - 10, height: size - 10)
            Text(character)
                .font(BaziFont.display(size: size * 0.46))
                .foregroundStyle(BaziTheme.cinnabar)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared: 留白叙事行

/// 一句一行,无 bullet 圆点,无 title+desc 双行结构。
/// 主句 Songti SC Medium + 浓墨;副句 PingFang SC + 灰墨。
/// spacing 驱动留白节奏,符合"克制安静"。
private struct BreathLine: View {
    let main: String
    var sub: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.xs) {
            Text(main)
                .font(BaziFont.display(size: 19, weight: .medium))
                .foregroundStyle(BaziTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if let sub {
                Text(sub)
                    .font(BaziFont.caption(size: 13))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: BaziTheme.Spacing.xl) {
            Spacer()

            SealStamp(character: "玄", size: 108)
                .accessibilityLabel("玄机问道印章")

            VStack(spacing: BaziTheme.Spacing.sm) {
                Text("玄机问道")
                    .font(BaziFont.display(size: 36))
                    .foregroundStyle(BaziTheme.ink)
                Text("QICOMPASS")
                    .font(BaziFont.caption(size: 10))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .tracking(4)
            }

            // 副标题克制,不用 cinnabar 红字(原"专业不忽悠"过刺眼)
            Text("读懂你的命局,不夸大,不忽悠")
                .font(BaziFont.body(size: 15))
                .foregroundStyle(BaziTheme.inkMuted)

            Spacer()
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
    }
}

// MARK: - Page 2: Stance

private struct StancePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.xxl) {
            Spacer()

            Text("不是算命软件")
                .font(BaziFont.display(size: 28))
                .foregroundStyle(BaziTheme.ink)

            VStack(alignment: .leading, spacing: BaziTheme.Spacing.xl) {
                BreathLine(
                    main: "同一组生辰,排出来的盘永远一样",
                    sub: "后端规则引擎,不随机,不玄学"
                )
                BreathLine(
                    main: "喜忌由规则判定,AI 只润色话术",
                    sub: "不交给 AI 现场猜,避免流派争议"
                )
                BreathLine(
                    main: "遇特殊命局,诚实说「不下结论」",
                    sub: "不编造,不牵强附会"
                )
            }

            Spacer()
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
    }
}

// MARK: - Page 3: Privacy

private struct PrivacyPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.xxl) {
            Spacer()

            Text("数据在你设备上")
                .font(BaziFont.display(size: 28))
                .foregroundStyle(BaziTheme.ink)

            VStack(alignment: .leading, spacing: BaziTheme.Spacing.xl) {
                BreathLine(
                    main: "命盘只存在你的手机上,不上传",
                    sub: "没有账号,没有云同步"
                )
                BreathLine(
                    main: "AI 解读经我们的服务器",
                    sub: "密钥保管在后端,不进客户端"
                )
                BreathLine(
                    main: "不跟踪,不画像,不卖数据",
                    sub: "v1 范围内不做用户行为分析"
                )
            }

            Spacer()
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
    }
}

// MARK: - Page 4: Start

private struct StartPage: View {
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: BaziTheme.Spacing.xl) {
            Spacer()

            SealStamp(character: "始", size: 108)
                .accessibilityLabel("始字印章,象征开始排盘")

            VStack(spacing: BaziTheme.Spacing.md) {
                Text("开始你的第一次排盘")
                    .font(BaziFont.display(size: 26))
                    .foregroundStyle(BaziTheme.ink)
                Text("填写出生信息,生成你的第一份命书。")
                    .font(BaziFont.body(size: 14))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button(action: {
                // 用户主动点 CTA 完成,记录日志(区别于下滑 dismiss,后者被禁)
                AppLogger.app.info("StartPage CTA 点击 → 触发 onComplete")
                onComplete()
            }) {
                Text("开始排盘")
                    .font(BaziFont.button())
                    .foregroundStyle(BaziTheme.paper)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, BaziTheme.Spacing.md)
                    .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
            }
            .accessibilityHint("点击开始你的第一次排盘,填写出生信息")
            .padding(.bottom, 60)
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
    }
}
