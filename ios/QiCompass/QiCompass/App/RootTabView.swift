import SwiftUI

/// 根 TabView:四 Tab(今日运势 / 深度解析 / 合盘 / 我的)。
/// 视觉 token(DESIGN.md §现代东方极简 · 宋瓷气质):主背景极浅暖白 `#FDFCFA`,主强调朱砂 `#C33B3B`。
///
/// 2026-08-01 grill-me 决策:
/// - 默认 Tab 改为 `.dailyFortune`(原 `.deepAnalysis`)。今日运势是视觉入口 + 高频回访。
/// - Tab 顺序:今日运势在最左(默认选中位置),深度解析第二,合盘第三,**"我的"第四**(决策 #17)。
///
/// 2026-08-13 onboarding 三屏重构:
/// - 6 屏压成 3 屏:Welcome → 出生表单(嵌 onboarding sheet 第 2 页)→ 生肖反馈(终态屏)。
///   原 fullScreenCover 表单流删除。
/// - showOnboarding 与 hasSeenOnboarding 解耦:hasSeenOnboarding 只做「下次启动还弹不弹」
///   gate;sheet 显示由 showOnboarding 独立控制。提交成功 → hasSeenOnboarding=true(修复
///   "反馈屏 kill App → 重启重走 onboarding → 重复排盘" bug);CTA 点击 → dismiss + 落地今日运势。
///
/// 监听 `.switchTab` Notification(决策 D3):合盘空态 CTA → 切到深度解析。
struct RootTabView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedTab: Tab = .dailyFortune
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    /// onboarding sheet 显示状态(2026-08-13 与 hasSeenOnboarding 解耦)。
    /// 启动时 !hasSeenOnboarding → true;反馈屏 CTA 点击 → false。
    @State private var showOnboarding = false

    /// 冷启动品牌转场(水墨孤本开机页,DESIGN.md §Motion)。每次冷启动播放,1.6s 内淡出。
    @State private var showSplash = true

    enum Tab: Hashable {
        case dailyFortune
        case deepAnalysis
        case compatibility
        case profile

        /// 对应 .switchTab Notification 的 userInfo["tab"] 字符串。
        /// 集中映射,避免字符串散落在 post / 监听两侧。
        var switchKey: String {
            switch self {
            case .dailyFortune:  return "dailyFortune"
            case .deepAnalysis:  return "deepAnalysis"
            case .compatibility: return "compatibility"
            case .profile:       return "profile"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DailyFortuneView()
                .tag(Tab.dailyFortune)
                .tabItem {
                    // 水墨孤本:纯文字 tab(DESIGN.md §Layout),不用 SF Symbol 图标
                    Text("今日")
                }

            DeepAnalysisView()
                .tag(Tab.deepAnalysis)
                .tabItem {
                    Text("深度")
                }

            CompatibilityView()
                .tag(Tab.compatibility)
                .tabItem {
                    Text("合盘")
                }

            ProfileView()
                .tag(Tab.profile)
                .tabItem {
                    Text("我的")
                }
        }
        .tint(BaziTheme.ink)
        // 纸纹:全 App 一次,overlay 在内容上(multiply 混合,不挡交互)
        .overlay(PaperGrain())
        // 冷启动品牌转场(DESIGN.md §Motion 三式:ink-in + stamp,1.6s 内淡出不阻塞)
        .overlay {
            if showSplash {
                SplashTransitionView(onFinished: { showSplash = false })
            }
        }
        .onAppear {
            // 首启 / 后续启动分流日志,便于定位"onboarding 没弹 / 反复弹"等异常
            AppLogger.app.info("RootTabView.onAppear hasSeenOnboarding=\(hasSeenOnboarding, privacy: .public) selectedTab=\(selectedTab.switchKey, privacy: .public)")
            // 2026-08-13:首启(未看过 onboarding)弹三屏 onboarding sheet。
            // showOnboarding 独立于 hasSeenOnboarding,提交成功不再自动 dismiss(否则反馈屏没机会展示)。
            if !hasSeenOnboarding {
                showOnboarding = true
            }
            // PR3.2:App 启动(若已登录)→ 后台静默 pull(同步云端命盘)
            Task { await env.syncManager.pull() }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(
                onComplete: {
                    // 反馈屏 CTA 点击 → chart 已存档。dismiss sheet + 落地今日运势。
                    AppLogger.app.info("OnboardingView onComplete 触发 → dismiss sheet + 落地 .dailyFortune")
                    showOnboarding = false
                    selectedTab = .dailyFortune
                },
                onChartArchived: {
                    // 提交成功(chart 已存档)即设 true:kill 重启后不再重走 onboarding,
                    // 避免重复排盘存档两张盘。反馈屏中途退出 = 错过 reveal 但可接受(盘已在)。
                    AppLogger.app.info("OnboardingView onChartArchived 触发 → hasSeenOnboarding=true")
                    hasSeenOnboarding = true
                }
            )
            .environmentObject(env)
            .interactiveDismissDisabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchTab)) { note in
            // guard 失败也要打日志:之前 silent return,出问题排查无据
            guard let raw = note.userInfo?["tab"] as? String else {
                AppLogger.app.error("收到 .switchTab 通知但 userInfo 无 tab 字段,忽略 userInfoKeys=\(String(describing: note.userInfo?.keys), privacy: .public)")
                return
            }
            AppLogger.app.info("收到 .switchTab tab=\(raw, privacy: .public)")
            switch raw {
            case Tab.dailyFortune.switchKey:  selectedTab = .dailyFortune
            case Tab.deepAnalysis.switchKey:  selectedTab = .deepAnalysis
            case Tab.compatibility.switchKey: selectedTab = .compatibility
            case Tab.profile.switchKey:       selectedTab = .profile
            default:
                AppLogger.app.error(".switchTab 收到未知 tab=\(raw, privacy: .public),忽略")
            }
        }
    }
}

