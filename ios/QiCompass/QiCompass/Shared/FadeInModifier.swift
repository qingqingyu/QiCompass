import SwiftUI

/// 淡入过渡 modifier(方案 §2.6)。
///
/// 设计:
/// - `.easeInOut(duration: 0.35)` + `.opacity`
/// - Reduce Motion 关:保留 0.35s 淡入(纯 opacity 本身就符合 Reduce Motion 精神)
/// - Reduce Motion 开:duration 压缩到 0.15s(不跳过,但加快)
///
/// 应用点:
/// - 状态切换(loading → loaded / error → retry)
/// - AI 解读区首次入场
/// - 卡片区段(InterpretationSection / AssessmentCardGrid / SyncedFortuneTable)
/// - 空态 / 错误态进入
struct FadeInModifier: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .onAppear {
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
    /// 淡入过渡。Reduce Motion 开启时压缩 duration 到 0.15s、去掉 delay。
    func fadeIn(delay: Double = 0) -> some View {
        modifier(FadeInModifier(delay: delay))
    }
}

// MARK: - BreathInModifier

/// 淡入 + 上移过渡(onboarding 专用"呼吸感"入场)。
///
/// 跟 `FadeInModifier` 的区别:除了 opacity 0→1 还叠加 8pt 上移(offset y: 8→0),
/// 让元素像"从下方浮出"。用于 onboarding 各页元素依次入场(印章 → 标题 → 副标题 → CTA),
/// 营造克制节奏感(2026-07-19 入门动画优化,方向:克制安静 + 东方质感)。
///
/// 设计:
/// - `.easeInOut(duration: 0.35)` + `.opacity` + `offset(y: 8)`
/// - Reduce Motion 关:0.35s 淡入 + 8pt 上移 + delay 节奏
/// - Reduce Motion 开:duration 压到 0.15s,去 delay,去位移(纯 opacity,符合 Reduce Motion 精神)
struct BreathInModifier: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: (visible || reduceMotion) ? 0 : 8)
            .onAppear {
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
    /// 淡入 + 上移过渡(onboarding 专用"呼吸感"入场)。
    /// Reduce Motion 开启时压缩 duration 到 0.15s、去 delay、去位移。
    func breathIn(delay: Double = 0) -> some View {
        modifier(BreathInModifier(delay: delay))
    }
}
