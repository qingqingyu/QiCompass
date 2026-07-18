import SwiftUI

/// 合盘 AI 解读段(D9 + DESIGN.md §Color)。
///
/// **独立 error 态 + 禁词拦截提示**:定性评估 + 流年同步表已就绪即视为合盘成功;
/// AI 子状态独立 error,可单独重试,不污染整体 resultReady。
///
/// 不复用 DailyInterpretationSection:字数(400-500)/ 标题 / 模块不同。
struct CompatibilityInterpretationSection: View {
    let state: InterpretState
    let remainingReads: Int
    let nextReset: Date
    let onGenerate: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("合盘解读")
                    .zcoolCardTitle()
                Spacer()
                Text("剩余 \(remainingReads) 次")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            switch state {
            case .idle:
                if remainingReads <= 0 {
                    DailyLimitReachedView(nextReset: nextReset)
                } else {
                    interpretationCTABlock(isLoading: false)
                }
            case .fetching:
                interpretationCTABlock(isLoading: true)
            case .ok(let text, let cached):
                Text(text)
                    .bodySerifText()
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .fadeIn()
                if cached {
                    HStack {
                        Image(systemName: "checkmark.seal")
                        Text("24h 内已缓存,不消耗次数")
                    }
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
                }
                HStack {
                    Spacer()
                    Button("重新生成", action: onRetry)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.cinnabar)
                }
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                    Button("重试", action: onRetry)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BaziTheme.cinnabar)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            case .dailyLimitReached(let nextReset):
                DailyLimitReachedView(nextReset: nextReset)
                // 达上限:**禁用生成按钮、不显示重试**(方案 step 4)
            }
        }
        .padding(16)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.cardBorder, lineWidth: 0.5)
        )
    }

    /// idle/fetching 共享 CTA 区(说明文字 + PrimaryCTAButton,loading 时也保留说明)。
    @ViewBuilder
    private func interpretationCTABlock(isLoading: Bool) -> some View {
        VStack(spacing: 12) {
            Text("点击生成合盘解读(约 400-500 字,涵盖五行、日主、流年同步)")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)

            PrimaryCTAButton(
                title: "生成合盘解读",
                loadingTitle: "推演中…",
                isLoading: isLoading,
                action: isLoading ? {} : onGenerate
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
