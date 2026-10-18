import SwiftUI
import UIKit
import Observation

/// 统一字体入口(DESIGN.md §Typography,2026-08-26 水墨孤本换轨 + 英文 locale 路由)。
///
/// DESIGN.md §Typography 落地:
/// - **Display / Ganzhi / Heading / Body(中文 UI)**:`Kaiti SC`(楷体,**iOS 系统
///   可下载字体,启动时按需下载,不打包**——2026-10-18 S1 修订,原「系统自带」说法不实:
///   真机探测 8 个楷体/宋体名全 false,模拟器带字体而真机不带,此前视觉验收全在模拟器)。
///   楷体扛全部中文展示层,书卷手写感呼应水墨孤本。命名缺失时 Font.custom 静默回退系统字体,
///   以 `UIFont(name:)` 家族名+PostScript 名双探测结果为准(备选名 "STKaiti")。
/// - **英文 locale 路由(2026-08-26,DESIGN.md Decisions Log)**:Kaiti 拉丁字形偏楷书衬线,
///   英文正文可读性差——display/heading 回退系统 `.serif`(New York 系,气质匹配水墨),
///   body 走系统 sans。品牌字(玄机问道/干支/印章)不走本路由,始终楷体(中文不翻译,决策 7)。
/// - **Numeric / Tabular**:系统默认 + `.monospacedDigit()`(SF Pro Text)。
/// - **LatinCaps**:QICOMPASS 字距标(system + 调用侧 .tracking 大间距)。
///
/// 历史:宋瓷时代 display 走系统 `.serif`(Songti SC)——2026-08-26 换轨为 Kaiti SC。
/// 仓库曾尝试 ZCOOL XiaoWei 打包,已废弃(免打包决策不变)。`zcool*` API 名保留作 alias。

/// 系统字体安装状态(S1,2026-10-18):可下载字体装好时在主队列 bump `revision`,
/// `RootTabView.body` 读一次 revision 建立 Observation 依赖 → 全树重渲染,
/// `Font.custom` 重新解析到楷体/宋体。**不用 `.id(revision)` 重建视图树**
/// (会丢导航状态与 onboarding 进度,plan §S1.1)。
@Observable
final class FontAvailability {
    static let shared = FontAvailability()

    /// 每次字体安装完成 +1。View body 里读它即建立依赖。
    private(set) var revision = 0

    private init() {}

    /// 仅供下载回调(主队列)调用。
    func markChanged() {
        revision += 1
    }
}

enum BaziFont {
    // MARK: - 字体名探测(S1,2026-10-18)

    /// 名字探测:返回第一个 `UIFont(name:)` 能命中的名字(家族名与 PostScript 名
    /// UIFont 都收,但真机只有下载后的名字会命中,见 S1.0 探测)。
    private static func firstAvailableFont(_ names: [String]) -> String? {
        names.first { UIFont(name: $0, size: 12) != nil }
    }

    /// 楷体名缓存语义(2026-10-18 S1 修订):**命中即缓存,nil 不缓存**——
    /// 原 `static let` 把首次探测的 nil 永久钉死,真机缺字体时下载完成也永远回退。
    /// 下载完成后下次取值重新探测即命中。约定主线程取值(SwiftUI body / Font 构造)。
    private static var _kaitiSCCache: String?
    private static var kaitiSCName: String? {
        if let cached = _kaitiSCCache { return cached }
        let found = firstAvailableFont(["Kaiti SC", "STKaitiSC-Regular"])
        if let found { _kaitiSCCache = found }
        return found
    }

