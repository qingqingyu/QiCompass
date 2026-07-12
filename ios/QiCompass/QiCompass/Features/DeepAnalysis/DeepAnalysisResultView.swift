import SwiftUI

/// 深度解析成功态:命盘 + AI 命书组合视图(方案 §一 DeepAnalysisResultView)。
///
/// 从 BaziResponse 取数渲染全部命理区域 + AI 命书区。
/// 子组件均为纯展示,数据源单一(response + request),无副作用。
struct DeepAnalysisResultView: View {
    @Bindable var vm: DeepAnalysisViewModel
    let response: BaziResponse
    let request: BaziCalculateRequest

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
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
                InterpretationSection(vm: vm, response: response)

                Button("重新排盘") {
                    vm.reset()
                }
                .font(.caption)
                .foregroundStyle(BaziTheme.gold)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .padding()
        }
    }
}
