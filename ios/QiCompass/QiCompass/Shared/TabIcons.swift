import SwiftUI

/// 墨物线描四枚 tab 图标(2026-08-30 定稿)。
///
/// 设计事实源:`~/.gstack/projects/qingqingyu-QiCompass/designs/tab-icons-20260830/finalized.html`
/// (方向 A,对比板 5/5)。几何参数取自批准变体 SVG 源码的 180 单位坐标系,非目测:
/// - **今日** = 墨圆环抱一点(EnsoView 同源笔触 + 7.2% 中心墨点),品牌指纹贯穿开屏 → tab
/// - **深度** = 三叠横墨(长 134/96/56,左圆帽右平收,层层入深)
/// - **合盘** = 双开口圆交叠(r 27.8%,圆心距 31%,缺口交错上下)
/// - **我的** = 未钤空心印(64% 方,radius 边长 24%),与朱印 SealStamp 互为阴阳
///
/// 单色 inkDeep 矢量,经 ImageRenderer 渲染为 UIImage 模板图,交系统 tabItem
/// 模板着色(选中 tint=ink / 未选中系统次级灰,深浅色随 BaziTheme.dyn 自动反转)。
/// 朱红不出现在 tab 层(DESIGN.md 朱红纪律:印章级专用;定稿页叁·朱红决策)。
enum TabIcons {
    /// tab 图标渲染尺寸(pt)。系统 tabItem 图标约 25-28pt,28pt 盒 + 3x 采样。
    static let renderSize: CGFloat = 28

    // MARK: - 今日(墨圆环抱点)

    struct TodayTabIcon: View {
        var size: CGFloat = renderSize

        var body: some View {
            ZStack {
                // 同源复用 EnsoView 笔触(静态直出,线宽按定稿 5.5% 而非展示态 6.3%)
                EnsoView(size: size, strokeWidth: size * 0.055, breathing: false, animated: false)
                // 中心墨点 r = 13/180 ≈ 7.2%(直径 14.4%)
                Circle()
                    .fill(BaziTheme.inkDeep)
                    .frame(width: size * 0.144, height: size * 0.144)
            }
            .frame(width: size, height: size)
        }
    }

    // MARK: - 深度(三叠横墨)

    /// 三笔横墨 Path:180 坐标系直译自批准变体 SVG。
    /// 笔高 18,长 134/96/56,左圆帽(capR 9,三次贝塞尔近似半圆)右平收。
    struct DeepTabIcon: View {
        var size: CGFloat = renderSize

        var body: some View {
            DeepInkStrokes()
                .fill(BaziTheme.inkDeep)
                .frame(width: size, height: size)
        }
    }

    private struct DeepInkStrokes: Shape {
        func path(in rect: CGRect) -> Path {
            let s = min(rect.width, rect.height) / 180
            var p = Path()
            // 第一笔 y 35→53, x 22→156
            p.move(to: CGPoint(x: 22, y: 35))
            p.addCurve(to: CGPoint(x: 156, y: 42.8),
                       control1: CGPoint(x: 76, y: 35), control2: CGPoint(x: 128, y: 41.5))
            p.addLine(to: CGPoint(x: 156, y: 45.2))
            p.addCurve(to: CGPoint(x: 22, y: 53),
                       control1: CGPoint(x: 128, y: 46.5), control2: CGPoint(x: 76, y: 53))
            p.addCurve(to: CGPoint(x: 22, y: 35),
                       control1: CGPoint(x: 13, y: 53), control2: CGPoint(x: 13, y: 35))
            p.closeSubpath()
            // 第二笔 y 81→99, x 42→138
            p.move(to: CGPoint(x: 42, y: 81))
            p.addCurve(to: CGPoint(x: 138, y: 88.8),
                       control1: CGPoint(x: 78, y: 81), control2: CGPoint(x: 116, y: 87.5))
            p.addLine(to: CGPoint(x: 138, y: 91.2))
            p.addCurve(to: CGPoint(x: 42, y: 99),
                       control1: CGPoint(x: 116, y: 92.5), control2: CGPoint(x: 78, y: 99))
            p.addCurve(to: CGPoint(x: 42, y: 81),
                       control1: CGPoint(x: 33, y: 99), control2: CGPoint(x: 33, y: 81))
            p.closeSubpath()
            // 第三笔 y 127→145, x 62→118
            p.move(to: CGPoint(x: 62, y: 127))
            p.addCurve(to: CGPoint(x: 118, y: 134.8),
                       control1: CGPoint(x: 82, y: 127), control2: CGPoint(x: 104, y: 133.5))
            p.addLine(to: CGPoint(x: 118, y: 137.2))
            p.addCurve(to: CGPoint(x: 62, y: 145),
                       control1: CGPoint(x: 104, y: 138.5), control2: CGPoint(x: 82, y: 145))
            p.addCurve(to: CGPoint(x: 62, y: 127),
                       control1: CGPoint(x: 53, y: 145), control2: CGPoint(x: 53, y: 127))
            p.closeSubpath()
            return p.applying(CGAffineTransform(scaleX: s, y: s))
        }
    }

