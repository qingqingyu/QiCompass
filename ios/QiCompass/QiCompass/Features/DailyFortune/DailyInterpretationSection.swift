import SwiftUI

/// AI 解读区(150-200 字,决策 F)。
///
/// 子状态独立(决策 §3.1):
/// - .idle → CTA「今日解读」按钮(显示剩余次数)
/// - .fetching → ProgressView + 「推演中…」
/// - .ok(text, cached) → 解读文本 + cached 标识
/// - .failed(msg) → 错误 + 重试
struct DailyInterpretationSection: View {
    let state: InterpretState
    let remainingReads: Int
    let nextReset: Date
    let onGenerate: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今日解读")
                    .zcoolCardTitle()
                Spacer()
                Text("剩余 \(remainingReads)/10 次")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            switch state {
            case .idle:
                if remainingReads <= 0 {
                    Text("今日机缘已尽,明日再来")
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                    CountdownResetLabel(nextReset: nextReset)
                } else {
                    EmptyInterpretationView(onGenerate: onGenerate)
                }
            case .fetching:
                HStack(spacing: 12) {
                    ProgressView().tint(BaziTheme.cinnabar)
                    Text("推演中…")
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
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
                VStack(spacing: 8) {
                    Text("今日机缘已尽,明日再来")
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                    CountdownResetLabel(nextReset: nextReset)
                    // 达上限:**禁用生成按钮、不显示重试**(方案 step 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
        .padding(16)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.cardBorder, lineWidth: 0.5)
        )
    }
}

private struct EmptyInterpretationView: View {
    let onGenerate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("点击生成今日流日解读(约 150-200 字)")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)

            Button(action: { HapticEngine.medium(); onGenerate() }) {
                HStack {
                    Image(systemName: "sparkles")
                    Text("今日解读")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(BaziTheme.paper)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
