import SwiftUI

/// AI 命书区(方案 §一 InterpretationSection + DESIGN.md §Color)。
///
/// 纯展示组件:接受 let 参数(状态 + 回调),不依赖具体 ViewModel。
/// 与 CompatibilityInterpretationSection / DailyInterpretationSection 模式一致。
///
/// 双轨渲染(Stage 7c 引入):
/// - v1 模式(默认推荐):`v1ModuleStates != nil` → ForEach ModuleID.allCases
///   渲染 8 个 ModuleCardView,服务 v1 prompt 系统模块化路径
/// - 老路径(legacy):`v1ModuleStates == nil` → switch effectiveState 渲染单文本态,
///   服务合盘 / 每日运势 / 未升级老 bazi_deep 路径(向后兼容)
///
/// 子状态机(老路径):
/// - idle:显示"生成命书"CTA(remaining > 0 保证;remaining = 0 由 effectiveState 转为 dailyLimitReached)
/// - fetching:ProgressView + 文案
/// - ok(text, cached):命书文本 + cached 标记 + 重新生成
/// - failed(message):错误 + 重试
/// - dailyLimitReached:达上限态(显示 DailyLimitReachedView)
struct InterpretationSection: View {
    let interpretState: InterpretState
    let remainingReads: Int
    let nextReset: Date
    let onGenerate: () -> Void
    let onRetry: () -> Void
    /// M3c 新增:点击付费章节锁标的"解锁"CTA 时触发,由父 View 装配 PaywallView sheet。
    var onShowPaywall: () -> Void = {}

    // Stage 7c:v1 prompt 系统模块化状态(可选,默认 nil 走老路径)
    // 不为 nil 时,本 section 渲染 8 个 ModuleCardView(ForEach ModuleID.allCases)
    // 老路径(okFree/okPaid/lockedPaid 等)只在 v1ModuleStates == nil 时走(向后兼容)
    var v1ModuleStates: [ModuleID: ModuleState]? = nil
    /// v1 模式:用户点 ModuleCardView 的"开始 M0 分析"CTA 时触发全链路编排。
    var onGenerateV1: () -> Void = {}
    /// v1 模式:用户点 ModuleCardView 单模块"重试"CTA 时触发单模块重跑。
    var onRetryV1: (ModuleID) -> Void = { _ in }
    /// v1 模式:用户点 ModuleCardView 的"提供输入"CTA 时触发(M4/M5 .needsInput)。
    /// ResultView 接收后弹 HealthInputForm / WealthInputForm sheet(Stage 8)。
    var onProvideInput: (ModuleID) -> Void = { _ in }

    /// 有效 interpretState:idle + remaining=0 时自动转为 dailyLimitReached(消除 idle case 的 if/else 判断)。
    private var effectiveState: InterpretState {
        if case .idle = interpretState, remainingReads <= 0 {
            return .dailyLimitReached(nextReset: nextReset)
        }
        return interpretState
    }

    var body: some View {
        // 水墨孤本(deep-p1):开放布局卷轴,kicker 小标 + hairline 分隔
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI 命书")
                    .font(BaziFont.caption(size: 10))
                    .tracking(4)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Spacer()
                Text("今日剩余 \(remainingReads) 次")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            // Stage 7c:v1 模式优先(若调用方传了 v1ModuleStates)
            // 老路径只在 v1ModuleStates == nil 时走(向后兼容合盘/每日运势)
            if let v1States = v1ModuleStates {
                v1ModuleList(v1States)
            } else {
                legacyInterpretationBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - v1 模块列表(Stage 7c)

    @ViewBuilder
    private func v1ModuleList(_ v1States: [ModuleID: ModuleState]) -> some View {
        // 达上限时不渲染模块卡片(同老路径逻辑,生成按钮禁用)
        if case .dailyLimitReached(let nextReset) = effectiveState {
            DailyLimitReachedView(nextReset: nextReset)
        } else {
            // 捌章卷轴:模块行之间 hairline 分隔(deep-p1-modules.html)
            VStack(spacing: 0) {
                ForEach(Array(ModuleID.allCases.enumerated()), id: \.element) { idx, module in
                    ModuleCardView(
                        module: module,
                        state: v1States[module] ?? .pending,
                        onGenerate: onGenerateV1,
                        onRetry: { onRetryV1(module) },
                        onUnlock: onShowPaywall,
                        onProvideInput: { onProvideInput(module) }
                    )
                    if idx < ModuleID.allCases.count - 1 {
                        Rectangle()
                            .fill(BaziTheme.hairline)
                            .frame(height: 0.5)
                    }
                }
            }
        }
    }

    // MARK: - 老路径(legacy,合盘/每日运势/未升级 bazi_deep 继续)

    @ViewBuilder
    private var legacyInterpretationBody: some View {
        switch effectiveState {
        case .idle:
            PrimaryCTAButton(
                title: "生成命书",
                loadingTitle: "生成命书中…",
                isLoading: false,
                action: onGenerate
            )

        case .fetching:
            PrimaryCTAButton(
                title: "生成命书",
                loadingTitle: "生成命书中…",
                isLoading: true,
                action: {}
            )

        case .okFree(let text, let cached):
            // 免费用户:显示免费 2 章 + 付费 8 章锁标引导购买(M3c 关键设计)
            // 用户看完 2 章感知"AI 真有料",自然看到下方 8 章被锁,点解锁触发 PaywallView
            Text(MarkdownSanitizer.rendered(text))
                .bodySerifText()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fadeIn()
            if cached {
                Text("◎ 缓存命中(不消耗次数)")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            // 2026-08-01 grill-me 决策 #15:不做"再生成"按钮。
            // 失败重试走 .failed case 的"重试"按钮(CLAUDE.md "AI 失败重试不消耗次数"原则)。
            Divider()
                .background(BaziTheme.hairline)
            // 2026-08-23 对齐 bazi_deep_paid v5(8 章命书框架,此前还写老 5 章)
            PaidChaptersLockView(
                previewChapters: ["命盘", "日元", "五行", "格局倾向",
                                  "事业与财富", "婚姻感情", "学习成长", "身体健康"],
                title: "深度命书·付费章节",
                ctaTitle: "解锁深度命书",
                onUnlock: onShowPaywall
            )

        case .okPaid(let text, let cached):
            // 已购买用户:直接显示付费 5 章内容,不显示锁标
            Text(MarkdownSanitizer.rendered(text))
                .bodySerifText()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fadeIn()
            if cached {
                Text("◎ 缓存命中(不消耗次数)")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            // 2026-08-01 grill-me 决策 #15:不做"再生成"按钮。
        case .lockedPaid(let previewChapters):
            PaidChaptersLockView(
                previewChapters: previewChapters,
                title: "深度命书·付费章节",
                ctaTitle: "解锁深度命书",
                onUnlock: onShowPaywall
            )

        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(BaziTheme.shenshaInauspicious)
            Button("重试", action: onRetry)
                .font(.caption.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)

        case .dailyLimitReached(let nextReset):
            DailyLimitReachedView(nextReset: nextReset)
            // 达上限:**禁用生成按钮、不显示重试**(方案 step 4)
        }
    }
}