    // MARK: - 合盘(双环交叠)

    /// 双开口圆:r=50(直径 55.6%),圆心 (62,90) 与 (118,90)(各偏 ±15.6%,圆心距 31%),
    /// 各 320° 弧缺口 40°(拍板口径;定稿页 SVG 路径实测为 340° 弧/缺口 20°):
    /// 左环缺口朝上、右环缺口朝下(交错 180°)。
    struct HepanTabIcon: View {
        var size: CGFloat = renderSize

        var body: some View {
            ZStack {
                openCircle(gapAtTop: true)
                    .offset(x: -size * 0.156)
                openCircle(gapAtTop: false)
                    .offset(x: size * 0.156)
            }
            .frame(width: size, height: size)
        }

        /// 320° 开口圆。Circle.trim 不回绕(from>to 会把 to 钳到 1 只画出残弧,
        /// 2026-08-30 首次实机验收踩过),因此用 from 0→0.8889 + 旋转放缺口:
        /// trim 缺口默认居 340°(右侧),旋转 -70°→缺口朝上(270°),+110°→朝下(90°)。
        private func openCircle(gapAtTop: Bool) -> some View {
            Circle()
                .trim(from: 0, to: 0.8889)
                .stroke(BaziTheme.inkDeep,
                        style: StrokeStyle(lineWidth: size * 0.039, lineCap: .round))
                .frame(width: size * 0.556, height: size * 0.556)
                .rotationEffect(.degrees(gapAtTop ? -70 : 110))
        }
    }

    // MARK: - 我的(未钤空心印)

    /// 空心圆角方:116/180 = 64.4% 见方,rx 28(边长 24%),线宽 7.5/180 = 4.2%。
    /// 印面全空 ——「未钤之印」,不加内衬框(区别于 SealStamp 的 insetBorder)。
    struct MeTabIcon: View {
        var size: CGFloat = renderSize

        var body: some View {
            RoundedRectangle(cornerRadius: size * 0.644 * 0.241)
                .stroke(BaziTheme.inkDeep, lineWidth: size * 0.0417)
                .frame(width: size * 0.644, height: size * 0.644)
        }
    }

    // MARK: - tabItem 用模板图

    enum Tab {
        case today, deep, hepan, me

        @ViewBuilder
        var icon: some View {
            switch self {
            case .today: TodayTabIcon()
            case .deep:  DeepTabIcon()
            case .hepan: HepanTabIcon()
            case .me:    MeTabIcon()
            }
        }
    }

    /// ImageRenderer 静态渲染 SwiftUI 视图 → 模板 UIImage。
    /// 失败即 preconditionFailure 显式崩溃(渲染内容非空,失败只可能是编程错误),
    /// 不返回占位图静默降级。
    /// @MainActor:ImageRenderer 全 API 主演员隔离;调用方(RootTabView tabItem)在主演员上。
    @MainActor
    static func uiImage(for tab: Tab) -> UIImage {
        let renderer = ImageRenderer(content: tab.icon.frame(width: renderSize, height: renderSize))
        renderer.proposedSize = ProposedViewSize(width: renderSize, height: renderSize)
        renderer.scale = 3
        guard let image = renderer.uiImage else {
            preconditionFailure("TabIcons.uiImage(\(tab)) 渲染失败:内容非空,属编程错误")
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    /// tabItem 闭包随 selection 变化会重复求值,缓存四枚模板图。
    @MainActor
    static let cachedToday = uiImage(for: .today)
    @MainActor
    static let cachedDeep = uiImage(for: .deep)
    @MainActor
    static let cachedHepan = uiImage(for: .hepan)
    @MainActor
    static let cachedMe = uiImage(for: .me)
}
