import SwiftUI

/// AI 解读区(50-80 字 Medium voice)。
///
/// 子状态独立(决策 §3.1):
/// - .idle → CTA「今日解读」按钮(显示剩余次数)
/// - .fetching → ProgressView + 「推演中…」
/// - .okFree(text, cached) → 解读文本 + cached 标识
/// - .failed(msg) → 错误 + 重试
struct DailyInterpretationSection: View {
    let state: InterpretState
    let remainingReads: Int
    let nextReset: Date
    let onGenerate: () -> Void
    let onRetry: () -> Void

    var body: some View {
        // 今日运势 V1「三框全载」:解读入框,正文楷体宽行距;全免费不上「剩余次数」
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.DailyFortune.interpretTitle)
                .font(BaziFont.caption(size: 10))
                .tracking(4)
                .foregroundStyle(BaziTheme.inkMutedSecondary)

            switch state {
            case .idle:
                if remainingReads <= 0 {
                    DailyLimitReachedView(nextReset: nextReset)
                } else {
                    interpretationCTABlock(isLoading: false)
                }
            case .fetching:
                interpretationCTABlock(isLoading: true)
            case .okFree(let text, let cached), .okPaid(let text, let cached):
                // 每日运势 v1 全免费(MONETIZATION.md 不在 SKU 列表),后端只调 daily_fortune module,
                // .okPaid 永不触发;合并处理避免重复代码。
                Text(MarkdownSanitizer.rendered(text))
                    .bodySerifText(size: 16)
                    .lineSpacing(9)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .fadeIn()
                if cached {
                    HStack {
                        Image(systemName: "checkmark.seal")
                        Text(L10n.DailyFortune.interpretCached)
                    }
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
                }
            case .lockedPaid:
                // 每日运势 v1 全免费,.lockedPaid 永不触发;保留 case 维护 switch 完整性。
                EmptyView()
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                    Button(L10n.DailyFortune.interpretRetry, action: onRetry)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BaziTheme.ink)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            case .dailyLimitReached(let nextReset):
                DailyLimitReachedView(nextReset: nextReset)
                // 达上限:**禁用生成按钮、不显示重试**(方案 step 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.hairline, lineWidth: 0.5)
        )
    }
}

private extension DailyInterpretationSection {
    /// idle/fetching 共享 CTA 区(说明文字 + PrimaryCTAButton,loading 时也保留说明)。
    @ViewBuilder
    func interpretationCTABlock(isLoading: Bool) -> some View {
        VStack(spacing: 12) {
            Text(L10n.DailyFortune.interpretCTA)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)

            PrimaryCTAButton(
                title: L10n.DailyFortune.interpretTitle,
                loadingTitle: L10n.DailyFortune.interpretLoading,
                isLoading: isLoading,
                action: isLoading ? {} : onGenerate
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
