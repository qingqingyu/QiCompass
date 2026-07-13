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
    let onBackToConfig: () -> Void
    let onGenerateInterpret: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 双盘对比(D6)
                if let dualPillars = makeDualPillars() {
                    DualPillarsTable(pillars: dualPillars)
                } else {
                    Text("双盘数据读取失败")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                }

                // 4 张评估卡(D7)
                AssessmentCardGrid(assessment: response.qualitativeAssessment)

                // 流年同步表(D8)
                SyncedFortuneTable(synced: response.syncedFortune)

                // AI 解读段(D9)
                CompatibilityInterpretationSection(
                    state: interpretState,
                    remainingReads: vm.remainingReads,
                    nextReset: vm.nextDailyReset,
                    onGenerate: onGenerateInterpret,
                    onRetry: onGenerateInterpret
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
