import SwiftUI

/// 生肖反馈屏(onboarding 第 3 屏,终态;提交成功后呈现)。
///
/// 设计事实源:repo 根 `生肖设计决策.md` Q4-Q21 + 2026-08-13 三屏重构 grill。
/// - **时序**(Q4 Z):oneshot 仪式(此屏)+ 低调常驻(ChartHeader 文字 + ProfileView 命主卡)
/// - **布局**(Q11 β → 2026-08-13 Q5 改):hero 压缩 ~140pt + 内容滚动 + CTA 钉底
///   [hero(印章图 + 主/次文字)→ 人格段落 → 好朋友 3 chips → 需磨合 1 chip → 立场微文案]
/// - **主文字**(Q12 iii):`辰 · 龙`(中点分隔,Songti SC display)
/// - **次文字**(Q13 C+ii):`乾造(男) · 庚辰年(2000)`(命理 + 公历双轨)
/// - **好朋友**(2026-08-13 Q3/Q4):六合 1 + 三合 2 = 3 个生肖 chip,墨青 jade(吉神色)
/// - **需磨合**(2026-08-13 Q4):六冲 1 个生肖 chip,中性灰(不用朱砂红,避免恐吓)
/// - **人格**(2026-08-13 Q6):12 生肖静态善意正面画像,1-2 句,ZodiacHelper.personalityText 取
/// - **CTA**(Q14 α):手动点击「查看今日运势」→ onComplete
/// - **动效**(Q15 B):盖章动效 — scale 0.8 → 1.05 (spring overshoot) → 1.0 + 朱砂光晕扩散
///   + 文字/内容错峰淡入;落定瞬间触发 HapticEngine.medium() 仪式感"砰"
/// - **暗色**(Q18 A):zodiac asset 走 Asset Catalog appearance set,系统自动选 light/dark variant
/// - **失败路径**(Q19 A):此 view 不处理错误,数据由调用方保证完整(字段缺失视为开发期 bug)
///
/// **数据来源**:调用方(OnboardingView)从后端 `BaziResponse.yearBranchZodiac`(英文 asset name,
/// 如 `Dragon`)+ `year_branch_friends` / `year_branch_clash`(复用 branch_relations.py)
/// + `pillars.year.ganZhi` + `pillars.year.zhi` 推导参数。
/// 后端 `year_branch_zodiac` 由 `lunar_python` 按立春算,自动修复立春边界 bug。
struct ZodiacRevealView: View {
    /// 本命生肖英文名(如 "Dragon")。asset = "Zodiac_\(zodiac)",人格文案按此取。
    let zodiac: String
    /// 主文字(如 `辰 · 龙`)。
    let mainLabel: String
    /// 次文字(如 `乾造(男) · 庚辰年(2000)`)。
    let subLabel: String
    /// 好朋友英文生肖名(六合 1 + 三合 2 = 3 个,后端算)。
    let friendZodiacs: [String]
    /// 需磨合英文生肖名(六冲 1 个,后端算)。
    let clashZodiac: String
    /// CTA 点击回调(进今日运势 tab)。
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - 动画 state(初始态 = 入场前)

    @State private var stampOpacity: Double = 0
    @State private var stampScale: CGFloat = 0.8
    @State private var haloOpacity: Double = 0
    @State private var haloScale: CGFloat = 0.85
    @State private var textOpacity: Double = 0
    @State private var ctaOpacity: Double = 0

    // MARK: - 视觉尺寸(2026-08-13 Q5:hero 压缩 ~140pt,内容滚动,CTA 钉底)

    /// 印章图尺寸。2026-08-13 从 280pt 压缩到 140pt(为下方人格/好友内容让出空间)。
    private let stampSize: CGFloat = 140
    /// 光晕直径,比印章大一圈让扩散可见。
    private let haloSize: CGFloat = 160
    /// chip 内生肖小图尺寸。
    private let chipImageSize: CGFloat = 28

