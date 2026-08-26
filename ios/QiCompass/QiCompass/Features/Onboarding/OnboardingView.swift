import SwiftUI

/// 首启动 onboarding sheet(2026-08-13 三屏重构,6 屏压成 3 屏)。
///
/// 2026-08-13 grill-me 重构(用户决策,事实源 `生肖设计决策.md`):
/// 1. **Welcome**(吸引屏,不变:印章「玄」+ 壁画佛手 + 经文)
/// 2. **出生表单**(嵌 TabView 第 2 页:用户直接体验输入出生信息)
/// 3. **生肖反馈**(终态屏:生肖 + 人格 + 好朋友/需磨合 + CTA,无 swipe 回退)
///
/// 结构决策(Q2):TabView 只放 [Welcome, 表单] 两页;提交成功(vm.state → .ready)
/// 整体切换成 ZodiacRevealView 终态屏。反馈屏不可回退,CTA 是唯一出路,
/// 编辑走 Profile 重置命盘(与 2026-08-10 生肖决策 Q20 v1 不开放编辑一致)。
///
/// 信任文案下沉(Q1):隐私微文案 → 表单页底;立场微文案 → 反馈屏底;
/// 完整版立场+隐私 → Profile 关于页。
///
/// 状态边界(Q7):提交成功即回调 onChartArchived(RootTabView 设 hasSeenOnboarding=true),
/// 修复"反馈屏 kill App → 重启重走 onboarding → 重复排盘"bug。
///
/// B2 约束保留(2026-08-01):只触发排盘 + chart 存档,**不**触发深度解析 AI 命书
/// (延后到用户主动进深度解析 Tab,β 点击触发)。
struct OnboardingView: View {
    /// 反馈屏 CTA 点击回调(RootTabView:dismiss sheet + 落地 .dailyFortune)。
    let onComplete: () -> Void
    /// 提交成功(chart 已存档)回调(RootTabView:hasSeenOnboarding = true)。
    let onChartArchived: () -> Void

    @EnvironmentObject private var env: AppEnvironment

    @State private var currentPage = 0
    @State private var vm: DeepAnalysisViewModel?
    /// 防止 ready → 多次触发 onComplete(SwiftUI 重渲染时可重复调用)。
    @State private var hasTriggeredComplete = false
    /// 提交前二次确认 sheet 触发态(生肖阶段 3:防新用户首次输错 → 重置命盘代价大)。
    @State private var showSubmitConfirm = false

