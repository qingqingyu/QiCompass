import SwiftUI

/// 深度解析成功态:命盘 + AI 命书组合视图(方案 §一 DeepAnalysisResultView)。
///
/// 从 BaziResponse 取数渲染全部命理区域 + AI 命书区。
/// 子组件均为纯展示,数据源单一(response + request),无副作用。
///
/// M3c:InterpretationSection 的 .lockedPaid case 触发 PaywallView sheet
/// (底部 sheet + grabber,购买成功后重新调 vm.generateInterpretation 切到 _paid)。
///
/// Stage 8:加 v1 启用入口 + M4/M5 输入 sheet 装配。
/// v1 模式启用前用户走老 legacyInterpretationBody(向后兼容);
/// 点 "试用新版模块化分析" 链接后切到 v1 模式(ForEach 8 ModuleCardView)。
struct DeepAnalysisResultView: View {
    @Bindable var vm: DeepAnalysisViewModel
    let response: BaziResponse
    let request: BaziCalculateRequest

    @EnvironmentObject private var env: AppEnvironment
    @State private var showPaywall = false
    // Stage 8:M4/M5 输入 sheet 状态
    @State private var showM4InputSheet = false
    @State private var showM5InputSheet = false
    // Stage 8:用户是否已切到 v1 模式(点过 v1EntryButton)
    // 显式 flag 替代「moduleStates.isEmpty 推断」,避免派生状态脆弱依赖
    @State private var v1ModeEnabled = false

    private var interpretState: InterpretState {
        if case .ready(_, let s) = vm.state { return s }
        return .idle
    }

    var body: some View {
        ScrollView {
            VStack(spacing: BaziTheme.Spacing.md) {
                // 2026-08-01 grill-me 决策 #13:chart 顶部 deterministic anchor sentence
                // 后端拼接(0 AI 成本),iOS MarkdownSanitizer 渲染 **加粗** emphasis
                if let anchor = response.anchorSentence {
                    Text(MarkdownSanitizer.rendered(anchor))
                        .bodySerifText()
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(BaziTheme.Spacing.md)
                        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                        .overlay(
                            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                                .stroke(BaziTheme.cinnabar.opacity(0.3), lineWidth: 0.5)
                        )
                }
                ChartHeaderView(response: response, request: request)
                PillarsTable(pillars: response.pillars)
                AuxiliaryCards(
                    mingGong: response.mingGong,
                    shenGong: response.shenGong,
                    taiYuan: response.taiYuan
                )
                ElementBalanceBar(balance: response.elementBalance)
                XijiCard(response: response)
                ShenshaChips(shensha: response.shensha)
                LuckPillarsTimeline(
                    luckPillars: response.luckPillars,
                    currentLuckPillar: response.currentLuckPillar
                )
                CurrentStatusCard(response: response)

                // Stage 8:v1 启用入口(老路径下显示"试用新版"链接)
                if !v1ModeEnabled {
                    v1EntryButton
                }

                InterpretationSection(
                    interpretState: interpretState,
                    remainingReads: vm.remainingReads,
                    nextReset: vm.nextDailyReset,
                    onGenerate: { vm.generateInterpretation() },
                    onRetry: { vm.retryInterpretation() },
                    onShowPaywall: { showPaywall = true },
                    // Stage 7c/8:传 v1 moduleStates 启用 v1 模式(ForEach 8 ModuleCardView)
                    // moduleStates 为空时返 nil → 走老 legacyInterpretationBody 路径
                    // (向后兼容合盘/每日运势/老 bazi_deep 用户)
                    v1ModuleStates: v1ModeEnabled ? vm.moduleStates : nil,
                    onGenerateV1: { vm.generateV1AllModules() },
                    onRetryV1: { module in vm.retryV1Module(module) },
                    // Stage 8:M4/M5 用户点"提供信息"CTA → 弹对应输入 sheet
                    onProvideInput: { module in
                        switch module {
                        case .m4:
                            showM4InputSheet = true
                        case .m5:
                            showM5InputSheet = true
                        default:
                            // 非 M4/M5 不应触发 onProvideInput(ModuleCardView 防御性 fatalError 已保证)
                            AppLogger.app.warning("deepResultView.onProvideInput unexpected module=\(module.rawValue, privacy: .public)")
                        }
                    }
                )

                Button("重新排盘") {
                    vm.reset()
                }
                .font(.caption)
                .foregroundStyle(BaziTheme.cinnabar)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .padding()
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(
                viewModel: PaywallViewModel(
                    module: .deepAnalysis,
                    contentHash: response.contentHash,
                    purchaseManager: env.purchaseManager,
                    onPurchaseSuccess: {
                        // 购买成功 → dismiss + 重新调 _paid(查到 entitlement 自动切)
                        showPaywall = false
                        vm.generateInterpretation()
                    }
                )
            )
        }
        // Stage 8:M4 健康输入 sheet
        .sheet(isPresented: $showM4InputSheet) {
            HealthInputForm(
                initialAge: vm.m4UserInput?.age ?? 30,
                initialConcern: vm.m4UserInput?.concern ?? "睡眠",
                onSubmit: { age, concern in
                    vm.submitM4Input(age: age, concern: concern)
                    showM4InputSheet = false
                },
                onCancel: {
                    showM4InputSheet = false
                }
            )
            .presentationDetents([.medium, .large])
        }
        // Stage 8:M5 财富输入 sheet
        .sheet(isPresented: $showM5InputSheet) {
            WealthInputForm(
                initialAssetsSummary: vm.m5UserInput?.assets ?? "",
                initialPreference: vm.m5UserInput?.preference ?? "平衡",
                onSubmit: { assets, preference in
                    vm.submitM5Input(assets: assets, preference: preference)
                    showM5InputSheet = false
                },
                onCancel: {
                    showM5InputSheet = false
                }
            )
            .presentationDetents([.medium, .large])
        }
    }

    // MARK: - v1 启用入口(Stage 8)

    /// 老路径下显示的"试用新版"链接,点击切到 v1 模式。
    /// 设计决策(Stage 8):不直接替换老"生成命书"按钮(避免破坏老用户预期),
    /// 用低强调链接引导有兴趣的用户试 v1。后续 Stage 9+ 决定是否默认 v1。
    private var v1EntryButton: some View {
        Button {
            HapticEngine.light()
            AppLogger.app.info("deepResultView.v1_entry_clicked contentHash=\(response.contentHash, privacy: .public)")
            // 切到 v1 模式:显式 flag + VM 触发 generateV1AllModules
            v1ModeEnabled = true
            vm.generateV1AllModules()
        } label: {
            HStack(spacing: BaziTheme.Spacing.xs) {
                Image(systemName: "sparkles")
                Text("试用新版模块化分析(M0-M7 八模块)")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(BaziTheme.daiBlue)
            .padding(.vertical, BaziTheme.Spacing.xs)
        }
        .buttonStyle(.plain)
    }
}
