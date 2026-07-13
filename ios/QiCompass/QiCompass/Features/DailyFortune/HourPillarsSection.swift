import SwiftUI

/// 12 时辰条(决策 §1.E):
/// - 默认折叠,展开后显示 12 行
/// - 当前时辰高亮**仅今日**显示,历史回看不高亮
struct HourPillarsSection: View {
    let hourPillars: [HourPillarDTO]
    let ziHourRule: String
    let businessDate: Date

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(MotionPreferences.animation(reduceMotion: reduceMotion)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text("12 时辰")
                        .zcoolCardTitle()
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.textDim)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(Array(hourPillars.enumerated()), id: \.offset) { idx, hp in
                    hourRow(idx: idx, hp: hp)
                }
            } else {
                // 折叠时显示当前时辰一行(仅今日)
                if let todayIdx = currentHourIndexToday {
                    if todayIdx < hourPillars.count {
                        hourRow(idx: todayIdx, hp: hourPillars[todayIdx])
                    }
                } else {
                    Text("展开查看 12 时辰详情")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.textDim.opacity(0.7))
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(16)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(BaziTheme.cardBorder, lineWidth: 1)
        )
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
            // 时辰字 + 高亮
            Text(hp.hour)
                .font(BaziFont.zcoolTitle(size: 20))
                .foregroundStyle(isCurrent ? BaziTheme.gold : BaziTheme.text)
                .frame(width: 28, alignment: .center)
                .padding(4)
                .background(
                    isCurrent
                        ? BaziTheme.gold.opacity(0.15)
                        : Color.clear,
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(hp.timeRange)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.textDim)
                    Text(hp.pillar)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(BaziTheme.text)
                    Text(hp.relation)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.gold)
                    if isCurrent {
                        Text("当下")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(BaziTheme.bgTop)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(BaziTheme.gold, in: Capsule())
                    }
                }
                if let chong = hp.chong {
                    let label = hp.chongTargets.isEmpty
                        ? "冲\(chong)"
                        : "冲\(chong) (\(hp.chongTargets.joined(separator: "、")))"
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                }
            }
        }
        .padding(.vertical, 4)
        if idx < hourPillars.count - 1 {
            Divider().background(BaziTheme.separator)
        }
    }
}
