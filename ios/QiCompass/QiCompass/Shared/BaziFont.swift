import SwiftUI
import UIKit

/// 统一字体入口(DESIGN.md §Typography,水墨孤本 → 2026-10-18 全宋体拍板)。
///
/// DESIGN.md §Typography 落地:
/// - **Display / Ganzhi / Heading / Body / 品牌层(中文 UI)**:宋体 = **打包的思源宋体
///   子集**(SC = `QiSongti-Regular.otf`,GBK 全汉字 + App 全词条;TC =
///   `QiSongtiTC-Regular.otf`,Big5 + App 繁体词条(TW 源无简体字形——zh 串由
///   SC 腿渲染,zh-hant 下偶现简体字回退系统);OFL 保留名 "Source" 故子集改名;
///   `tools/build_songti_fonts.py` 单一事实源)。2026-10-18 晚拍板——同日早间 S1b
///   打包的霞鹜文楷(教科书手写体血统,源自 Klee One)上真机后用户不满:「没有
///   宋体那么好看」;主字体全宋体化(「宋刻孤本」),文楷 SC/TC(41MB)退役,
///   「图内宋/文中楷」分层随之消解为单族。系统名(Songti SC/STSongti)保留在
///   探测序后半作回退。
/// - **英文 locale 路由(2026-08-26)**:宋体拉丁可读,但英文正文走系统 serif
///   (New York 系)更利阅读——display 回退系统 `.serif`,body 走系统 sans。
///   品牌字(玄机问道/干支/印章)不走本路由,始终宋体(中文不翻译,决策 7)。
/// - **Numeric / Tabular**:系统默认 + `.monospacedDigit()`(SF Pro Text)。
/// - **LatinCaps**:QICOMPASS 字距标(system + 调用侧 .tracking 大间距)。
///
/// 历史:宋瓷时代 display 走系统 `.serif`(Songti SC)——2026-08-26 换轨楷体
/// (孤本手抄);真机无楷宋字体 + Apple 下载 API 空成功(S1.0 实证),2026-10-18
/// S1b 打包霞鹜文楷落地,同日晚用户目验后拍板全宋体(思源宋体子集)。`zcool*`
/// API 名保留作 alias。

enum BaziFont {
    // MARK: - 字体名探测(S1b,2026-10-18)

    /// 名字探测:返回第一个 `UIFont(name:)` 能命中的名字(打包字体经 UIAppFonts
    /// 注册后与系统字体同命名空间;探测序 = 打包名优先,系统名回退)。
    private static func firstAvailableFont(_ names: [String]) -> String? {
        names.first { UIFont(name: $0, size: 12) != nil }
    }

    /// 字体名缓存语义:**命中即缓存,nil 不缓存**——晚注册的字体下次取值重新
    /// 探测即命中。约定主线程取值(SwiftUI body / Font 构造)。
    private static var _songtiSCCache: String?
    /// 简体宋体:打包思源宋体子集(QiSongti)优先,系统 Songti SC / STSong 回退。
    private static var songtiSCName: String? {
        if let cached = _songtiSCCache { return cached }
        let found = firstAvailableFont(["QiSongti-Regular", "Songti SC", "STSongti-SC-Regular", "STSong"])
        if let found { _songtiSCCache = found }
        return found
    }

    private static var _songtiTCCache: String?
    /// 繁体宋体(D7:繁体字形):打包 QiSongtiTC 优先,系统 Songti TC 回退。
    private static var songtiTCName: String? {
        if let cached = _songtiTCCache { return cached }
        let found = firstAvailableFont(["QiSongtiTC-Regular", "Songti TC", "STSongtiTC-Regular"])
        if let found { _songtiTCCache = found }
        return found
    }

    /// 当前语言应用的宋体名(zh-hant → QiSongtiTC,缺失回落 SC;zh / en 品牌字
    /// 维持 SC 路径)。语言实时判定,切换后下次取值即生效。
    private static var songtiName: String? {
        if AppLanguage.current == .zhHant {
            return songtiTCName ?? songtiSCName
        }
        return songtiSCName
    }

