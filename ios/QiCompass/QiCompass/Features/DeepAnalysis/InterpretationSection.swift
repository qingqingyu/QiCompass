import SwiftUI

/// AI 命书区(方案 §一 InterpretationSection)。
///
/// 子状态机:
/// - idle:"生成命书"按钮 + 剩余次数
/// - fetching:ProgressView + 文案
/// - ok(text, cached):命书文本 + cached 标记 + 重新生成
/// - failed(message):错误 + 重试(达上限时显示倒计时到午夜)
struct InterpretationSection: View {
    @Bindable var vm: DeepAnalysisViewModel
    let response: BaziResponse

    @MainActor private var interpretState: InterpretState {
        if case .chartReady(_, let s) = vm.state { return s }
        return .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("AI 命书")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaziTheme.goldLight)
                Spacer()
                Text("今日剩余 \(vm.remainingReads) 次")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.textDim)
            }

            switch interpretState {
            case .idle:
                Button(action: vm.generateInterpretation) {
                    Text("生成命书")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BaziTheme.bgTop)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(BaziTheme.gold, in: Capsule())
                }

            case .fetching:
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(BaziTheme.gold)
                    Text("生成命书中…")
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.textDim)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)

            case .ok(let text, let cached):
                Text(text)
                    .font(.body)
                    .foregroundStyle(BaziTheme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    if cached {
                        Text("◎ 缓存命中(不消耗次数)")
                            .font(.caption2)
                            .foregroundStyle(BaziTheme.gold.opacity(0.8))
                    }
                    Spacer()
                    Button("重新生成", action: vm.retryInterpretation)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.gold)
                }

            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Color.red.opacity(0.9))
                if message.contains("机缘已尽") {
                    countdownView
                }
                Button("重试", action: vm.retryInterpretation)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BaziTheme.gold)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BaziTheme.cardBorder, lineWidth: 1))
    }

    /// 倒计时到午夜(TimelineView,每分钟刷新,无 Timer 泄漏)。
    private var countdownView: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let remaining = vm.nextDailyReset.timeIntervalSince(context.date)
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
