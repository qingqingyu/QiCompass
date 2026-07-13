import SwiftUI
import UIKit

/// 统一字体入口(DESIGN.md §Typography + 方案 §2.3)。
///
/// DESIGN.md §Typography 落地:
/// - **Display / Ganzhi / Heading**:系统衬线(iOS 中文 fallback = Songti SC),Semibold/Medium 字重。
/// - **Body**:系统默认(iOS 中文 = PingFang SC),Regular 字重。
/// - **Numeric / Tabular**:系统默认 + `.monospacedDigit()`。
///
/// 历史:仓库曾尝试用 ZCOOL XiaoWei 打包,但为减少体积改用 iOS 系统字体(DESIGN.md 决策:
/// "iOS 系统 Songti SC + PingFang SC 已够用,免打包")。本 enum 保留 `zcool*` API 名作 alias,
/// 调用点迁移到 `display`/`ganzhi`/`body` 后可统一改名。
enum BaziFont {
    /// ZCOOL XiaoWei 是否已加载(保留探测,如果未来需要打包字体可平滑切换)。
    private static let zcoolLoaded: Bool = UIFont(name: "ZCOOLXiaoWei", size: 12) != nil

    /// 显示字体(DESIGN.md §Display/Hero:Songti SC Semibold)。
    /// 走系统 `.serif` design — iOS 中文环境 fallback 到 Songti SC。
    static func display(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        zcoolLoaded
            ? .custom("ZCOOLXiaoWei", size: size)
            : .system(size: size, weight: weight, design: .serif)
    }

    /// 八字专用干支字体(DESIGN.md §Ganzhi:Songti SC Semibold,与 display 同族)。
    static func ganzhi(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        display(size: size, weight: weight)
    }

    /// 命书正文(DESIGN.md §Body:PingFang SC Regular,系统默认)。
    static func body(size: CGFloat = 16) -> Font {
        .system(size: size)
    }

    /// 数字 / 西文(DESIGN.md §Numeric:SF Pro Text + tabular-nums)。
    static func numeric(size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
            .monospacedDigit()
    }

    /// chip / 标签(系统默认 medium)。
    static func chip(size: CGFloat = 12) -> Font {
        .system(size: size, weight: .medium)
    }

    /// 按钮(系统默认半粗)。
    static func button(size: CGFloat = 16) -> Font {
        .system(size: size, weight: .semibold)
    }

    /// 说明文字(系统默认小号)。
    static func caption(size: CGFloat = 12) -> Font {
        .system(size: size)
    }

    // MARK: - 旧 API alias(渐进重构)

    /// 旧 zcoolTitle → display(Songti SC)。
    static func zcoolTitle(size: CGFloat) -> Font {
        display(size: size)
    }

    /// 旧 bodySerif → body(DESIGN.md §Body 改用 PingFang SC 无衬线;旧"serif"语义废弃)。
    /// ⚠️ 设计反转:DESIGN.md 把命书正文从 .serif 改为 PingFang SC。
    static func bodySerif(size: CGFloat = 16) -> Font {
        body(size: size)
    }
}

extension View {
    /// 页面标题样式(Songti SC Semibold + 浓墨,DESIGN.md §Display)。
    func zcoolPageTitle(size: CGFloat = 24) -> some View {
        font(BaziFont.display(size: size))
            .foregroundStyle(BaziTheme.ink)
    }

    /// 卡片标题样式(Songti SC Semibold + 浓墨,小一号,DESIGN.md §Heading)。
    func zcoolCardTitle(size: CGFloat = 17) -> some View {
        font(BaziFont.display(size: size, weight: .medium))
            .foregroundStyle(BaziTheme.ink)
    }

    /// 命书正文样式(PingFang SC Regular + 浓墨,DESIGN.md §Body)。
    func bodySerifText(size: CGFloat = 16) -> some View {
        font(BaziFont.body(size: size))
            .foregroundStyle(BaziTheme.ink)
    }
}
