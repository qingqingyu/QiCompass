import SwiftUI

/// AI 命书区(方案 §一 InterpretationSection + DESIGN.md §Color)。
///
/// 子状态机:
/// - idle:"生成命书"按钮(cinnabar CTA)+ 剩余次数
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
                    .zcoolCardTitle()
                Spacer()
                Text("今日剩余 \(vm.remainingReads)/10 次")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            switch interpretState {
            case .idle:
                Button(action: { HapticEngine.medium(); vm.generateInterpretation() }) {
                    Text("生成命书")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BaziTheme.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }

            case .fetching:
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(BaziTheme.cinnabar)
                    Text("生成命书中…")
                        .font(.subheadline)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)

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
                    Button("重新生成", action: vm.retryInterpretation)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.cinnabar)
                }

            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(BaziTheme.shenshaInauspicious)
                Button("重试", action: vm.retryInterpretation)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(BaziTheme.cinnabar)

            case .dailyLimitReached(let nextReset):
                Text("今日机缘已尽,明日再来")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.shenshaInauspicious)
                CountdownResetLabel(nextReset: nextReset)
                // 达上限:**禁用生成按钮、不显示重试**(方案 step 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.cardBorder, lineWidth: 0.5))
    }
}
