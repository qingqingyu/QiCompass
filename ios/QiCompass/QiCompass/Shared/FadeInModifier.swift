import SwiftUI

/// 淡入过渡 modifier(方案 §2.6)。
///
/// 设计:
/// - `.easeInOut(duration: 0.35)` + `.opacity`(+ 可选 `yOffset` 上移)
/// - Reduce Motion 关:0.35s 淡入(+ delay + 可选上移)
/// - Reduce Motion 开:duration 压到 0.15s,去 delay,去位移(纯 opacity,符合 Reduce Motion 精神)
///
/// 同一实现支撑两个语义化 API(`yOffset` 参数让两者共享代码,避免 DRY 重复):
/// - `fadeIn`:纯淡入(yOffset=0)。状态切换 / AI 解读区首次入场 / 卡片区段 / 空态 / 错误态进入
/// - `riseIn`:淡入 + 8pt 上移(yOffset=8)。onboarding 元素依次入场(印章 → 标题 → 副标题 → CTA,
///   2026-07-19 入门动画优化,方向:克制安静 + 东方质感)
struct FadeInModifier: ViewModifier {
    let delay: Double
    let yOffset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: (visible || reduceMotion) ? 0 : yOffset)
            .onAppear {
                // TabView .page 预渲染相邻页时 onAppear 可能提前触发,
                // 预渲染期间动画已在用户看到前播完,无需特殊处理。
                // 不加 onDisappear 重置:避免来回翻页时 opacity:1→0→1 的视觉跳跃。
                withAnimation(
                    .easeInOut(duration: reduceMotion ? 0.15 : 0.35)
                    .delay(reduceMotion ? 0 : delay)
                ) {
                    visible = true
                }
            }
    }
}

extension View {
    /// 淡入过渡(无位移)。Reduce Motion 开启时压缩 duration 到 0.15s、去掉 delay。
    func fadeIn(delay: Double = 0) -> some View {
        modifier(FadeInModifier(delay: delay, yOffset: 0))
    }

    /// 淡入 + 上移过渡(从下方浮入,onboarding 专用"呼吸感"入场)。
    /// Reduce Motion 开启时压缩 duration 到 0.15s、去 delay、去位移。
    /// 命名跟 NarrationLine(内容组件)区分,riseIn 是动画动作。
    func riseIn(delay: Double = 0) -> some View {
        modifier(FadeInModifier(delay: delay, yOffset: 8))
    }
}
