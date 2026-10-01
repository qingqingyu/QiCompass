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
    /// 失败态重试 + 付费成功回调共用(VM generateInterpretation)。
    let onGenerateInterpret: () -> Void
    let onShowPaywall: () -> Void

    var body: some View {
        let dualPillars = makeDualPillars()
        return ScrollView {
            VStack(spacing: BaziTheme.Spacing.lg) {
                // 双盘对比(D6;S4 中轴带日主方向短语,后端关系标签作守卫回退)
                if let dualPillars {
                    DualPillarsTable(
                        pillars: dualPillars, labelA: nameA, labelB: nameB,
                        dayMasterRelation: response.qualitativeAssessment.dayMasterRelation)
                } else {
                    Text("双盘数据读取失败")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                }

                // 4 张评估卡(D7;点名干支详情从同一双盘源确定性派生,BP #2;
                // 双盘源缺失时仍给枚举值 + 解释,不空屏)
                AssessmentCardGrid(
                    assessment: response.qualitativeAssessment,
                    detail: dualPillars.map { CompatibilityRelationDetailBuilder.make(pillars: $0) }
                )

                // 五行分布(BP #4:让「互补」有盘面事实可查;需双盘源,缺失时整段不渲染)
                if let dualPillars {
                    ElementBalanceSection(pillars: dualPillars, nameB: nameB)
                }

                // 流年同步表(D8;A 列头固定「你的流年」,只注入 B 称呼)
                SyncedFortuneTable(
                    synced: response.syncedFortune, nameB: nameB)

                // AI 解读段(D9;2026-10-01 #13:免费章自动生成,手动 CTA 拔除)
                CompatibilityInterpretationSection(
                    state: interpretState,
                    remainingReads: vm.remainingReads,
                    nextReset: vm.nextDailyReset,
                    onRetry: onGenerateInterpret,
                    onShowPaywall: onShowPaywall
                )

                // L3/F1(修订 D10.5):打开即自动翻译——翻译中不显示提示条,
                // 只在失败时出现(重试入口)
                if let offer = vm.translationOffer, vm.translationFailed {
                    TranslateHintBar(
                        mode: .failure(
                            sourceLanguage: offer.sourceLanguage,
                            failureText: String(localized: "翻译失败")
                        ),
                        onRetry: { vm.acceptTranslation() }
                    )
                    .padding(.top, 4)
                }
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
