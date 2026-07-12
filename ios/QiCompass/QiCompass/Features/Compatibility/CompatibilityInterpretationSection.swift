import SwiftUI

/// 合盘 AI 解读段(D9)。
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
                    .font(.headline)
                    .foregroundStyle(BaziTheme.goldLight)
                Spacer()
                Text("剩余 \(remainingReads)/3 次")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.textDim)
            }

            switch state {
            case .idle:
                emptyIdleView
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
                HStack {
                    Spacer()
                    Button("重新生成", action: onRetry)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.gold)
                }
            case .failed(let message):
                VStack(spacing: 8) {
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                    if message.contains("机缘已尽") {
                        countdownView
                    }
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

    private var emptyIdleView: some View {
        VStack(spacing: 12) {
            Text("点击生成合盘解读(约 400-500 字,涵盖五行、日主、流年同步)")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.textDim)
                .multilineTextAlignment(.center)

            Button(action: onGenerate) {
                HStack {
                    Image(systemName: "sparkles")
                    Text(remainingReads > 0 ? "生成合盘解读" : "今日机缘已尽")
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

    /// 倒计时到午夜(TimelineView,每分钟刷新,无 Timer 泄漏)。
    private var countdownView: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let remaining = nextReset.timeIntervalSince(context.date)
            Text("距重置:\(formatCountdown(max(0, remaining)))")
                .font(.caption2)
                .foregroundStyle(BaziTheme.textDim)
        }
    }

    private func formatCountdown(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return String(format: "%d 时 %d 分", h, m)
    }
}
