import SwiftUI

/// 根 TabView:四 Tab(今日运势 / 深度解析 / 合盘 / 我的)。
/// 视觉 token(DESIGN.md §现代东方极简 · 宋瓷气质):主背景极浅暖白 `#FDFCFA`,主强调朱砂 `#C33B3B`。
///
/// 2026-08-01 grill-me 决策:
/// - 默认 Tab 改为 `.dailyFortune`(原 `.deepAnalysis`)。今日运势是视觉入口 + 高频回访。
/// - Tab 顺序:今日运势在最左(默认选中位置),深度解析第二,合盘第三,**"我的"第四**(决策 #17)。
/// - Onboarding 流改 B2:StartPage CTA 后**不**直接 dismiss,而是呈现 FirstLaunchBirthFormView
///   作为 fullScreenCover;表单提交成功(只触发排盘,不跑深度解析 AI)后才 dismiss 全部 + 落地今日运势。
///
/// 监听 `.switchTab` Notification(决策 D3):合盘空态 CTA → 切到深度解析。
struct RootTabView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var selectedTab: Tab = .dailyFortune
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    /// B2 流:StartPage CTA 点击后呈现出生表单 fullScreenCover。
    /// hasSeenOnboarding 保持 false 直到表单提交成功,确保中途 kill 进程后下次重启仍走 onboarding。
    @State private var showFirstLaunchForm = false

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
                    Label("每日运势", systemImage: "sun.max")
                }

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

            ProfileView()
                .tag(Tab.profile)
                .tabItem {
                    Label("我的", systemImage: "person.crop.circle")
                }
        }
        .tint(BaziTheme.cinnabar)
        .onAppear {
            // 首启 / 后续启动分流日志,便于定位"onboarding 没弹 / 反复弹"等异常
            AppLogger.app.info("RootTabView.onAppear hasSeenOnboarding=\(hasSeenOnboarding, privacy: .public) selectedTab=\(selectedTab.switchKey, privacy: .public)")
            // PR3.2:App 启动(若已登录)→ 后台静默 pull(同步云端命盘)
            Task { await env.syncManager.pull() }
        }
        .sheet(isPresented: Binding(
            get: { !hasSeenOnboarding && !showFirstLaunchForm },
            set: { newValue in
                // isPresented 变化都打:呈现(true)/ dismiss(false)
                AppLogger.app.info("Onboarding sheet isPresented=\(newValue, privacy: .public) hasSeenOnboarding=\(hasSeenOnboarding, privacy: .public) showFirstLaunchForm=\(showFirstLaunchForm, privacy: .public)")
                // B2 流:sheet 不主动设 hasSeenOnboarding(改由 FirstLaunchBirthFormView 表单提交成功设)。
                // 仅打日志,实际 dismiss 由 hasSeenOnboarding 翻 true 驱动。
            }
        )) {
            OnboardingView(onComplete: {
                // StartPage CTA 点击 → 进入 B2 出生表单流(不设 hasSeenOnboarding)
                AppLogger.app.info("OnboardingView onComplete 触发 → 进入 B2 出生表单流")
                showFirstLaunchForm = true
            })
            .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $showFirstLaunchForm) {
            FirstLaunchBirthFormView(
                onComplete: {
                    // 表单提交成功 → chart 已存档。dismiss 全部 + 落地今日运势。
                    AppLogger.app.info("FirstLaunchBirthFormView onComplete 触发 → hasSeenOnboarding=true + 落地 .dailyFortune")
                    hasSeenOnboarding = true
                    showFirstLaunchForm = false
                    selectedTab = .dailyFortune
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

// MARK: - FirstLaunchBirthFormView(B2 强制轻注册)

/// B2 流的出生表单容器(2026-08-01 grill-me 决策 #12)。
///
/// 包装 BirthFormView + 状态观察。提交成功(vm.state → .ready)时调用 onComplete,
/// 由 RootTabView 落地今日运势 + dismiss 全部覆盖层。
///
/// 关键约束:
/// - 只触发 `/api/bazi/calculate` 排盘 + chart 存档(orchestrator.runCalculation)
/// - **不**触发 `/api/interpret`(深度解析 AI 命书延后到用户主动进深度解析 Tab 触发,β 点击触发)
/// - 用户中途 kill 进程 → hasSeenOnboarding 仍为 false → 下次重启重新走 onboarding(可接受)
/// - chart 创建失败 → 显示 ErrorStateView + 重试,不进入主 App(用户必须有 chart 才能用)
private struct FirstLaunchBirthFormView: View {
    @EnvironmentObject private var env: AppEnvironment
    let onComplete: () -> Void

    @State private var vm: DeepAnalysisViewModel?
    /// 防止 ready → onAppear 多次触发 onComplete(SwiftUI 重渲染时 onAppear 可重复调用)。
    @State private var hasTriggeredComplete = false

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("开始排盘")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
        }
        .task {
            if vm == nil {
                let newVM = DeepAnalysisViewModel(
                    orchestrator: env.deepAnalysisOrchestrator,
                    entitlementStore: env.entitlementStore
                )
                // B2 流不消费 pendingReturnTab(没有"原 Tab"可切回);onChartArchived 留 nil。
                vm = newVM
                AppLogger.app.info("FirstLaunchBirthFormView VM 创建完成")
            }
        }
    }

    @ViewBuilder
    @MainActor
    private var content: some View {
        if let vm {
            switch vm.state {
            case .empty, .formInvalid:
                BirthFormView(vm: vm, onSubmit: vm.calculate)
            case .calculating(let stage):
                LoadingStateView(title: stage.text)
            case .ready:
                // 排盘成功 → chart 已存档。呈现生肖反馈屏(Q11 β + Q15 盖章动效)。
                // 用户主动点 CTA 触发 onComplete → RootTabView 落地今日运势 + dismiss 全部覆盖层。
                // hasTriggeredComplete 防护:SwiftUI 重渲染时确保 onComplete 只触发一次(副作用幂等契约)。
                let zodiac = tempZodiacData(
                    forBirthYear: Calendar.current.component(.year, from: vm.birthDate),
                    gender: vm.gender
                )
                ZodiacRevealView(
                    zodiacAssetName: zodiac.asset,
                    mainLabel: zodiac.main,
                    subLabel: zodiac.sub,
                    onComplete: {
                        guard !hasTriggeredComplete else {
                            AppLogger.app.warning("ZodiacRevealView onComplete 已触发过,跳过重复调用")
                            return
                        }
                        hasTriggeredComplete = true
                        AppLogger.app.info("ZodiacRevealView CTA 点击 → 触发 onComplete")
                        onComplete()
                    }
                )
            case .chartFailed(let userError):
                ErrorStateView(error: userError, retry: vm.retryCalculation)
            }
        } else {
            ProgressView()
                .tint(BaziTheme.cinnabar)
        }
    }

    // MARK: - 阶段 4 mock:客户端生肖推导

    /// **TEMPORARY**:阶段 4(本 slice)的 mock 客户端生肖推导。
    ///
    /// 阶段 2 数据层就绪后,从 `BaziResponse.year_branch_zodiac` + `year_pillar_gan_zhi`
    /// 取值,删除此 helper。当前为开发期正确性(避免 dev 看到固定 mock 困惑)。
    ///
    /// **已知边界 bug**:1月-2月初出生的用户,公历年 ≠ 立春后的农历年,生肖可能差 1 年。
    /// 后端 `lunar_python` 按立春算,阶段 2 wire up 后自动修正。
    ///
    /// 算法:1984 = 甲子鼠年(基准)。`animalIdx = (year % 12 + 8) % 12`,`ganzhiIdx = ((year - 1984) % 60 + 60) % 60`。
    private func tempZodiacData(
        forBirthYear year: Int,
        gender: String
    ) -> (asset: String, main: String, sub: String) {
        let animals = ["Rat", "Ox", "Tiger", "Rabbit", "Dragon", "Snake",
                       "Horse", "Goat", "Monkey", "Rooster", "Dog", "Pig"]
        let branches = ["子", "丑", "寅", "卯", "辰", "巳",
                        "午", "未", "申", "酉", "戌", "亥"]
        let animalChars = ["鼠", "牛", "虎", "兔", "龙", "蛇",
                           "马", "羊", "猴", "鸡", "狗", "猪"]
        let ganzhi60 = ["甲子", "乙丑", "丙寅", "丁卯", "戊辰", "己巳", "庚午", "辛未", "壬申", "癸酉",
                        "甲戌", "乙亥", "丙子", "丁丑", "戊寅", "己卯", "庚辰", "辛巳", "壬午", "癸未",
                        "甲申", "乙酉", "丙戌", "丁亥", "戊子", "己丑", "庚寅", "辛卯", "壬辰", "癸巳",
                        "甲午", "乙未", "丙申", "丁酉", "戊戌", "己亥", "庚子", "辛丑", "壬寅", "癸卯",
                        "甲辰", "乙巳", "丙午", "丁未", "戊申", "己酉", "庚戌", "辛亥", "壬子", "癸丑",
                        "甲寅", "乙卯", "丙辰", "丁巳", "戊午", "己未", "庚申", "辛酉", "壬戌", "癸亥"]

        let animalIdx = (year % 12 + 8) % 12
        let ganzhiIdx = ((year - 1984) % 60 + 60) % 60

        let asset = "Zodiac_\(animals[animalIdx])"
        let main = "\(branches[animalIdx]) · \(animalChars[animalIdx])"
        let genderLabel = gender == "male" ? "乾造(男)" : "坤造(女)"
        let sub = "\(genderLabel) · \(ganzhi60[ganzhiIdx])年(\(year))"

        return (asset, main, sub)
    }
}

// MARK: - BaziTheme

/// 命理主题视觉 token(DESIGN.md §现代东方极简 · 宋瓷气质 · 全局唯一色值事实源)。
///
/// 所有 token 直接映射 DESIGN.md §Color 色板。五行色走 `ElementColors`。
/// Capsule 只留给 chip;其余圆角默认 4pt(见 `BaziTheme.Radius.sm`)。
enum BaziTheme {
    // MARK: - DESIGN.md §Color 主事实源(Light + Dark 双值,墨夜瓷釉配色)

    /// 动态色 helper:traitCollection 切换时自动 Light/Dark 反转。
    /// 色值仍集中在 RootTabView.swift 单文件,与 DESIGN.md §Color 一一对应(单一事实源)。
    private static func dyn(_ light: Color, _ dark: Color) -> Color {
        Color(uiColor: UIColor { tc in
            tc.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    /// 主背景。Light 极浅暖白 / Dark 暖墨(非纯黑,保留宋瓷温润感)。
    static let paper         = dyn(Color(red: 0xFD/255, green: 0xFC/255, blue: 0xFA/255),
                                   Color(red: 0x1A/255, green: 0x18/255, blue: 0x15/255))
    /// 卡片底色。Light 浅宣 / Dark 深纸(比 paper 深 1 级,卡片在背景上仍可辨,不靠阴影)。
    static let cardSurface   = dyn(Color(red: 0xEB/255, green: 0xE3/255, blue: 0xD0/255),
                                   Color(red: 0x25/255, green: 0x22/255, blue: 0x1D/255))
    /// 主文字。Light 浓墨 / Dark 暖白(带暖调避免纯白刺眼,呼应 paper 的暖)。
    static let ink           = dyn(Color(red: 0x1C/255, green: 0x1C/255, blue: 0x1C/255),
                                   Color(red: 0xE8/255, green: 0xE0/255, blue: 0xCC/255))
    /// 弱说明文字。Light 灰墨 / Dark 浅灰墨(= Dark ink × 0.72 亮度,保持"弱说明"层级)。
    static let inkMuted      = dyn(Color(red: 0x6B/255, green: 0x65/255, blue: 0x57/255),
                                   Color(red: 0xA8/255, green: 0x9F/255, blue: 0x89/255))
    /// 主强调 / CTA / 当前柱(朱砂红)。Dark 提亮 +6 保持识别。
    static let cinnabar      = dyn(Color(red: 0xC3/255, green: 0x3B/255, blue: 0x3B/255),
                                   Color(red: 0xD4/255, green: 0x4A/255, blue: 0x4A/255))
    /// 朱砂淡(当前柱 / 选中态底色)。opacity 跟随 cinnabar 自动反转,实测后可能 Dark 调到 12%。
    static let cinnabarSoft  = cinnabar.opacity(0.08)
    /// 次强调 / 吉神 / 木行(墨青)。Dark 提亮保持识别。
    static let jade          = dyn(Color(red: 0x2C/255, green: 0x5F/255, blue: 0x3F/255),
                                   Color(red: 0x5A/255, green: 0x99/255, blue: 0x78/255))
    /// 三强调 / 水行 / 链接(黛蓝)。Dark 提亮保持识别。
    static let daiBlue       = dyn(Color(red: 0x1D/255, green: 0x3A/255, blue: 0x5F/255),
                                   Color(red: 0x6A/255, green: 0x8E/255, blue: 0xB5/255))
    /// 0.5pt 细线(灰墨 @ 30%)。opacity 跟随 inkMuted 自动反转。
    static let hairline      = inkMuted.opacity(0.3)
    /// 错误 / 破坏性操作(iOS `.destructive` 习惯,与 cinnabar 同值,语义独立便于未来调色)。
    static let destructive   = dyn(Color(red: 0xC3/255, green: 0x3B/255, blue: 0x3B/255),
                                   Color(red: 0xD4/255, green: 0x4A/255, blue: 0x4A/255))
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
