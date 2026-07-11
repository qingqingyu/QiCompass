import SwiftUI

/// 根 TabView:三 Tab(深度解析 / 合盘 / 每日运势)。
/// 视觉 token:主背景渐变 `#0d0b08 → #12100d → #0a0c10`,主金 `#c9a03c`。
struct RootTabView: View {
    @EnvironmentObject private var env: AppEnvironment

    var body: some View {
        TabView {
            DeepAnalysisView()
                .tabItem {
                    Label("深度解析", systemImage: "chart.bar.xaxis")
                }

            CompatibilityView()
                .tabItem {
                    Label("合盘", systemImage: "person.2")
                }

            DailyFortuneView()
                .tabItem {
                    Label("每日运势", systemImage: "sun.max")
                }
        }
        .tint(BaziTheme.gold)
    }
}

// MARK: - BaziTheme

/// 命理主题视觉 token(按设计文档 §Visual Design Tokens)。
/// 脚手架阶段只打底色 + 主金强调,不做字体/动画打磨。
enum BaziTheme {
    static let bgTop     = Color(red: 0x0d/255, green: 0x0b/255, blue: 0x08/255)
    static let bgMid     = Color(red: 0x12/255, green: 0x10/255, blue: 0x0d/255)
    static let bgBottom  = Color(red: 0x0a/255, green: 0x0c/255, blue: 0x10/255)
    static let gold      = Color(red: 0xc9/255, green: 0xa0/255, blue: 0x3c/255)
    static let goldLight = Color(red: 0xf5/255, green: 0xd7/255, blue: 0x85/255)
    static let text      = Color(red: 0xe8/255, green: 0xdc/255, blue: 0xc8/255)
    static let textDim   = Color(red: 0x8a/255, green: 0x80/255, blue: 0x70/255)

    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [bgTop, bgMid, bgBottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
