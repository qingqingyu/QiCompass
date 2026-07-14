import SwiftUI

/// 根 TabView:三 Tab(深度解析 / 合盘 / 每日运势)。
/// 视觉 token(DESIGN.md §现代东方极简 · 宋瓷气质):主背景宣纸米 `#f5efe1`,主强调朱砂 `#c33b3b`。
///
/// 监听 `.switchTab` Notification(决策 D3):合盘空态 CTA → 切到深度解析。
struct RootTabView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedTab: Tab = .deepAnalysis
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    enum Tab: Hashable {
        case deepAnalysis
        case compatibility
        case dailyFortune
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            DeepAnalysisView()
                .tag(Tab.deepAnalysis)
                .tabItem {
                    Label("深度解析", systemImage: "chart.bar.xaxis")
                }

            CompatibilityView()
                .tag(Tab.compatibility)
                .tabItem {
                    Label("合盘", systemImage: "person.2")
                }

            DailyFortuneView()
                .tag(Tab.dailyFortune)
                .tabItem {
                    Label("每日运势", systemImage: "sun.max")
                }
        }
        .tint(BaziTheme.cinnabar)
        .sheet(isPresented: Binding(
            get: { !hasSeenOnboarding },
            set: { newValue in
                if !newValue { hasSeenOnboarding = true }
            }
        )) {
            OnboardingView(onComplete: {
                hasSeenOnboarding = true
            })
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchTab)) { note in
            guard let raw = note.userInfo?["tab"] as? String else { return }
            switch raw {
            case "deepAnalysis":  selectedTab = .deepAnalysis
            case "compatibility": selectedTab = .compatibility
            case "dailyFortune":  selectedTab = .dailyFortune
            default: break
            }
        }
    }
}

// MARK: - BaziTheme

/// 命理主题视觉 token(DESIGN.md §现代东方极简 · 宋瓷气质 · 全局唯一色值事实源)。
///
/// 所有 token 直接映射 DESIGN.md §Color 色板。五行色走 `ElementColors`。
/// Capsule 只留给 chip;其余圆角默认 4pt(见 `BaziTheme.Radius.sm`)。
enum BaziTheme {
    // MARK: - DESIGN.md §Color 主事实源

    /// 主背景(宣纸米,替代黑渐变)。
    static let paper         = Color(red: 0xF5/255, green: 0xEF/255, blue: 0xE1/255)
    /// 卡片底色(浅宣)。
    static let cardSurface   = Color(red: 0xEB/255, green: 0xE3/255, blue: 0xD0/255)
    /// 主文字(浓墨)。
    static let ink           = Color(red: 0x1C/255, green: 0x1C/255, blue: 0x1C/255)
    /// 弱说明文字(灰墨)。
    static let inkMuted      = Color(red: 0x6B/255, green: 0x65/255, blue: 0x57/255)
    /// 主强调 / CTA / 当前柱(朱砂红)。
    static let cinnabar      = Color(red: 0xC3/255, green: 0x3B/255, blue: 0x3B/255)
    /// 朱砂淡(当前柱 / 选中态底色)。
    static let cinnabarSoft  = cinnabar.opacity(0.08)
    /// 次强调 / 吉神 / 木行(墨青)。
    static let jade          = Color(red: 0x2C/255, green: 0x5F/255, blue: 0x3F/255)
    /// 三强调 / 水行 / 链接(黛蓝)。
    static let daiBlue       = Color(red: 0x1D/255, green: 0x3A/255, blue: 0x5F/255)
    /// 0.5pt 细线(灰墨 @ 30%)。
    static let hairline      = Color(red: 0x6B/255, green: 0x65/255, blue: 0x57/255).opacity(0.3)
}

// MARK: - BaziTheme.Spacing / Radius

extension BaziTheme {
    /// 8pt 基准 spacing 网格(DESIGN.md §Spacing)。
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
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
