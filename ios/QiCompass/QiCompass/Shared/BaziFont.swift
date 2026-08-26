import SwiftUI
import UIKit

/// 统一字体入口(DESIGN.md §Typography,2026-08-26 水墨孤本换轨)。
///
/// DESIGN.md §Typography 落地:
/// - **Display / Ganzhi / Heading / Body**:`Kaiti SC`(楷体,iOS 系统自带,不打包)。
///   楷体扛全部中文展示层,书卷手写感呼应水墨孤本。命名缺失时 Font.custom 静默回退系统字体,
///   模拟器实测以 `UIFont(name: "Kaiti SC")` 探测结果为准(备选名 "STKaiti")。
/// - **Numeric / Tabular**:系统默认 + `.monospacedDigit()`(SF Pro Text)。
/// - **LatinCaps**:QICOMPASS 字距标(system + 调用侧 .tracking 大间距)。
///
/// 历史:宋瓷时代 display 走系统 `.serif`(Songti SC)——2026-08-26 换轨为 Kaiti SC。
/// 仓库曾尝试 ZCOOL XiaoWei 打包,已废弃(免打包决策不变)。`zcool*` API 名保留作 alias。
enum BaziFont {
    /// 楷体首选 PostScript 名;"STKaiti" 为旧名兜底。
    /// 两者都取不到时返回 nil,调用侧回退系统 .serif(宋体),不至于渲染失败。
    private static let kaitiName: String? = UIFont(name: "Kaiti SC", size: 12) != nil
        ? "Kaiti SC"
        : (UIFont(name: "STKaiti", size: 12) != nil ? "STKaiti" : nil)

    /// 楷体字体。kaitiName 不可用时回退系统 .serif(Songti SC),保证永远有衬线兜底。
    private static func kaiti(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        if let name = kaitiName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// 显示字体(DESIGN.md §Display/Hero:Kaiti SC)。
    /// 楷体笔画细,展示层默认 Medium(替代宋瓷时代的 Semibold)。
    static func display(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        kaiti(size: size, weight: weight)
    }

    /// 八字专用干支字体(DESIGN.md §Ganzhi:Kaiti SC,与 display 同族)。
    static func ganzhi(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        display(size: size, weight: weight)
    }

    /// 命书正文(DESIGN.md §Body:Kaiti SC,阅读页 15.5pt 行距 2.15× 由调用侧 lineSpacing 控制)。
    static func body(size: CGFloat = 16) -> Font {
        kaiti(size: size, weight: .regular)
    }

    /// 数字 / 西文(DESIGN.md §Numeric:SF Pro Text + tabular-nums)。
    static func numeric(size: CGFloat = 14, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
            .monospacedDigit()
    }

    /// Latin 大字距小标(QICOMPASS 类,8.5-10pt + 调用侧 .tracking(≈字号的 0.55 倍))。
    static func latinCaps(size: CGFloat = 9.5) -> Font {
        .system(size: size, weight: .regular)
    }

    /// chip / 标签(系统默认 medium)。
    static func chip(size: CGFloat = 12) -> Font {
        .system(size: size, weight: .medium)
    }

    /// 按钮(系统默认半粗;楷体按钮字重不足,按钮仍走系统字)。
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
    /// 页面标题样式(Kaiti SC Medium + 浓墨,DESIGN.md §Display)。
    func zcoolPageTitle(size: CGFloat = 24) -> some View {
        font(BaziFont.display(size: size))
            .foregroundStyle(BaziTheme.ink)
    }

    /// 卡片标题样式(Kaiti SC Medium + 浓墨,小一号,DESIGN.md §Heading)。
    func zcoolCardTitle(size: CGFloat = 17) -> some View {
        font(BaziFont.display(size: size, weight: .medium))
            .foregroundStyle(BaziTheme.ink)
    }

    /// 命书正文样式(Kaiti SC Regular + 浓墨,DESIGN.md §Body)。
    func bodySerifText(size: CGFloat = 16) -> some View {
        font(BaziFont.body(size: size))
            .foregroundStyle(BaziTheme.ink)
    }
}