    var body: some View {
        ZStack {
            BaziTheme.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: BaziTheme.Spacing.lg) {
                        stampComposition
                            .padding(.top, BaziTheme.Spacing.xxl)

                        // MARK: 主/次文字(Q12 iii + Q13 C+ii)
                        VStack(spacing: BaziTheme.Spacing.xs) {
                            Text(mainLabel)
                                .font(BaziFont.display(size: 40))
                                .foregroundStyle(BaziTheme.ink)
                            Text(subLabel)
                                .font(BaziFont.body(size: 15))
                                .foregroundStyle(BaziTheme.inkMuted)
                        }
                        .opacity(textOpacity)

                        // MARK: 人格段落(2026-08-13 Q6:无标题,紧接主标)
                        Text(ZodiacHelper.personalityText(forZodiac: zodiac))
                            .font(BaziFont.body(size: 15))
                            .foregroundStyle(BaziTheme.ink)
                            .lineSpacing(6)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(textOpacity)

                        // MARK: 好朋友(2026-08-13 Q3/Q4:六合+三合,jade 吉神色)
                        section(
                            title: L10n.Onboarding.revealFriendsTitle,
                            content: {
                                chipRow(friendZodiacs, tint: BaziTheme.jade)
                            }
                        )
                        .opacity(textOpacity)

                        // MARK: 需磨合(2026-08-13 Q4:六冲,中性灰不恐吓)
                        section(
                            title: L10n.Onboarding.revealClashTitle,
                            content: {
                                zodiacChip(clashZodiac, tint: BaziTheme.inkMuted)
                            }
                        )
                        .opacity(textOpacity)

                        // MARK: 立场微文案(Q1 拆分下沉:收到结论那一刻给可信度背书)
                        VStack(spacing: BaziTheme.Spacing.md) {
                            Rectangle()
                                .fill(BaziTheme.hairline)
                                .frame(height: 0.5)
                            Text(L10n.Onboarding.revealStanceLine)
                                .font(BaziFont.caption(size: 12))
                                .foregroundStyle(BaziTheme.inkMuted)
                                .multilineTextAlignment(.center)
                        }
                        .opacity(textOpacity)
                        .padding(.top, BaziTheme.Spacing.sm)
                    }
                    .padding(.horizontal, BaziTheme.Spacing.xl)
                    .padding(.bottom, BaziTheme.Spacing.lg)
                }

