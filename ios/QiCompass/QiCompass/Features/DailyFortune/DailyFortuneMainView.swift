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

                // 宜/忌 main anchor(视觉锚点,非 AI 输出)
                // 朱砂=宜 / 灰墨=忌,左右并列 layout
                YiJiAnchorSection(dayRelation: response.dayRelationToDayMaster)

                // AI 解读(50-80 字 Medium voice)
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

// MARK: - YiJiAnchorSection

/// 今日运势页宜/忌 main anchor(视觉锚点,非 AI 输出)。
///
/// 朱砂=宜 / 灰墨=忌 + 左右并列 layout。
///
/// **数据源**(v1 简化):前端十神→关键词映射表。基于 `dayRelationToDayMaster`
/// 查表得到 actionable 2-3 字 bullet。
/// TODO 后续:可能挪到后端基于 favorable_elements + 流日关系确定性映射,
/// 但 v1 不增加后端复杂度,前端 lookup 足够。
///
/// 不复用 HuangliSection(那是通用黄历宜/忌,人人一样);
/// 本 section 是**个性化**宜/忌(基于流日对日主的关系)。
private struct YiJiAnchorSection: View {
    let dayRelation: String

    /// 十神→宜/忌 actionable 关键词映射(10 神,对齐后端 lunar_python 命名)。
    /// 每条 2-3 字 actionable,与今日页 Medium voice 节奏一致。
    private static let mapping: [String: (yi: String, ji: String)] = [
        "比肩": ("独立", "争执"),
        "劫财": ("行动", "冲动"),
        "食神": ("创造", "拖延"),
        "伤官": ("表达", "冲撞"),
        "偏财": ("拓展", "孤注"),
        "正财": ("守成", "短视"),
        "七杀": ("果断", "犹豫"),
        "正官": ("担当", "退缩"),
        "偏印": ("思考", "执拗"),
        "正印": ("学习", "依赖"),
    ]

    /// 防御:未知关系(理论上后端必返回十神之一,但保护)。
    private static let fallback = (yi: "顺势", ji: "强求")

    /// 查表命中失败时记日志,不静默 fallback(对齐 CLAUDE.md 错误显式传播约束)。
    private var pair: (yi: String, ji: String) {
        if let matched = Self.mapping[dayRelation] {
            return matched
        }
        AppLogger.app.warning(
            "op=yiJiAnchor.lookupMiss day_relation=\(dayRelation, privacy: .public) -> fallback"
        )
        return Self.fallback
    }

    var body: some View {
        let resolved = pair
        HStack(spacing: BaziTheme.Spacing.md) {
            anchorColumn(label: "宜", keyword: resolved.yi, color: BaziTheme.cinnabar)
            anchorColumn(label: "忌", keyword: resolved.ji, color: BaziTheme.inkMuted)
        }
        .padding(BaziTheme.Spacing.md)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                .stroke(BaziTheme.hairline, lineWidth: 0.5)
        )
    }

    private func anchorColumn(label: String, keyword: String, color: Color) -> some View {
        HStack(spacing: BaziTheme.Spacing.sm) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(keyword)
                .bodySerifText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
