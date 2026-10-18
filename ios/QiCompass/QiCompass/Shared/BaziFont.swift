import SwiftUI
import UIKit

/// 统一字体入口(DESIGN.md §Typography,2026-08-26 水墨孤本换轨 + 英文 locale 路由)。
///
/// DESIGN.md §Typography 落地:
/// - **Display / Ganzhi / Heading / Body(中文 UI)**:楷体 = **打包的霞鹜文楷**
///   (LXGW WenKai,SIL OFL 1.1,`Resources/LXGWWenKai-Regular.ttf`;zh-hant 腿
///   = 文楷 TC `LXGWWenKaiTC-Regular.ttf`,D7 繁体字形)。2026-10-18 S1b 拍板——
///   此前「iOS 系统自带 Kaiti SC」不实:真机默认不带(探测实证 8 名全 false,
///   模拟器才自带),Apple 下载 API 在 iOS 27 真机 0 字节空成功,系统楷体不可依赖;
///   系统名(Kaiti SC/STKaiti)保留在探测序后半作回退。楷体扛全部中文展示层。
/// - **图内题记宋体**:打包的思源宋体子集(QiSongti,`Resources/QiSongti-Regular.otf`,
///   ~300KB,字符集 = 今日页图内宋层固定文案;OFL 保留名 "Source" 故子集改名),
///   系统 Songti SC/STSong 作回退。
/// - **英文 locale 路由(2026-08-26,DESIGN.md Decisions Log)**:楷体拉丁字形偏楷书衬线,
///   英文正文可读性差——display/heading 回退系统 `.serif`(New York 系,气质匹配水墨),
///   body 走系统 sans。品牌字(玄机问道/干支/印章)不走本路由,始终楷体(中文不翻译,决策 7)。
/// - **Numeric / Tabular**:系统默认 + `.monospacedDigit()`(SF Pro Text)。
/// - **LatinCaps**:QICOMPASS 字距标(system + 调用侧 .tracking 大间距)。
///
/// 历史:宋瓷时代 display 走系统 `.serif`(Songti SC)——2026-08-26 换轨为 Kaiti SC;
/// 2026-10-18 S1a 曾走「系统可下载字体 + 启动按需下载」,S1b 打包确定性落地后
/// 下载机制退役。`zcool*` API 名保留作 alias。

enum BaziFont {
    // MARK: - 字体名探测(S1b,2026-10-18)

    /// 名字探测:返回第一个 `UIFont(name:)` 能命中的名字(打包字体经 UIAppFonts
    /// 注册后与系统字体同命名空间;探测序 = 打包名优先,系统名回退)。
    private static func firstAvailableFont(_ names: [String]) -> String? {
        names.first { UIFont(name: $0, size: 12) != nil }
    }

    /// 楷体名缓存语义:**命中即缓存,nil 不缓存**——晚注册的字体下次取值重新
    /// 探测即命中。约定主线程取值(SwiftUI body / Font 构造)。
    private static var _kaitiSCCache: String?
    /// 简体楷体:打包霞鹜文楷优先,系统 Kaiti SC / STKaitiSC-Regular 回退。
    private static var kaitiSCName: String? {
        if let cached = _kaitiSCCache { return cached }
        let found = firstAvailableFont(["LXGWWenKai-Regular", "Kaiti SC", "STKaitiSC-Regular"])
        if let found { _kaitiSCCache = found }
        return found
    }

    private static var _kaitiTCCache: String?
    /// 繁体楷体(D7:繁体字形):打包霞鹜文楷 TC 优先,系统 Kaiti TC 回退。
    private static var kaitiTCName: String? {
        if let cached = _kaitiTCCache { return cached }
        let found = firstAvailableFont(["LXGWWenKaiTC-Regular", "Kaiti TC", "STKaitiTC-Regular"])
        if let found { _kaitiTCCache = found }
        return found
    }

    private static var _stkaitiCache: String?
    /// "STKaiti" 旧名兜底(D7 保留)。
    private static var stkaitiName: String? {
        if let cached = _stkaitiCache { return cached }
        let found = firstAvailableFont(["STKaiti"])
        if let found { _stkaitiCache = found }
        return found
    }

    /// 当前语言应用的楷体名(zh-hant → Kaiti TC,缺失回落 SC 再回落 STKaiti;
    /// zh / en 品牌字维持 Kaiti SC 路径)。语言实时判定,切换后下次取值即生效。
    private static var kaitiName: String? {
        if AppLanguage.current == .zhHant {
            return kaitiTCName ?? kaitiSCName ?? stkaitiName
        }
        return kaitiSCName ?? stkaitiName
    }

    /// 当前 UI 是否中文(AppLanguage 实时判定,系统语言切换后下次取值即生效)。
    /// zh 与 zh-hant 均走中文;zh-hant 在 kaitiName 分流 Kaiti TC(D7)。
    private static var isChineseUI: Bool { AppLanguage.current.isChinese }

    /// 楷体字体。kaitiName 不可用时回退系统 .serif(Songti SC),保证永远有衬线兜底。
    private static func kaiti(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        if let name = kaitiName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// 宋体名探测(「图内宋」hero 题记用,2026-08-31 glass-v2 分层):
    /// 打包思源宋体子集(QiSongti)优先,系统 Songti SC / STSong 回退。
    private static var _songtiCache: String?
    private static var songtiName: String? {
        if let cached = _songtiCache { return cached }
        let found = firstAvailableFont(["QiSongti-Regular", "Songti SC", "STSongti-SC-Regular", "STSong"])
        if let found { _songtiCache = found }
        return found
    }

    /// 图内题记字体(2026-08-31 glass-v2 拍板:图内中文 = 宋体,刻本气质;
    /// 解读框等其余展示层仍楷体——「图内宋/文中楷」分层,DESIGN.md 补录)。
    /// 英文 locale 走系统 .serif(New York 系)。缺失时回退系统 .serif 永不裸奔。
    static func songDisplay(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        guard isChineseUI else {
            return .system(size: size, weight: weight, design: .serif)
        }
        if let name = songtiName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    /// 显示字体(中文 Kaiti / 英文系统衬线)。楷体笔画细,展示层默认 Medium。
    static func display(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        guard isChineseUI else {
            return .system(size: size, weight: weight, design: .serif)
        }
        return kaiti(size: size, weight: weight)
    }

    /// 八字专用干支字体(与 display 同族;干支为中文术语,始终走 display 路由)。
    static func ganzhi(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        display(size: size, weight: weight)
    }

    /// 品牌层字体(**始终 Kaiti,不走 EN 路由**):干支题款/印章/品牌字用。
    /// display 在 EN locale 落系统衬线,而 DESIGN.md「品牌字(玄机问道/干支/
    /// 印章)不走本路由,始终楷体」——hero 落款竖排汉字(2026-10-01 Today
    /// 定稿 D1)需要跨语言稳定的楷形。探测失败同 kaiti() 回退衬线,永不裸奔。
    static func brush(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        kaiti(size: size, weight: weight)
    }

    /// 命书正文(中文 Kaiti / 英文系统 sans;阅读页 16pt 行距 ~1.65× 由调用侧 lineSpacing 控制,2026-10-09 改版)。
    static func body(size: CGFloat = 16) -> Font {
        guard isChineseUI, let name = kaitiName else {
            return .system(size: size)
        }
        return .custom(name, size: size)
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