// MARK: - BaziTheme

/// 命理主题视觉 token(DESIGN.md §水墨孤本 · 全局唯一色值事实源,2026-08-26 换轨)。
///
/// 所有 token 直接映射 DESIGN.md §Color 色板。五行色走 `ElementColors`。
/// Capsule 只留给 chip;其余圆角默认 4pt(见 `BaziTheme.Radius.sm`)。
/// **朱红纪律**:`cinnabar` 为印章级专用(SealStamp / 付费标 / 聚焦线 / 当前时辰点 / 在读态),
/// 禁止 CTA 与大面积底色;CTA 一律 `inkDeep` 底 + `onInkDeep` 字(成对使用,暗色反转)。
enum BaziTheme {
    // MARK: - DESIGN.md §Color 主事实源(Light + Dark 双值,夜宣纸配色)

    /// 动态色 helper:traitCollection 切换时自动 Light/Dark 反转。
    /// 色值仍集中在 RootTabView.swift 单文件,与 DESIGN.md §Color 一一对应(单一事实源)。
    /// internal:ElementColors.swift 等处的 BaziTheme 扩展共用同一实现,避免 dyn 散两份。
    static func dyn(_ light: Color, _ dark: Color) -> Color {
        Color(uiColor: UIColor { tc in
            tc.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    /// 主背景。Light 冷灰宣纸 / Dark 夜宣纸(冷调,非暖墨)。
    static let paper         = dyn(Color(red: 0xF3/255, green: 0xF1/255, blue: 0xEC/255),
                                   Color(red: 0x14/255, green: 0x13/255, blue: 0x17/255))
    /// sheet 底 / 残留卡底。水墨语言下卡片让位 hairline,此 token 逐步收缩到 sheet 与锁框。
    static let cardSurface   = dyn(Color(red: 0xF7/255, green: 0xF5/255, blue: 0xF0/255),
                                   Color(red: 0x1E/255, green: 0x1D/255, blue: 0x23/255))
    /// 主文字。Light 浓墨(冷黑)/ Dark 冷白(非暖白)。
    static let ink           = dyn(Color(red: 0x1C/255, green: 0x1B/255, blue: 0x1E/255),
                                   Color(red: 0xE9/255, green: 0xE7/255, blue: 0xE2/255))
    /// 弱说明文字。
    static let inkMuted      = dyn(Color(red: 0x77/255, green: 0x72/255, blue: 0x6A/255),
                                   Color(red: 0x9B/255, green: 0x96/255, blue: 0x8C/255))
    /// 二级弱注(比 inkMuted 更弱的标签 / 元信息)。
    static let inkMutedSecondary = dyn(Color(red: 0xA5/255, green: 0xA0/255, blue: 0x98/255),
                                       Color(red: 0x6E/255, green: 0x6A/255, blue: 0x62/255))
    /// 焦墨 CTA 底 / enso 笔触。Dark 反转为冷白底(与 onInkDeep 成对使用)。
    static let inkDeep       = dyn(Color(red: 0x17/255, green: 0x16/255, blue: 0x1A/255),
                                   Color(red: 0xE9/255, green: 0xE7/255, blue: 0xE2/255))
    /// CTA 前景(inkDeep 的反色伴生 token)。
    static let onInkDeep     = dyn(Color(red: 0xF3/255, green: 0xF1/255, blue: 0xEC/255),
                                   Color(red: 0x17/255, green: 0x16/255, blue: 0x1A/255))
    /// 印章朱红。**印章级专用,禁止 CTA / 大面积底色**(DESIGN.md §Color)。Dark 提亮保持识别。
    static let cinnabar      = dyn(Color(red: 0xA8/255, green: 0x32/255, blue: 0x26/255),
                                   Color(red: 0xC2/255, green: 0x51/255, blue: 0x43/255))
    /// 朱砂淡(选中态底色,极少量场景)。opacity 跟随 cinnabar 自动反转。
    static let cinnabarSoft  = cinnabar.opacity(0.10)
    /// 次强调 / 吉向 / 好朋友 chip / 宜(墨青)。Dark 提亮保持识别。
    static let jade          = dyn(Color(red: 0x2F/255, green: 0x5E/255, blue: 0x4A/255),
                                   Color(red: 0x6F/255, green: 0xA0/255, blue: 0x8A/255))
    /// 三强调 / 水行 / 链接(黛墨蓝,降饱和)。Dark 提亮保持识别。
    static let daiBlue       = dyn(Color(red: 0x3D/255, green: 0x4A/255, blue: 0x5C/255),
                                   Color(red: 0x7E/255, green: 0x93/255, blue: 0xAC/255))
    /// 0.5-1pt hairline。opacity 跟随 ink 自动反转。
    static let hairline      = ink.opacity(0.18)
    /// 虚线 hairline(锁定框 / 临时态 / 未登录框,dash [4,3])。
    static let hairlineDashed = inkMuted.opacity(0.35)
    /// 错误 / 破坏性操作(iOS `.destructive` 习惯,与 cinnabar 同值,语义独立便于未来调色)。
    static let destructive   = dyn(Color(red: 0xA8/255, green: 0x32/255, blue: 0x26/255),
                                   Color(red: 0xC2/255, green: 0x51/255, blue: 0x43/255))
}

// MARK: - BaziTheme.Spacing / Radius

extension BaziTheme {
    /// 8pt 基准 spacing 网格(DESIGN.md §Spacing)。
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        /// compact-md,表格高密度场景专用(非标准 8pt 网格值,实测期批准)。
        static let cmd: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }
    /// 圆角克制层级(DESIGN.md §Layout)。
    enum Radius {
        /// 按钮 / 卡片默认。
        static let sm: CGFloat = 4
        /// 大卡片 / sheet。
        static let md: CGFloat = 8
        /// Modal。
        static let lg: CGFloat = 12
    }
}
