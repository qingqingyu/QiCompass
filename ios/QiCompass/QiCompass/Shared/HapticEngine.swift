import UIKit

/// 触感工具(方案 §D3)。
///
/// 设计:
/// - 仅用户主动交互触发(排盘发起 / AI 发起 / 重试 / 达上限时点生成)
/// - **不**在自动加载 / 缓存命中 / 错误回调 / refund 中触发(遵循 iOS HIG)
/// - Reduce Motion 启用时静默(系统约定:触感与动画相伴,关动画即关触感)
enum HapticEngine {
    static func light() { fire(.light) }
    static func medium() { fire(.medium) }
    static func heavy() { fire(.heavy) }
    static func rigid() { fire(.rigid) }

    private static func fire(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }
}
