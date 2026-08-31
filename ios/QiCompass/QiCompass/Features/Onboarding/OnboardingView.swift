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
                InkCalculatingView(title: stage.text)
            case .ready(let response, _):
                // 第 3 屏:生肖反馈终态屏(提交成功 → 整体切换,无 swipe 回退)
                ZodiacRevealView(
                    zodiac: response.yearBranchZodiac,
                    mainLabel: mainLabel(from: response),
                    subLabel: subLabel(
                        from: response,
                        gender: vm.gender,
                        // 年份按出生城市钟面取(S03 WYSIWYG;Calendar.current 会跨年漂移)。
                        // birthDate 已 Optional 化(S03 日期必选):.ready 前置 validateForm 已保证非空
                        birthYear: vm.birthDate.map { vm.placeCalendar.component(.year, from: $0) }
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
                .tint(BaziTheme.ink)
        }
    }

    // MARK: - 第 2 屏:出生表单页

    /// 表单页 = 页标题(固定)+ BirthFormView(自带 ScrollView,弹性)+ 隐私微文案(固定)。
    /// 隐私微文案放这里(Q1 拆分下沉):用户交出生信息那一刻最关心隐私。
    /// 视觉对齐 O2 原型(docs/design-ref/shuimo/onboarding-o2-birthform.html):
    /// 居中大字距标题 + 小副标 + 左上竖排「問命」版心 + 底部隐私微文案。
    private func formPage(vm: DeepAnalysisViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: BaziTheme.Spacing.xs) {
                Text(L10n.Onboarding.formTitle)
                    .font(BaziFont.display(size: 24))
                    .tracking(6)
                    .foregroundStyle(BaziTheme.ink)
                Text(L10n.Onboarding.formSubtitle)
                    .font(BaziFont.caption(size: 11))
                    .tracking(3)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, BaziTheme.Spacing.xl)
            .padding(.bottom, BaziTheme.Spacing.md)
            .riseIn(delay: 0.1)

            // 表单主体:复用 DeepAnalysis 的 BirthFormView(自带 ScrollView)
            BirthFormView(vm: vm, onSubmit: { showSubmitConfirm = true })

            // 隐私微文案(Q1):一行为止,不说教
            Text(L10n.Onboarding.formPrivacyLine)
                .font(BaziFont.caption(size: 10))
                .tracking(2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.horizontal, BaziTheme.Spacing.xl)
                .padding(.vertical, BaziTheme.Spacing.md)
        }
        // 左上竖排「問命」小标(原型 .vmark:竖排 + leading hairline,版心元素)
        .overlay(alignment: .topLeading) {
            VText(phrase: "問命", size: 13, tracking: 5, color: BaziTheme.inkMuted)
                .padding(.leading, BaziTheme.Spacing.sm)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(width: 0.5)
                }
                .padding(.leading, BaziTheme.Spacing.xl)
                .padding(.top, BaziTheme.Spacing.lg)
                .riseIn(delay: 0.05)
                .allowsHitTesting(false)
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
    /// birthYear 为 Optional(S03 birthDate Optional 化):nil = 理论不可达(.ready 前置
    /// validateForm 已保证日期非空),显式记录 + 诚实降级去括号,不静默编造年份。
    private func subLabel(from response: BaziResponse, gender: String, birthYear: Int?) -> String {
        let genderLabel = ZodiacHelper.genderLabel(forGender: gender)
        let ganzhi = response.pillars.year.ganZhi  // 如 "庚辰"
        guard let birthYear else {
            AppLogger.app.error("OnboardingView.subLabel birthDate_missing(理论不可达,请上报)")
            return "\(genderLabel) · \(ganzhi)年"
        }
        return "\(genderLabel) · \(ganzhi)年(\(birthYear))"
    }
}

