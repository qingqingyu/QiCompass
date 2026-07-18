import SwiftUI

/// 全局主 CTA 按钮(网络类操作专用)。
///
/// 视觉事实源(DESIGN.md):
/// - 背景:BaziTheme.cinnabar 实心(朱砂红)
/// - 圆角:BaziTheme.Radius.sm(4pt,克制)
/// - 文字:BaziFont.button()(系统默认 Semibold)+ BaziTheme.paper(宣纸米)
/// - 触感:HapticEngine.medium()(Reduce Motion 兼容已在 HapticEngine 内处理)
///
/// isLoading 态:
/// - .disabled(true)(防重复点击,系统级拦截)
/// - 内嵌 ProgressView().tint(BaziTheme.paper)
/// - 文字换 loadingTitle
/// - opacity 0.6(视觉禁用暗示)
///
/// 设计意图:点击后按钮自身进入 loading 态(不消失、不换内容),
/// 因果链清晰:我点了 → 按钮在响应 → 等待结果。
/// 替代旧模式"按钮消失换 ProgressView+Text",后者反馈弱、易被误认为"卡了"。
struct PrimaryCTAButton: View {
    let title: String
    var loadingTitle: String
    let isLoading: Bool
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            guard !isLoading, isEnabled else { return }
            HapticEngine.medium()
            action()
        } label: {
            HStack(spacing: BaziTheme.Spacing.sm) {
                if isLoading {
                    ProgressView()
                        .tint(BaziTheme.paper)
                        .controlSize(.small)
                }
                Text(isLoading ? loadingTitle : title)
                    .font(BaziFont.button())
                    .foregroundStyle(BaziTheme.paper)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
            .opacity(isLoading || !isEnabled ? 0.6 : 1.0)
        }
        .disabled(isLoading || !isEnabled)
    }
}
