import SwiftUI

/// success 态主布局:7 天历史 pill + 5 个 section + 下拉刷新。
///
/// 不直接接 state machine,由 DailyFortuneView 切换后传入。
struct DailyFortuneMainView: View {
    @Bindable var vm: DailyFortuneViewModel
    let response: DailyFortuneResponse
    let interpretState: InterpretState
    let businessDate: Date
    let chartHash: String?
    let ziHourRule: String
    let onRefresh: () -> Void
    let onHistorySelect: (Date) -> Void
    let onGenerateInterpret: () -> Void

    @State private var historySnapshots: [DailyFortuneSnapshot] = []
    @State private var historyError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 离线查看角标(方案 step 6):网络失败 fallback 到本地缓存时显示。
                if vm.isOffline {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                        Text("离线查看(展示本地缓存,不扣次数)")
                    }
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.cinnabar)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .background(BaziTheme.cinnabarSoft, in: Capsule())
                }

                // 顶部 7 天历史 pill(决策 §1.D)
                DailyFortuneHistoryView(
                    selectedDate: businessDate,
                    snapshots: historySnapshots,
                    onSelect: onHistorySelect,
                )
                if let historyError {
                    Text(historyError)
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.inkMuted.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // 头部:公历 + 农历 + 流日柱 + 关系 chip + 冲 chip
                DailyFortuneHeaderView(
                    businessDate: businessDate,
                    lunarDate: response.lunarDate,
                    dayPillar: response.dayPillar,
                    dayRelation: response.dayRelationToDayMaster,
                    dayChong: response.dayChong,
                    dayChongTargets: response.dayChongTargets,
                )

                // AI 解读(150-200 字,决策 F)
                DailyInterpretationSection(
                    state: interpretState,
                    remainingReads: vm.remainingReads,
                    nextReset: vm.nextDailyReset,
                    onGenerate: onGenerateInterpret,
                    onRetry: onGenerateInterpret,
                )

                // 12 时辰(默认折叠,决策 §1.E)
                HourPillarsSection(
                    hourPillars: response.hourPillars,
                    ziHourRule: ziHourRule,
                    businessDate: businessDate,
                )

                // 黄历宜/忌
                HuangliSection(yi: response.huangliYi, ji: response.huangliJi)

                // 明日预告
                TomorrowPreviewSection(preview: response.tomorrowPreview)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .refreshable { onRefresh() }
        .background(
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Color.clear.onAppear {
                    vm.checkBusinessDateChanged(
                        currentChartHash: chartHash,
                        ziHourRule: ziHourRule,
                    )
                }
            }
        )
        .task {
            loadHistory()
        }
    }

    private func loadHistory() {
        guard let hash = chartHash else { return }
        do {
            historySnapshots = try vm.loadHistory(chartHash: hash)
            historyError = nil
        } catch {
            // 不静默吞:错误显示在 chip 旁(不影响主流程)
            historyError = "历史加载失败"
            AppLogger.persistence.error(
                "op=dailyFortune.loadHistory failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }
}
