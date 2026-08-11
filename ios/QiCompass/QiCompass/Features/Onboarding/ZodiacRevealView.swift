import SwiftUI

/// 生肖反馈屏(B2 流提交成功后呈现的过渡屏)。
///
/// 设计事实源:repo 根 `生肖设计决策.md` Q4-Q21。
/// - **时序**(Q4 Z):oneshot 仪式(此屏)+ 低调常驻(ChartHeader 文字 + ProfileView 命主卡)
/// - **布局**(Q11 β):印章图 + 主文字 + 次文字 + 朱砂 CTA
/// - **主文字**(Q12 iii):`辰 · 龙`(中点分隔,Songti SC display)
/// - **次文字**(Q13 C+ii):`乾造(男) · 庚辰年(2000)`(命理 + 公历双轨)
/// - **CTA**(Q14 α):手动点击 `查看今日运势` → onComplete
/// - **动效**(Q15 B):盖章动效 — scale 0.8 → 1.05 (spring overshoot) → 1.0 + 朱砂光晕扩散
///   + 文字/CTA 错峰淡入,总时长 ~1.15s;落定瞬间触发 HapticEngine.medium() 仪式感"砰"
/// - **暗色**(Q18 A):zodiacAssetName 走 Asset Catalog appearance set,系统自动选 light/dark variant
/// - **失败路径**(Q19 A):此 view 不处理错误,数据由调用方保证完整(字段缺失视为开发期 bug)
///
/// **数据来源**:调用方(`FirstLaunchBirthFormView`)从 `BaziResponse.pillars.year.zhi`
/// 经 `ZodiacCalculator` 推导三个参数(commit `1b683f6` 阶段 2 数据层接通后,自动修复
/// 立春边界 bug;原阶段 4 mock 公历年 idx 算法已删除)。
struct ZodiacRevealView: View {
    /// 生肖图 asset name(如 `Zodiac_Dragon`)。Asset Catalog appearance set 自动选 light/dark variant。
    let zodiacAssetName: String
    /// 主文字(如 `辰 · 龙`)。
    let mainLabel: String
    /// 次文字(如 `乾造(男) · 庚辰年(2000)`)。
    let subLabel: String
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

    // MARK: - 视觉尺寸(Q11 β 布局,留白驱动)

    /// 印章图尺寸。spec 阶段 4 checklist 锁定 280pt。
    private let stampSize: CGFloat = 280
    /// 光晕直径,比印章大一圈让扩散可见。
    private let haloSize: CGFloat = 320

    var body: some View {
        ZStack {
            BaziTheme.paper.ignoresSafeArea()

            VStack(spacing: BaziTheme.Spacing.xl) {
                Spacer()

                stampComposition

                // MARK: 主文字(Q12 iii)
                Text(mainLabel)
                    .font(BaziFont.display(size: 44))
                    .foregroundStyle(BaziTheme.ink)
                    .opacity(textOpacity)

                // MARK: 次文字(Q13 C+ii)
                Text(subLabel)
                    .font(BaziFont.body(size: 16))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .opacity(textOpacity)

                Spacer()

                // MARK: CTA(Q14 α,朱砂手动按钮)
                Button(action: {
                    HapticEngine.medium()
                    onComplete()
                }) {
                    Text("查看今日运势")
                        .font(BaziFont.button())
                        .foregroundStyle(BaziTheme.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, BaziTheme.Spacing.md)
                        .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }
                .accessibilityHint("查看你的今日运势")
                .opacity(ctaOpacity)
                .padding(.horizontal, BaziTheme.Spacing.xl)
                .padding(.bottom, 60)
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
            Image(zodiacAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: stampSize, height: stampSize)
                .scaleEffect(stampScale)
                .opacity(stampOpacity)
        }
        .accessibilityElement(children: .ignore)
        .frame(width: haloSize + 40, height: haloSize + 40)
    }

    // MARK: - 盖章动效(Q15 B)

    /// 时序(总 ~1.15s):
    /// 1. t=0      — 印章 scale 0.8 + opacity 0;光晕 scale 0.85 + opacity 0
    /// 2. t=0-0.25s — 印章 spring 入场到 scale 1.05(dampingFraction=0.55 自然 overshoot)+ opacity 1;
    ///                光晕 opacity 0.6 显现
    /// 3. t=0.25s   — HapticEngine.medium() 仪式感"砰" + 印章开始落定到 1.0;
    ///                光晕开始扩散 scale 1.4 + 消散 opacity 0
    /// 4. t=0.55-0.85s — 主/次文字淡入
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

        // Phase 3:主/次文字淡入
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
        zodiacAssetName: "Zodiac_Dragon",
        mainLabel: "辰 · 龙",
        subLabel: "乾造(男) · 庚辰年(2000)",
        onComplete: { print("onComplete") }
    )
}

#Preview("Dark Mode") {
    ZodiacRevealView(
        zodiacAssetName: "Zodiac_Dragon",
        mainLabel: "辰 · 龙",
        subLabel: "乾造(男) · 庚辰年(2000)",
        onComplete: { print("onComplete") }
    )
    .preferredColorScheme(.dark)
}
