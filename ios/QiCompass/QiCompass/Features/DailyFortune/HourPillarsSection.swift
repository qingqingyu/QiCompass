import SwiftUI

/// 12 时辰条(决策 §1.E + DESIGN.md §Color 当前时辰 cinnabar):
/// - 默认折叠,展开后显示 12 行
/// - 当前时辰高亮**仅今日**显示,历史回看不高亮
struct HourPillarsSection: View {
    let hourPillars: [HourPillarDTO]
    let ziHourRule: String
    let businessDate: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        // 水墨孤本 T1:开放布局。折叠态 = 十二时辰点带(当前时辰朱点,参考 daily-t1.html);
        // 展开态 = 12 行明细(hairline 分隔)。
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(MotionPreferences.animation(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(L10n.DailyFortune.hourTitle)
                        .font(BaziFont.caption(size: 10))
                        .tracking(4)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(Array(hourPillars.enumerated()), id: \.offset) { idx, hp in
                    hourRow(idx: idx, hp: hp)
                }
            } else {
                // 折叠态:12 时辰点带(当前时辰 = 朱点放大,仅今日)
                HStack(spacing: 12) {
                    HStack(spacing: 7) {
                        ForEach(0..<12, id: \.self) { idx in
                            let isCurrent = currentHourIndexToday == idx
                            Circle()
                                .fill(isCurrent ? BaziTheme.cinnabar : BaziTheme.ink.opacity(0.2))
                                .frame(width: isCurrent ? 7 : 5, height: isCurrent ? 7 : 5)
                        }
                    }
                    Spacer(minLength: 12)
                    Text(hourSummaryLabel)
                        .font(BaziFont.caption(size: 11))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// 折叠态右侧文字:「12 时辰 · 当下未 ›」或「12 时辰 ›」(历史回看无当前)。
    /// 时辰字来自后端(术语不翻译,决策 7);"当下"复用 hourNow 既有 key。
    private var hourSummaryLabel: String {
        guard let todayIdx = currentHourIndexToday,
              todayIdx < hourPillars.count
        else { return "\(L10n.DailyFortune.hourTitle) ›" }
        return "\(L10n.DailyFortune.hourTitle) · \(L10n.DailyFortune.hourNow)\(hourPillars[todayIdx].hour) ›"
    }

    /// 仅今日(且有时辰算法可算出)才返回当前时辰索引;历史回看返回 nil。
    private var currentHourIndexToday: Int? {
        guard Calendar.current.isDateInToday(businessDate) else { return nil }
        return BusinessDateCalculator.currentHourIndex(
            now: .now, ziHourRule: ziHourRule,
        )
    }

    @ViewBuilder
    private func hourRow(idx: Int, hp: HourPillarDTO) -> some View {
        let isCurrent = currentHourIndexToday == idx
        HStack(alignment: .top, spacing: 12) {
            // 时辰字 + 高亮(当前时辰 cinnabar,DESIGN.md §Color)
            Text(hp.hour)
                .font(BaziFont.ganzhi(size: 20))
                .foregroundStyle(isCurrent ? BaziTheme.cinnabar : BaziTheme.ink)
                .frame(width: 28, alignment: .center)
                .padding(BaziTheme.Spacing.xs)
                .background(
                    isCurrent
                        ? BaziTheme.cinnabarSoft
                        : Color.clear,
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(hp.timeRange)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                    Text(hp.pillar)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(BaziTheme.ink)
                    Text(hp.relation)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.jade)
                    if isCurrent {
                        Text(L10n.DailyFortune.hourNow)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BaziTheme.onInkDeep)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(BaziTheme.inkDeep, in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                if let chong = hp.chong {
                    let label = L10n.DailyFortune.chongLabel(chong: chong, targets: hp.chongTargets)
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                }
            }
        }
        .padding(.vertical, 4)
        if idx < hourPillars.count - 1 {
            Divider().background(BaziTheme.hairline)
        }
    }
}
