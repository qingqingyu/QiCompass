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
                    .font(.headline)
                    .foregroundStyle(BaziTheme.goldLight)
                Spacer()
                Text("剩余 \(remainingReads)/1 次")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.textDim)
            }

            switch state {
            case .idle:
                EmptyInterpretationView(
                    remainingReads: remainingReads,
                    onGenerate: onGenerate,
                )
            case .fetching:
                HStack(spacing: 12) {
                    ProgressView().tint(BaziTheme.gold)
                    Text("推演中…")
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            case .ok(let text, let cached):
                Text(text)
                    .font(.body)
                    .foregroundStyle(BaziTheme.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if cached {
                    HStack {
                        Image(systemName: "checkmark.seal")
                        Text("24h 内已缓存,不消耗次数")
                    }
                    .font(.caption)
                    .foregroundStyle(BaziTheme.textDim)
                }
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                    Button("重试", action: onRetry)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BaziTheme.gold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
        }
        .padding(16)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(BaziTheme.cardBorder, lineWidth: 1)
        )
    }
}

private struct EmptyInterpretationView: View {
    let remainingReads: Int
    let onGenerate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("点击生成今日流日解读(约 150-200 字)")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.textDim)
                .multilineTextAlignment(.center)

            Button(action: onGenerate) {
                HStack {
                    Image(systemName: "sparkles")
                    Text(remainingReads > 0 ? "今日解读" : "今日机缘已尽")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(BaziTheme.bgTop)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(
                    remainingReads > 0 ? BaziTheme.gold : BaziTheme.textDim.opacity(0.4),
                    in: Capsule()
                )
            }
            .disabled(remainingReads <= 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