// MARK: - Page 1: Welcome(水墨孤本 O1,2026-08-26 重写)
//
// 参考 docs/design-ref/shuimo/onboarding-o1-welcome.html:
// 墨圆居中承接开机转场 → 玄印落于圆心 → 楷体标题 → QICOMPASS 字距标 →
// 副标题 → 竖排经文(版心左 hairline)。壁画佛手背景图退役(与新语言冲突)。
// 错峰时序(承接 splash 后从简):enso 0s → 标题 0.2s → 副标 0.35s → 经文 0.55s → 印 0.9s。
private struct WelcomePage: View {
    var body: some View {
        ZStack {
            BaziTheme.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 92)

                // 墨圆 + 玄印居中(stamp 落定在墨圆成形之后)
                EnsoView(size: 172, breathing: true)
                    .overlay {
                        SealStamp(character: "玄", size: 34, rotation: 3, stampDelay: 0.9)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("玄机问道印章")

                VStack(spacing: 12) {
                    Text("玄机问道")
                        .font(BaziFont.display(size: 27))
                        .tracking(8)
                        .foregroundStyle(BaziTheme.ink)
                        .riseIn(delay: 0.2)
                    Text("QICOMPASS")
                        .font(BaziFont.latinCaps(size: 8.5))
                        .tracking(5)
                        .foregroundStyle(BaziTheme.inkMuted)
                        .riseIn(delay: 0.35)
                    Text(L10n.Onboarding.welcomeTagline)
                        .font(BaziFont.body(size: 12.5))
                        .tracking(3)
                        .foregroundStyle(BaziTheme.inkMuted)
                        .riseIn(delay: 0.45)
                }
                .padding(.top, 30)

                Spacer()

                SutraView()
                    .padding(.bottom, 96)

                // 左滑提示(经文之下、系统翻页点之上)
                Text(L10n.Onboarding.welcomeSwipeHint)
                    .font(BaziFont.caption(size: 10))
                    .tracking(3)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                    .riseIn(delay: 0.9)
                    .padding(.bottom, 22)
            }
        }
    }
}

// MARK: - Welcome: 经文区(竖排版心)

/// 论语·尧曰「不知命，无以为君子也」。
/// - 中文系统(zh-*):VText 竖排 + 左侧 hairline(古书版心气质)
/// - 非中文系统:横排整句,italic 加文学感
/// 字符串走 `Localizable.xcstrings` 的 `welcome_sutra` key,不硬编码。
private struct SutraView: View {
    @Environment(\.locale) private var locale

    private var isChinese: Bool {
        locale.language.languageCode?.identifier.hasPrefix("zh") == true
    }

    var body: some View {
        if isChinese {
            VText(phrase: String(localized: "welcome_sutra"), size: 17, tracking: 6)
                .padding(.vertical, 18)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(width: 0.5)
                }
                .riseIn(delay: 0.55)
        } else {
            // 非中文:横排整句,italic 加文学感
            Text("welcome_sutra")
                .font(BaziFont.caption(size: 13))
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)
                .italic()
                .riseIn(delay: 0.55)
        }
    }
}

// MARK: - O3: 排盘布算(水墨 loading)

/// 排盘布算中:墨圆缓呼吸 + 竖排「排盘布算中」+ 真实阶段文案。
/// 参考 docs/design-ref/shuimo/onboarding-o3-calculating.html(墨滴涟漪的水墨等价物)。
private struct InkCalculatingView: View {
    let title: String

    var body: some View {
        ZStack {
            BaziTheme.paper.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // 主体:墨圆 + 右侧竖排题(非对称,呼应开机页构图;英文 VText 自动横排回退)
                HStack(alignment: .center, spacing: 26) {
                    EnsoView(size: 190, breathing: true)
                    VText(phrase: L10n.Onboarding.calculatingTitle, size: 19, tracking: 8)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(BaziTheme.hairline)
                                .frame(width: 0.5)
                        }
                }

                Spacer()

                // 阶段文案(真实后端阶段,横排小字)+ 推演条目
                VStack(spacing: 14) {
                    Text(title)
                        .font(BaziFont.body(size: 12))
                        .tracking(4)
                        .foregroundStyle(BaziTheme.inkMuted)
                    Text(L10n.Onboarding.calculatingSteps)
                        .font(BaziFont.caption(size: 11))
                        .tracking(4)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                .padding(.bottom, 90)
            }
        }
    }
}
