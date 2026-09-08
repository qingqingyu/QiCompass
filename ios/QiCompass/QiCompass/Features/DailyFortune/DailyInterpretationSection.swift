import SwiftUI

/// AI 解读区(50-80 字 Medium voice)。
///
/// 子状态独立(决策 §3.1;2026-09-07 起主路径 = 进入页面自动生成):
/// - .idle → 仅离线兜底/达限可达:离线且有次数 → CTA 手动入口;
///   次数耗尽 → 达限卡(自动触发前 VM 会查次数,不发起空调用)
/// - .fetching → 静默推演指示(ProgressView + 「推演中…」,无按钮)
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
                    // 自动生成时代 .idle 仅剩离线兜底一条路(联网后手动点)
                    interpretationCTABlock()
                }
            case .fetching:
                // 自动生成(2026-09-07):推演中不再渲染 CTA 按钮,
                // 静默指示即可——按钮暗示「还要点一下」,与免点击语义相悖
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(BaziTheme.inkMuted)
                    Text(L10n.DailyFortune.interpretLoading)
                        .font(BaziFont.caption(size: 12))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
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
    /// .idle(离线兜底)手动 CTA 区:说明文字 + 按钮。
    @ViewBuilder
    func interpretationCTABlock() -> some View {
        VStack(spacing: 12) {
            Text(L10n.DailyFortune.interpretCTA)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)

            PrimaryCTAButton(
                title: L10n.DailyFortune.interpretTitle,
                loadingTitle: L10n.DailyFortune.interpretLoading,
                isLoading: false,
                action: onGenerate
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
