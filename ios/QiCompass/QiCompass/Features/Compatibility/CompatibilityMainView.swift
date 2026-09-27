import SwiftUI

/// 合盘结果态主布局:双盘对比 + 4 张评估卡 + 流年同步表 + AI 解读段。
///
/// 不直接接 state machine,由 CompatibilityView 切换后传入。
/// 顶部「返回修改」toolbar 切回配置态(D1)。
struct CompatibilityMainView: View {
    @Bindable var vm: CompatibilityViewModel
    let response: CompatibilityResponse
    let interpretState: InterpretState
    let chartASnapshot: ChartSnapshot
    let chartBSnapshot: ChartSnapshot
    /// 两人称呼(2026-09-27 A/B 代号修复):A 恒命主本人「你/you」,B 为对方
    /// alias/兜底名(与 prompt context 同源,UI 与正文称呼一致)。
    let nameA: String
    let nameB: String
    let onBackToConfig: () -> Void
    let onGenerateInterpret: () -> Void
    let onShowPaywall: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: BaziTheme.Spacing.lg) {
                // 双盘对比(D6)
                if let dualPillars = makeDualPillars() {
                    DualPillarsTable(
                        pillars: dualPillars, labelA: nameA, labelB: nameB)
                } else {
                    Text("双盘数据读取失败")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                }

                // 4 张评估卡(D7)
                AssessmentCardGrid(assessment: response.qualitativeAssessment)

                // 流年同步表(D8;A 列头固定「你的流年」,只注入 B 称呼)
                SyncedFortuneTable(
                    synced: response.syncedFortune, nameB: nameB)

                // AI 解读段(D9)
                CompatibilityInterpretationSection(
                    state: interpretState,
                    remainingReads: vm.remainingReads,
                    nextReset: vm.nextDailyReset,
                    onGenerate: onGenerateInterpret,
                    onRetry: onGenerateInterpret,
                    onShowPaywall: onShowPaywall
                )
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
    }

    /// 从两个 ChartSnapshot 解码 BaziResponse,构造双盘对比源。
    /// 解码失败显式返回 nil(由 UI 提示),不静默用占位。
    /// 走 VM 暴露的窄方法,避免 View 直访 SwiftData payload/store。
    private func makeDualPillars() -> [DualPillarSource]? {
        do {
            return try vm.makeDualPillars(
                chartASnapshot: chartASnapshot,
                chartBSnapshot: chartBSnapshot
            )
        } catch {
            AppLogger.persistence.error(
                "op=compatibility.makeDualPillars failed error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }
}
