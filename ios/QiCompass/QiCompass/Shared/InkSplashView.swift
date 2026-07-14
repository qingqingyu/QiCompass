import SwiftUI

/// 墨溅装饰视图(Canvas + Path 自绘,无外部依赖,DESIGN.md §Color)。
///
/// 设计(方案 §D2):
/// - seed 化轮廓让不同 instance 产生稳定的微变化(每次构建看起来一致)
/// - Reduce Motion 启用:transition 退化为 `.opacity`(只保留淡入,不做位移/缩放)
///
/// 用途:
/// - 网络错误 / 兜底错误态的装饰图(替代 SF Symbol 的"天意未明"墨溅意象)
struct InkSplashView: View {
    /// 轮廓 seed(决定墨溅形状)。同 seed 出同形状。
    let seed: UInt64
    /// 主色(默认朱砂,DESIGN.md §Color 与错误态主色对齐)。
    var color: Color = BaziTheme.cinnabar

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let baseRadius = min(size.width, size.height) * 0.42
            var path = Path()
            let points = 28
            for i in 0...points {
                let angle = Double(i) / Double(points) * 2 * .pi
                let noise = Self.pseudoNoise(seed: seed &+ UInt64(i))
                let r = baseRadius * (0.78 + 0.32 * noise)
                let x = center.x + r * cos(angle)
                let y = center.y + r * sin(angle)
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            path.closeSubpath()
            context.fill(path, with: .color(color.opacity(0.32)))
            context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 1.4)

            // 中心点缀一滴实心圆(墨核)
            let coreNoise = Self.pseudoNoise(seed: seed)
            let coreRadius = baseRadius * (0.18 + 0.06 * coreNoise)
            let coreRect = CGRect(
                x: center.x - coreRadius, y: center.y - coreRadius,
                width: coreRadius * 2, height: coreRadius * 2
            )
            context.fill(Path(ellipseIn: coreRect), with: .color(color.opacity(0.55)))
        }
        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
    }

    /// 简单确定性 hash → [0, 1]。xxhash 风格的 mix,够用且无依赖。
    private static func pseudoNoise(seed: UInt64) -> Double {
        var x = seed
        x ^= x &<< 13
        x ^= x &>> 7
        x ^= x &<< 17
        return Double(x % 1000) / 1000.0
    }
}

#if DEBUG
#Preview {
    InkSplashView(seed: 42)
        .frame(width: 160, height: 160)
        .background(BaziTheme.paper)
}
#endif
