import SwiftUI
import UIKit

/// 统一字体入口(方案 §2.3)。
///
/// 两层字体策略:
/// - **ZCOOL XiaoWei**(显示字体):页面标题 / 卡片标题 / 命盘激活态数字 / Tab 激活态。
///   字符覆盖不足,**不用于**长文正文。
/// - **系统衬线**(正文字体):命书段落(`InterpretationSection` 等)。
///
/// fallback 机制:ZCOOL ttf 未加载时自动降级到 `.system(.serif)`,不阻断 UI。
/// 当前仓库未打包 ZCOOL 字体文件,因此默认走 fallback;若后续加入字体,
/// 需同时把 ttf 加入 Copy Bundle Resources 并在 Info.plist 注册。
enum BaziFont {
    /// ZCOOL XiaoWei 是否已加载(启动时一次性探测,避免每次渲染都查)。
    private static let zcoolLoaded: Bool = UIFont(name: "ZCOOLXiaoWei", size: 12) != nil

    /// 页面标题 / 卡片标题 / 激活态数字(显示字体,有 fallback)。
    static func zcoolTitle(size: CGFloat) -> Font {
        zcoolLoaded
            ? .custom("ZCOOLXiaoWei", size: size)
            : .system(size: size, design: .serif)
    }

    /// 命书正文(系统衬线,字符覆盖完整)。
    static func bodySerif(size: CGFloat = 15) -> Font {
        .system(size: size, design: .serif)
    }

    /// chip / 标签(系统默认,不强装饰)。
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
}

extension View {
    /// 页面标题样式(ZCOOL + 亮金)。
    func zcoolPageTitle(size: CGFloat = 24) -> some View {
        font(BaziFont.zcoolTitle(size: size))
            .foregroundStyle(BaziTheme.goldLight)
    }

    /// 卡片标题样式(ZCOOL + 亮金,小一号)。
    func zcoolCardTitle(size: CGFloat = 17) -> some View {
        font(BaziFont.zcoolTitle(size: size))
            .foregroundStyle(BaziTheme.goldLight)
    }

    /// 命书正文样式(系统衬线 + 正文色)。
    func bodySerifText(size: CGFloat = 15) -> some View {
        font(BaziFont.bodySerif(size: size))
            .foregroundStyle(BaziTheme.text)
    }
}
