import SwiftUI

/// 深度解析成功态:命盘 + AI 命书组合视图(方案 §一 DeepAnalysisResultView)。
///
/// 从 BaziResponse 取数渲染全部命理区域 + AI 命书区。
/// 子组件均为纯展示,数据源单一(response + request),无副作用。
///
/// M3c 新增:InterpretationSection 的 .lockedPaid case 触发 PaywallView sheet
/// (底部 sheet + grabber,购买成功后重新调 vm.generateInterpretation 切到 _paid)。
struct DeepAnalysisResultView: View {
    @Bindable var vm: DeepAnalysisViewModel
    let response: BaziResponse
    let request: BaziCalculateRequest

    @EnvironmentObject private var env: AppEnvironment
    @State private var showPaywall = false

    private var interpretState: InterpretState {
        if case .chartReady(_, let s) = vm.state { return s }
        return .idle
    }

    var body: some View {
        ScrollView {
            VStack(spacing: BaziTheme.Spacing.md) {
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
                InterpretationSection(
                    interpretState: interpretState,
                    remainingReads: vm.remainingReads,
                    nextReset: vm.nextDailyReset,
                    onGenerate: { vm.generateInterpretation() },
                    onRetry: { vm.retryInterpretation() },
                    onShowPaywall: { showPaywall = true }
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
                    contentHash: response.contentHash,
                    module: EntitlementModule.baziDeep,
                    productId: AppleProductID.deepAnalysisSingle,
                    purchaseManager: env.purchaseManager,
                    onPurchaseSuccess: {
                        // 购买成功 → dismiss + 重新调 _paid(查到 entitlement 自动切)
                        showPaywall = false
                        vm.generateInterpretation()
                    }
                )
            )
        }
    }
}
