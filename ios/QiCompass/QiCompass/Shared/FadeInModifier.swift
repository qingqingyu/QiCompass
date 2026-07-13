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
