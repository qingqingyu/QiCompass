import SwiftUI

/// 全局主 CTA 按钮(网络类操作专用)。
///
/// 视觉事实源(DESIGN.md §水墨孤本,2026-08-26 换轨):
/// - 背景:BaziTheme.inkDeep 实心(焦墨;朱红已退出 CTA,降为印章级点缀)
/// - 圆角:5pt(略大于默认 4pt,CTA 专属)
/// - 文字:BaziFont.button()(系统 Semibold)+ BaziTheme.onInkDeep(与 inkDeep 成对,暗色反转)
/// - 尾端 7pt 朱色菱形印点(cinnabar,旋转 45°)——CTA 上唯一的印章级点缀
/// - 触感:HapticEngine.medium()(Reduce Motion 兼容已在 HapticEngine 内处理)
///
/// isLoading 态:
/// - .disabled(true)(防重复点击,系统级拦截)
/// - 内嵌 ProgressView().tint(BaziTheme.onInkDeep)
/// - 文字换 loadingTitle
/// - opacity 0.6(视觉禁用暗示)
///
/// 设计意图:点击后按钮自身进入 loading 态(不消失、不换内容),
/// 因果链清晰:我点了 → 按钮在响应 → 等待结果。
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
                        .tint(BaziTheme.onInkDeep)
                        .controlSize(.small)
                }
                Text(isLoading ? loadingTitle : title)
                    .font(BaziFont.button())
                    .foregroundStyle(BaziTheme.onInkDeep)
                if !isLoading {
                    // 朱色菱形印点:CTA 尾端的印章级点缀(DESIGN.md §Color 朱红纪律)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(BaziTheme.cinnabar)
                        .frame(width: 7, height: 7)
                        .rotationEffect(.degrees(45))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(BaziTheme.inkDeep, in: RoundedRectangle(cornerRadius: 5))
            .opacity(isLoading || !isEnabled ? 0.6 : 1.0)
        }
        .disabled(isLoading || !isEnabled)
    }
}