    /// 当前 UI 是否中文(AppLanguage 实时判定,系统语言切换后下次取值即生效)。
    /// zh 与 zh-hant 均走中文;zh-hant 在 songtiName 分流 QiSongtiTC(D7)。
    private static var isChineseUI: Bool { AppLanguage.current.isChinese }

    /// 宋体字体。songtiName 不可用时回退系统 .serif(Songti SC),保证永远有衬线兜底。
    /// 思源宋体仅打包 Regular 一档(对齐 S1b 拍板①;weight 参数只作用于回退分支)。
    private static func songti(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if let name = songtiName {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: weight, design: .serif)
    }

    // MARK: - 语义字体(全宋体后单一字族,2026-10-18)

    /// 显示字体(中文宋体 / 英文系统衬线;默认 Medium——作用于 EN 回退分支,
    /// 打包宋体仅 Regular 一档,对齐 S1b 拍板①)。
    static func display(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        guard isChineseUI else {
            return .system(size: size, weight: weight, design: .serif)
        }
        return songti(size: size, weight: weight)
    }

    /// 八字专用干支字体(与 display 同族;干支为中文术语,始终走 display 路由)。
    static func ganzhi(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        display(size: size, weight: weight)
    }

    /// 品牌层字体(**始终宋体,不走 EN 路由**):干支题款/印章/品牌字用。
    /// display 在 EN locale 落系统衬线,而 DESIGN.md「品牌字(玄机问道/干支/
    /// 印章)不走本路由,始终中文字形」——hero 落款竖排汉字(2026-10-01 Today
    /// 定稿 D1)需要跨语言稳定的字形。探测失败同 songti() 回退衬线,永不裸奔。
    static func brush(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        songti(size: size, weight: weight)
    }

    /// 图内题记字体(2026-08-31 glass-v2 引入「图内宋」;2026-10-18 全宋体后与
    /// display 同族同链,API 保留防调用侧 churn)。英文 locale 走系统 .serif。
    static func songDisplay(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        display(size: size, weight: weight)
    }

    /// 命书正文(中文宋体 / 英文系统 sans;阅读页 16pt 行距 ~1.65× 由调用侧 lineSpacing 控制,2026-10-09 改版)。
    static func body(size: CGFloat = 16) -> Font {
        guard isChineseUI, let name = songtiName else {
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

    /// 按钮(系统默认半粗;宋体按钮字重不足,按钮仍走系统字)。
    static func button(size: CGFloat = 16) -> Font {
        .system(size: size, weight: .semibold)
    }

    /// 说明文字(系统默认小号)。
    static func caption(size: CGFloat = 12) -> Font {
        .system(size: size)
    }

    // MARK: - 旧 API alias(渐进重构)

    /// 旧 zcoolTitle → display。
    static func zcoolTitle(size: CGFloat) -> Font {
        display(size: size)
    }

    /// 旧 bodySerif → body。
    static func bodySerif(size: CGFloat = 16) -> Font {
        body(size: size)
    }
}

extension View {
    /// 页面标题样式(宋体 + 浓墨,DESIGN.md §Display)。
    func zcoolPageTitle(size: CGFloat = 24) -> some View {
        font(BaziFont.display(size: size))
            .foregroundStyle(BaziTheme.ink)
    }

    /// 卡片标题样式(宋体 + 浓墨,小一号,DESIGN.md §Heading)。
    func zcoolCardTitle(size: CGFloat = 17) -> some View {
        font(BaziFont.display(size: size))
            .foregroundStyle(BaziTheme.ink)
    }

    /// 命书正文样式(宋体 + 浓墨,DESIGN.md §Body)。
    func bodySerifText(size: CGFloat = 16) -> some View {
        font(BaziFont.body(size: size))
            .foregroundStyle(BaziTheme.ink)
    }
}