    private static var _kaitiTCCache: String?
    private static var kaitiTCName: String? {
        if let cached = _kaitiTCCache { return cached }
        let found = firstAvailableFont(["Kaiti TC", "STKaitiTC-Regular"])
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

    /// 宋体名探测(「图内宋」hero 题记用,2026-08-31 glass-v2 分层)。
    /// 缓存语义同楷体:命中即缓存,nil 不缓存(S1,2026-10-18)。
    private static var _songtiCache: String?
    private static var songtiName: String? {
        if let cached = _songtiCache { return cached }
        let found = firstAvailableFont(["Songti SC", "STSongti-SC-Regular", "STSong"])
        if let found { _songtiCache = found }
        return found
    }

    // MARK: - 可下载字体(S1,2026-10-18)

    /// 启动时按需下载系统字体:楷体/宋体是 iOS **可下载**字体,真机默认不带
    /// (2026-10-18 真机探测实证:家族名+PostScript 名 8 个全 false,模拟器才自带)。
    /// CoreText 官方下载 API,零依赖。失败显式打 error 日志并保留回退字体,
    /// 下次启动重试;成功后主队列 bump `FontAvailability.revision` 通知界面重渲染。
    ///
    /// ⚠️ 实测边界(2026-10-18,iPhone 16 Pro / iOS 27.2 真机):该 API 对所有
    /// 名字写法(PostScript 名 / 目录全名 / 旧名)都毫秒级 didFinish「成功」但
    /// TotalAssetSize=0,字体从未落盘——iOS 27 上是空操作(对旧版 iOS 仍可能
    /// 生效)。终极方案 = 打包霞鹜文楷(S1b,用户 2026-10-18 拍板),本函数作为
    /// 旧 OS 上的尽力而为增强保留。
    static func ensureDownloadableFonts() {
        // (探测名族, 下载候选名):探测名族含家族名,任一命中即视为已装;
        // 下载候选 = Apple 可下载字体目录里的条目名(目录名是全名如
        // "Kaiti SC Regular" 与旧单字重名 "STKaiti"/"STSong",2026-10-18 核对
        // developer.apple.com/fonts/system-fonts)。用非目录名(如 PostScript 名
        // "STKaitiSC-Regular")请求同样 0 字节空成功。
        let wanted: [(probes: [String], candidates: [String])] = [
            (["Kaiti SC", "STKaitiSC-Regular"], ["Kaiti SC Regular", "STKaiti"]),
            (["Kaiti TC", "STKaitiTC-Regular"], ["Kaiti TC Regular"]),
            (["Songti SC", "STSongti-SC-Regular", "STSong"], ["Songti SC Regular", "STSong"]),
        ]
        let missing = wanted.filter { $0.probes.allSatisfy { UIFont(name: $0, size: 12) == nil } }
        guard !missing.isEmpty else { return }
        AppLogger.app.info("op=fontDownload.start missing=\(missing.map { $0.probes[0] }.joined(separator: ","), privacy: .public)")
        let descriptors = missing.flatMap { entry in
            entry.candidates.map {
                CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: $0] as CFDictionary)
            }
        }
        // info 即进度字典本身(本工具链 audited import 把 CFDictionaryRef block
        // 参数导入为 CFDictionary?,String(describing:) 直接打内容)——错误载荷在
        // kCTFontDescriptorMatchingError,诊断键如 TotalAssetSize 同在。
        let matchStarted = CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descriptors as CFArray, nil) { state, info in
            switch state {
            case .didFailWithError:
                // 不吞错:下载失败(无网/无描述符等)显式落日志,UI 走回退字体
                AppLogger.app.error("op=fontDownload.fail state=\(String(describing: state), privacy: .public) info=\(String(describing: info), privacy: .public)")
            case .didFinish:
                AppLogger.app.info("op=fontDownload.didFinish info=\(String(describing: info), privacy: .public)")
                DispatchQueue.main.async { FontAvailability.shared.markChanged() }
            default:
                break
            }
            return true
        }
        // 返回 false = 匹配流程根本没启动(不触发任何回调)——不查就静默吞掉
        if !matchStarted {
            AppLogger.app.error("op=fontDownload.matchStartFailed missing=\(missing.map { $0.probes[0] }.joined(separator: ","), privacy: .public)")
        }
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