    var body: some View {
        ZStack {
            BaziTheme.paper.ignoresSafeArea()
            content
        }
        .sheet(isPresented: $showSubmitConfirm) {
            if let vm {
                BirthInfoConfirmSheet(
                    vm: vm,
                    onConfirm: {
                        showSubmitConfirm = false
                        AppLogger.app.info("OnboardingView 二次确认 → 触发 vm.calculate")
                        vm.calculate()
                    },
                    onCancel: {
                        showSubmitConfirm = false
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .onAppear {
            // 首启 onboarding 呈现的入口日志,用于排查"没弹"问题
            AppLogger.app.info("OnboardingView.onAppear 首启动引导呈现")
        }
        .onChange(of: currentPage) { _, newPage in
            // 翻页日志:排查"卡在第 N 页 / 用户中途退出"等问题
            let pageNames = ["Welcome", "BirthForm"]
            let name = newPage < pageNames.count ? pageNames[newPage] : "Unknown"
            AppLogger.app.info("OnboardingView 翻页 currentPage=\(newPage, privacy: .public) name=\(name, privacy: .public)")
        }
        .task {
            if vm == nil {
                let newVM = DeepAnalysisViewModel(
                    orchestrator: env.deepAnalysisOrchestrator,
                    entitlementStore: env.entitlementStore
                )
                // 提交成功 → RootTabView 设 hasSeenOnboarding=true(Q7 状态边界)
                newVM.onChartArchived = { onChartArchived() }
                vm = newVM
                AppLogger.app.info("OnboardingView VM 创建完成")
            }
        }
    }

    // MARK: - 状态机内容

    @ViewBuilder
    @MainActor
    private var content: some View {
        if let vm {
            switch vm.state {
            case .empty, .formInvalid:
                // 第 1/2 屏:Welcome + 出生表单(两页 TabView)
                TabView(selection: $currentPage) {
                    WelcomePage().tag(0)
                    formPage(vm: vm).tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .interactive))
                .tint(BaziTheme.cinnabar)
            case .calculating(let stage):
                LoadingStateView(title: stage.text)
            case .ready(let response, _):
                // 第 3 屏:生肖反馈终态屏(提交成功 → 整体切换,无 swipe 回退)
                ZodiacRevealView(
                    zodiac: response.yearBranchZodiac,
                    mainLabel: mainLabel(from: response),
                    subLabel: subLabel(
                        from: response,
                        gender: vm.gender,
                        // 年份按出生城市钟面取(S03 WYSIWYG;Calendar.current 会跨年漂移)
                        birthYear: vm.placeCalendar.component(.year, from: vm.birthDate)
                    ),
                    friendZodiacs: response.yearBranchFriends,
                    clashZodiac: response.yearBranchClash,
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

    // MARK: - 第 2 屏:出生表单页

    /// 表单页 = 页标题(固定)+ BirthFormView(自带 ScrollView,弹性)+ 隐私微文案(固定)。
    /// 隐私微文案放这里(Q1 拆分下沉):用户交出生信息那一刻最关心隐私。
    private func formPage(vm: DeepAnalysisViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.Onboarding.formTitle)
                .font(BaziFont.display(size: 28))
                .foregroundStyle(BaziTheme.ink)
                .padding(.horizontal, BaziTheme.Spacing.xl)
                .padding(.top, BaziTheme.Spacing.xl)
                .padding(.bottom, BaziTheme.Spacing.md)

            // 表单主体:复用 DeepAnalysis 的 BirthFormView(自带 ScrollView)
            BirthFormView(vm: vm, onSubmit: { showSubmitConfirm = true })

            // 隐私微文案(Q1):一行为止,不说教
            Text(L10n.Onboarding.formPrivacyLine)
                .font(BaziFont.caption(size: 12))
                .foregroundStyle(BaziTheme.inkMuted)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BaziTheme.Spacing.xl)
                .padding(.vertical, BaziTheme.Spacing.md)
        }
    }

    // MARK: - ZodiacRevealView 文案 helper(后端真值推导)

    /// 主文字(生肖决策 Q12 iii):`辰 · 龙`(中点分隔)。
    /// 地支汉字从 `response.pillars.year.zhi`(后端 lunar_python 按立春算),
    /// 生肖汉字从 `ZodiacHelper.animalChar(forZodiac:)`(英文 asset name → 中文)。
    private func mainLabel(from response: BaziResponse) -> String {
        let zhi = response.pillars.year.zhi  // 如 "辰"
        let animalChar = ZodiacHelper.animalChar(forZodiac: response.yearBranchZodiac)  // "Dragon" → "龙"
        return "\(zhi) · \(animalChar)"
    }

    /// 次文字(生肖决策 Q13 C+ii):`乾造(男) · 庚辰年(2000)`(命理 + 公历双轨)。
    /// 年柱干支从 `response.pillars.year.ganZhi`(按立春算,可能与公历年不对应 —
    /// 立春前的公历年会显示上一年的年柱,这是正确行为,不是 bug)。
    /// 公历年份由调用方传(从 vm.birthDate 取,用于用户认知锚点)。
    private func subLabel(from response: BaziResponse, gender: String, birthYear: Int) -> String {
        let genderLabel = ZodiacHelper.genderLabel(forGender: gender)
        let ganzhi = response.pillars.year.ganZhi  // 如 "庚辰"
        return "\(genderLabel) · \(ganzhi)年(\(birthYear))"
    }
}

// MARK: - Shared: 朱砂印章

// MARK: - Page 1: Welcome
// SealStamp 已迁移到 Shared/InkKit.swift(水墨孤本版:朱底方印白字 + stamp 落印动画)。

/// 首屏欢迎页(2026-07-19 重构,2026-08-13 三屏重构保留不动):
/// - 全屏背景图(壁画佛手 + 宣纸留白) + 宣纸色兜底防露边
/// - 上半部:印章「玄」+ 标题 + 副标题(叠在壁画佛手区)
/// - 下半部宣纸留白区:经文(`SutraView` 自动按系统语言切排版)
/// - 错峰 riseIn 淡入:印章 0s → 标题 0.15s → 副标题 0.3s → 经文 0.45s
///
/// TODO(assets):WelcomeBackground 1x/2x/3x 切片已生成(2026-08-09),
/// 当前 PNG 无损压缩单张仍偏大(@3x 4MB / @2x 2.1MB / @1x 648KB),
/// 若需进一步瘦身可考虑 pngquant 有损压缩或重新导出(用户操作)。
private struct WelcomePage: View {
    var body: some View {
        ZStack {
            // 底层宣纸色兜底:图片加载延迟 / scaledToFill 在宽屏机型仍可能露边
            BaziTheme.paper
                .ignoresSafeArea()

            // 背景图:scaledToFill + 居中,所有 iPhone 机型(含 Pro Max)覆盖到底
            Image("WelcomeBackground")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            // 内容层
            VStack(spacing: 0) {
                // 上半部:印章 + 标题 + 副标题(叠在壁画佛手区)
                VStack(spacing: BaziTheme.Spacing.sm) {
                    Spacer().frame(height: 60)

                    SealStamp(character: "玄", size: 108)
                        .riseIn()
                        .accessibilityLabel("玄机问道印章")

                    VStack(spacing: BaziTheme.Spacing.xs) {
                        Text("玄机问道")
                            .font(BaziFont.display(size: 36))
                            .foregroundStyle(BaziTheme.ink)
                        Text("QICOMPASS")
                            .font(BaziFont.caption(size: 10))
                            .foregroundStyle(BaziTheme.inkMuted)
                            .tracking(4)
                    }
                    .riseIn(delay: 0.15)

                    // 副标题克制,不用 cinnabar 红字(原"专业不忽悠"过刺眼)
                    Text("读懂你的命局")
                        .font(BaziFont.body(size: 15))
                        .foregroundStyle(BaziTheme.inkMuted)
                        .riseIn(delay: 0.3)
                }

                Spacer()

                // 下半部:宣纸留白区经文
                SutraView()
                    .padding(.horizontal, BaziTheme.Spacing.xl)
                    .padding(.bottom, 100)
            }
        }
    }
}

// MARK: - Welcome: 经文区

/// 论语·尧曰「不知命，无以为君子也」。
/// - 中文系统(zh-*):竖排逐字,古书排版气质
/// - 非中文系统:横排整句,英文等语言的自然阅读方向
/// 字符串走 `Localizable.xcstrings` 的 `welcome_sutra` key,不硬编码。
private struct SutraView: View {
    @Environment(\.locale) private var locale

    private var isChinese: Bool {
        locale.language.languageCode?.identifier.hasPrefix("zh") == true
    }

    var body: some View {
        if isChinese {
            // 中文竖排逐字(String(localized:) 取本地化值后逐字堆叠)
            VStack(spacing: 6) {
                ForEach(
                    Array(String(localized: "welcome_sutra").map(String.init).enumerated()),
                    id: \.offset
                ) { _, char in
                    Text(char)
                        .font(BaziFont.display(size: 22, weight: .medium))
                        .foregroundStyle(BaziTheme.ink)
                }
            }
            .riseIn(delay: 0.45)
        } else {
            // 非中文:横排整句,italic 加文学感
            Text("welcome_sutra")
                .font(BaziFont.caption(size: 13))
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)
                .italic()
                .riseIn(delay: 0.45)
        }
    }
}
