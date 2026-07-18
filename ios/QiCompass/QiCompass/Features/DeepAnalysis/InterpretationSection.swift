import SwiftUI

/// AI 命书区(方案 §一 InterpretationSection + DESIGN.md §Color)。
///
/// 纯展示组件:接受 let 参数(状态 + 回调),不依赖具体 ViewModel。
/// 与 CompatibilityInterpretationSection / DailyInterpretationSection 模式一致。
///
/// 子状态机:
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

    /// 有效 interpretState:idle + remaining=0 时自动转为 dailyLimitReached(消除 idle case 的 if/else 判断)。
    private var effectiveState: InterpretState {
        if case .idle = interpretState, remainingReads <= 0 {
            return .dailyLimitReached(nextReset: nextReset)
        }
        return interpretState
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI 命书")
                    .zcoolCardTitle()
                Spacer()
                Text("今日剩余 \(remainingReads) 次")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

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

            case .ok(let text, let cached):
                Text(text)
                    .bodySerifText()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fadeIn()
                HStack {
                    if cached {
                        Text("◎ 缓存命中(不消耗次数)")
                            .font(.caption2)
                            .foregroundStyle(BaziTheme.inkMuted)
                    }
                    Spacer()
                    Button("重新生成", action: onRetry)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.cinnabar)
                }

            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(BaziTheme.shenshaInauspicious)
                Button("重试", action: onRetry)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BaziTheme.cinnabar)

            case .dailyLimitReached(let nextReset):
                DailyLimitReachedView(nextReset: nextReset)
                // 达上限:**禁用生成按钮、不显示重试**(方案 step 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.cardBorder, lineWidth: 0.5))
    }
}
