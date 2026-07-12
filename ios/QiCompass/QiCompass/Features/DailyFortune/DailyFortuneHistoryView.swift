import SwiftUI

/// 顶部 7 天历史日期 pill(决策 §1.D):
/// 今日 + 过去 6 天。选中态高亮。命中本地 snapshot 的日带圆点指示。
struct DailyFortuneHistoryView: View {
    let selectedDate: Date
    let snapshots: [DailyFortuneSnapshot]
    let onSelect: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(historyDates(), id: \.self) { date in
                    pillButton(for: date)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func pillButton(for date: Date) -> some View {
        let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
        let hasSnapshot = snapshots.contains { calendar.isDate($0.targetDate, inSameDayAs: date) }
        let isToday = calendar.isDateInToday(date)

        return Button {
            onSelect(date)
        } label: {
            VStack(spacing: 4) {
                Text(shortWeekday(date))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? BaziTheme.bgTop : BaziTheme.textDim)
                Text(dayString(date))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? BaziTheme.bgTop : BaziTheme.text)
                if hasSnapshot {
                    Circle()
                        .fill(isSelected ? BaziTheme.bgTop : BaziTheme.gold)
                        .frame(width: 4, height: 4)
                } else {
                    Color.clear.frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? BaziTheme.gold
                    : BaziTheme.cardBackground,
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isToday ? BaziTheme.gold.opacity(0.6) : BaziTheme.cardBorder,
                        lineWidth: isToday && !isSelected ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    /// 生成今日 + 过去 6 天,按日期 DESC。
    private func historyDates() -> [Date] {
        let today = calendar.startOfDay(for: .now)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    private func shortWeekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "E"
        return f.string(from: date)
    }

    private func dayString(_ date: Date) -> String {
        let day = calendar.component(.day, from: date)
        return "\(day)"
    }
}