                // MARK: CTA(Q14 α,朱砂手动按钮,钉底部不进滚动)
                Button(action: {
                    HapticEngine.medium()
                    onComplete()
                }) {
                    Text(L10n.Onboarding.revealCTA)
                        .font(BaziFont.button())
                        .foregroundStyle(BaziTheme.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BaziTheme.Spacing.md)
                        .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }
                .accessibilityHint("查看你的今日运势")
                .opacity(ctaOpacity)
                .padding(.horizontal, BaziTheme.Spacing.xl)
                .padding(.top, BaziTheme.Spacing.sm)
                .padding(.bottom, 24)
            }
        }
        .task {
            await playStampAnimation()
        }
    }

    // MARK: - 印章组合(圆环生肖图 + 朱砂光晕)

    /// 印章 = 圆环生肖图 + 朱砂光晕。光晕在印章落定时从中心扩散消散,
    /// 呼应中国传统印章的"盖戳"物理动作。
    private var stampComposition: some View {
        ZStack {
            // 朱砂光晕(Q15:Circle stroke + scale 扩散 + opacity 消散)
            Circle()
                .stroke(BaziTheme.cinnabar.opacity(0.5), lineWidth: 1)
                .frame(width: haloSize, height: haloSize)
                .scaleEffect(haloScale)
                .opacity(haloOpacity)

            // 圆环生肖图(Q8/Q18:细线 stroke + 圆环外框,asset 已含外观)
            // accessibilityLabel 不加在图上:下方 Text(mainLabel) 已被 VoiceOver 读出,
            // 图再贴同名 label 会"辰 龙"读两次。整个组合对 VoiceOver 隐藏,主/次文字负责朗读。
            Image("Zodiac_\(zodiac)")
                .resizable()
                .scaledToFit()
                .frame(width: stampSize, height: stampSize)
                .scaleEffect(stampScale)
                .opacity(stampOpacity)
        }
        .accessibilityElement(children: .ignore)
        .frame(width: haloSize + 40, height: haloSize + 40)
    }

    // MARK: - 区块(chip 行标题)

    /// 小标题 + 内容。标题 caption semibold inkMuted,低调不抢主标。
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: BaziTheme.Spacing.sm) {
            Text(title)
                .font(BaziFont.caption(size: 12))
                .fontWeight(.semibold)
                .foregroundStyle(BaziTheme.inkMuted)
            content()
        }
    }

    // MARK: - 生肖 chip(小图 + 名)

    /// chip 行:优先横排,放不下(英文长名 × 窄屏)降级竖排居中。
    /// ViewThatFits 是系统内置,不引入新依赖。
    private func chipRow(_ names: [String], tint: Color) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: BaziTheme.Spacing.sm) {
                ForEach(names, id: \.self) { zodiacChip($0, tint: tint) }
            }
            VStack(spacing: BaziTheme.Spacing.sm) {
                ForEach(names, id: \.self) { zodiacChip($0, tint: tint) }
            }
        }
    }

    /// Capsule chip(设计系统:Capsule 只留给 chip)。
    /// 好朋友 → jade(吉神色);需磨合 → inkMuted(中性,不恐吓)。
    private func zodiacChip(_ name: String, tint: Color) -> some View {
        HStack(spacing: BaziTheme.Spacing.sm) {
            Image("Zodiac_\(name)")
                .resizable()
                .scaledToFit()
                .frame(width: chipImageSize, height: chipImageSize)
            Text(ZodiacHelper.displayName(forZodiac: name))
                .font(BaziFont.body(size: 14))
                .fontWeight(.medium)
                .foregroundStyle(BaziTheme.ink)
        }
        .padding(.horizontal, BaziTheme.Spacing.md)
        .padding(.vertical, BaziTheme.Spacing.sm)
        .background(tint.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    // MARK: - 盖章动效(Q15 B)

    /// 时序(总 ~1.15s):
    /// 1. t=0      — 印章 scale 0.8 + opacity 0;光晕 scale 0.85 + opacity 0
    /// 2. t=0-0.25s — 印章 spring 入场到 scale 1.05(dampingFraction=0.55 自然 overshoot)+ opacity 1;
    ///                光晕 opacity 0.6 显现
    /// 3. t=0.25s   — HapticEngine.medium() 仪式感"砰" + 印章开始落定到 1.0;
    ///                光晕开始扩散 scale 1.4 + 消散 opacity 0
    /// 4. t=0.55-0.85s — 主/次文字 + 内容区(人格/好友/微文案)淡入
    /// 5. t=0.85-1.15s — CTA 淡入
    ///
    /// **取消语义**:`.task` 在 view disappear 时被取消,`Task.sleep` 抛 `CancellationError`。
    /// 用 `sleepOrCancel` 显式捕获:返回 false 表示被取消,直接 return 后续 phase 不执行。
    /// 此时 view 已 disappear,state 停在中间态无视觉影响(避免静默吞异常,符合 CLAUDE.md)。
    ///
    /// **Reduce Motion**:跳过 spring / 错峰,所有元素直接显示(duration 压到 0.15s 仅做 opacity 过渡)。
    private func playStampAnimation() async {
        guard !reduceMotion else {
            // Reduce Motion:直接可见,无动效
            stampOpacity = 1
            stampScale = 1
            textOpacity = 1
            ctaOpacity = 1
            // 光晕仍然闪一下作为印章语义提示,但极短
            withAnimation(.easeInOut(duration: 0.15)) {
                haloOpacity = 0.6
            }
            if await !sleepOrCancel(.milliseconds(150)) { return }
            withAnimation(.easeInOut(duration: 0.15)) {
                haloOpacity = 0
            }
            return
        }

        // Phase 1:印章 spring 入场(0.8 → 1.05 overshoot)+ 光晕显现
        withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) {
            stampScale = 1.05
            stampOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.2)) {
            haloOpacity = 0.6
        }

        if await !sleepOrCancel(.milliseconds(280)) { return }

        // Phase 2:落定 + 仪式触感 + 光晕扩散消散
        HapticEngine.medium()
        withAnimation(.easeOut(duration: 0.15)) {
            stampScale = 1.0
        }
        withAnimation(.easeOut(duration: 0.3)) {
            haloScale = 1.4
            haloOpacity = 0
        }

        if await !sleepOrCancel(.milliseconds(300)) { return }

        // Phase 3:主/次文字 + 内容区(人格/好友/微文案)淡入
        withAnimation(.easeOut(duration: 0.3)) {
            textOpacity = 1.0
        }

        if await !sleepOrCancel(.milliseconds(300)) { return }

        // Phase 4:CTA 淡入
        withAnimation(.easeOut(duration: 0.3)) {
            ctaOpacity = 1.0
        }
    }

    /// 显式处理 `Task.sleep` 的 `CancellationError`。
    /// 返回 true = 正常睡完,false = 被取消(CLAUDE.md "错误显式传播":不静默吞,由调用方决策)。
    private func sleepOrCancel(_ duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            // 唯一抛出的是 CancellationError(.task 被 view disappear 取消)
            return false
        }
    }
}

// MARK: - Preview

#Preview {
    ZodiacRevealView(
        zodiac: "Dragon",
        mainLabel: "辰 · 龙",
        subLabel: "乾造(男) · 庚辰年(2000)",
        friendZodiacs: ["Rooster", "Rat", "Monkey"],
        clashZodiac: "Dog",
        onComplete: { print("onComplete") }
    )
}

#Preview("Dark Mode") {
    ZodiacRevealView(
        zodiac: "Dragon",
        mainLabel: "辰 · 龙",
        subLabel: "乾造(男) · 庚辰年(2000)",
        friendZodiacs: ["Rooster", "Rat", "Monkey"],
        clashZodiac: "Dog",
        onComplete: { print("onComplete") }
    )
    .preferredColorScheme(.dark)
}
