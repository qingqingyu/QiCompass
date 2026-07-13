import SwiftUI

/// 项目统一的动画/过渡封装(方案 §D4)。
///
/// 设计:
/// - `@Environment(\.accessibilityReduceMotion)` 注入到 modifier / 命令式调用
/// - Reduce Motion 关闭:保留现有过渡;开启:位移/缩放/翻转 → `.opacity` 淡入或无动画
/// - 现状自定义动画 1 处(`HourPillarsSection.swift` `withAnimation(.easeInOut)`),
///   改造后新过渡(墨溅出现/错误态切换/结果区切换)统一走本封装。
enum MotionPreferences {
    /// Reduce Motion 关:返回原 animation;开:返回 nil(无动画)。
    static func animation(_ animation: Animation = .easeInOut, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// Reduce Motion 关:返回原 transition;开:返回 `.opacity`(淡入)。
    static func transition(_ transition: AnyTransition, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : transition
    }
}

extension View {
    /// 项目统一动画 modifier:Reduce Motion 启用时不应用动画。
    func baziAnimation<V: Equatable>(
        _ animation: Animation = .easeInOut,
        value: V
    ) -> some View {
        modifier(BaziAnimationModifier(base: animation, value: value))
    }
}

private struct BaziAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    let base: Animation
    let value: Value
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : base, value: value)
    }
}
