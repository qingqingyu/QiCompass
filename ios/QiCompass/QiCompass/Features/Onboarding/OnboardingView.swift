import SwiftUI

/// 首启动 onboarding sheet(DESIGN.md §现代东方极简 · 宋瓷气质)。
///
/// 4 页滑动:
/// 1. 欢迎页(产品名 + memorable thing)
/// 2. 产品姿态(4 条核心承诺,区别于算命软件)
/// 3. 数据归属(4 条隐私说明)
/// 4. 开始排盘(CTA)
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
    }
}

// MARK: - Shared bullet row

/// Onboarding 通用 bullet 行(圆点 + 标题 + 说明)。
/// Stance 页传 cinnabar,Privacy 页传 jade,保持视觉语义区分。
private struct OnboardingBulletRow: View {
    let color: Color
    let title: String
    let desc: String

    var body: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.xs) {
            HStack(spacing: BaziTheme.Spacing.sm) {
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                Text(title)
                    .font(BaziFont.body().weight(.semibold))
                    .foregroundStyle(BaziTheme.ink)
            }
            Text(desc)
                .font(BaziFont.caption())
                .foregroundStyle(BaziTheme.inkMuted)
                .padding(.leading, BaziTheme.Spacing.md)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    var body: some View {
        VStack(spacing: BaziTheme.Spacing.xl) {
            Spacer()

            // 朱砂印章式装饰
            ZStack {
                Circle()
                    .fill(BaziTheme.cinnabarSoft)
                    .frame(width: 120, height: 120)
                Text("玄")
                    .font(BaziFont.display(size: 56))
                    .foregroundStyle(BaziTheme.cinnabar)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("玄机问道印章")

            VStack(spacing: BaziTheme.Spacing.sm) {
                Text("玄机问道")
                    .font(BaziFont.display(size: 40))
                    .foregroundStyle(BaziTheme.ink)
                Text("QICOMPASS")
                    .font(BaziFont.caption(size: 11))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .tracking(6)
            }

            Text("一款克制的八字研究工具")
                .font(BaziFont.body())
                .foregroundStyle(BaziTheme.inkMuted)

            Spacer()

            Text("专业不忽悠,不像算命软件")
                .font(BaziFont.display(size: 17, weight: .medium))
                .foregroundStyle(BaziTheme.cinnabar)
                .padding(.bottom, 60)
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
    }
}

// MARK: - Page 2: Stance

private struct StancePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.lg) {
            Spacer()

            Text("不是算命软件")
                .font(BaziFont.display(size: 28))
                .foregroundStyle(BaziTheme.ink)

            VStack(alignment: .leading, spacing: BaziTheme.Spacing.lg) {
                OnboardingBulletRow(
                    color: BaziTheme.cinnabar,
                    title: "确定性排盘",
                    desc: "后端 lunar_python 引擎,同一输入永远同一输出"
                )
                OnboardingBulletRow(
                    color: BaziTheme.cinnabar,
                    title: "规则引擎给喜忌",
                    desc: "扶抑法 + 调候法 + 从格检测,LLM 只润色话术,不自行推断"
                )
                OnboardingBulletRow(
                    color: BaziTheme.cinnabar,
                    title: "从格诚实降级",
                    desc: "命中从格特征时,喜忌留空,LLM 明确告知,不编造"
                )
                OnboardingBulletRow(
                    color: BaziTheme.cinnabar,
                    title: "格局 v1 不硬分",
                    desc: "用「命局呈现××倾向」模糊叙事,不给正官格 / 偏印格等硬分类"
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
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.lg) {
            Spacer()

            Text("数据归属")
                .font(BaziFont.display(size: 28))
                .foregroundStyle(BaziTheme.ink)

            VStack(alignment: .leading, spacing: BaziTheme.Spacing.lg) {
                OnboardingBulletRow(
                    color: BaziTheme.jade,
                    title: "本地存储",
                    desc: "命盘数据走 SwiftData,存在你的设备上"
                )
                OnboardingBulletRow(
                    color: BaziTheme.jade,
                    title: "AI 解读有缓存",
                    desc: "客户端 + 后端 SQLite 两级缓存,prompt 改版自动失效"
                )
                OnboardingBulletRow(
                    color: BaziTheme.jade,
                    title: "API key 不进客户端",
                    desc: "所有排盘 + AI 解读走后端,iOS App 不持有密钥"
                )
                OnboardingBulletRow(
                    color: BaziTheme.jade,
                    title: "不做云同步(v1)",
                    desc: "无账号系统,数据不离开本设备"
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

            // 朱砂印章式装饰(与 WelcomePage 呼应,收束 onboarding)
            ZStack {
                Circle()
                    .fill(BaziTheme.cinnabarSoft)
                    .frame(width: 120, height: 120)
                Text("始")
                    .font(BaziFont.display(size: 56))
                    .foregroundStyle(BaziTheme.cinnabar)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("始字印章,象征开始排盘")

            VStack(spacing: BaziTheme.Spacing.md) {
                Text("开始你的第一次排盘")
                    .font(BaziFont.display(size: 24))
                    .foregroundStyle(BaziTheme.ink)
                Text("填写出生信息,深度解析会自动生成。")
                    .font(BaziFont.body(size: 15))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button(action: onComplete) {
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
