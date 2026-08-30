import SwiftUI

/// 顶部 7 天历史日期 pill(决策 §1.D + DESIGN.md §Color):
/// 今日 + 过去 6 天。选中态 cinnabar 高亮。命中本地 snapshot 的日带圆点指示。
/// 末尾「更早」pill(2026-08-30,MONETIZATION.md §每日运势历史回看):
/// 免费 = dashed 锁框 → 锁定态 sheet;有任意购买记录 = 实线 → 更早日期清单。
struct DailyFortuneHistoryView: View {
    let selectedDate: Date
    let snapshots: [DailyFortuneSnapshot]
    /// 历史回看解锁判据(EntitlementStore.hasAnyActivePurchase)。
    var canViewFullHistory = false
    /// 点「更早」pill:打开历史回看 sheet(锁定态或清单态由 canViewFullHistory 决定)。
    var onEarlier: () -> Void = {}
    let onSelect: (Date) -> Void

    private let calendar = Calendar.current

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(historyDates(), id: \.self) { date in
                    pillButton(for: date)
                }
                earlierPill
            }
            .padding(.vertical, 4)
        }
    }

    /// 「更早」pill:免费 = dashed 锁框(DESIGN.md 虚线=锁定语义);已购 = 实线 + chevron。
    private var earlierPill: some View {
        Button(action: onEarlier) {
            VStack(spacing: 4) {
                Image(systemName: canViewFullHistory ? "chevron.right" : "lock")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Text(L10n.DailyFortune.historyEarlier)
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
                // 与日期 pill 等高:补一个 4pt 占位(对齐底部圆点行)
                Color.clear.frame(width: 4, height: 4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                    .stroke(
                        canViewFullHistory ? BaziTheme.hairline : BaziTheme.hairlineDashed,
                        style: StrokeStyle(
                            lineWidth: 0.5,
                            dash: canViewFullHistory ? [] : [4, 3]
                        )
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.DailyFortune.historySheetTitle)
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
                    .foregroundStyle(isSelected ? BaziTheme.onInkDeep : BaziTheme.inkMuted)
                Text(dayString(date))
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? BaziTheme.onInkDeep : BaziTheme.ink)
                if hasSnapshot {
                    Circle()
                        .fill(isSelected ? BaziTheme.onInkDeep : BaziTheme.cinnabar)
                        .frame(width: 4, height: 4)
                } else {
                    Color.clear.frame(width: 4, height: 4)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected
                    ? BaziTheme.inkDeep
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                    .stroke(
                        isSelected ? BaziTheme.inkDeep : BaziTheme.hairline,
                        lineWidth: 0.5
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

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "E"
        return f
    }()

    private func shortWeekday(_ date: Date) -> String {
        Self.weekdayFormatter.string(from: date)
    }

    private func dayString(_ date: Date) -> String {
        let day = calendar.component(.day, from: date)
        return "\(day)"
    }
}

// MARK: - 历史回看 sheet(2026-08-30,MONETIZATION.md §每日运势历史回看)

/// 历史回看 sheet:免费 = 锁定态(「解」印 + 规则说明 + CTA 进付费墙);
/// 已购 = 更早日期清单(点选走既有 selectHistoryDate,本地无则后端按需生成)。
struct DailyFortuneHistorySheet: View {
    let canViewFullHistory: Bool
    let snapshots: [DailyFortuneSnapshot]
    let onSelect: (Date) -> Void
    /// 锁定态 CTA:打开付费墙(规则是「任意购买解锁」,付费墙卖的是深度解析/合盘)。
    let onUnlock: () -> Void

    @Environment(\.dismiss) private var dismiss
    private let calendar = Calendar.current

    /// 已购清单窗口:strip 已覆盖今日 + 过去 6 天,这里从第 7 天往前 90 天。
    /// 上界防无边界 on-demand 生成(每行点选都可能触发一次后端调用);
    /// 窗口大小是可调产品参数,记录在 MONETIZATION.md。
    private var earlierDates: [Date] {
        let today = calendar.startOfDay(for: .now)
        return (7...96).compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.DailyFortune.historySheetTitle)
                    .font(BaziFont.caption(size: 10))
                    .tracking(4)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Spacer()
                Button(L10n.DailyFortune.historyDone) { dismiss() }
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            .padding(.bottom, 16)

            if canViewFullHistory {
                earlierList
            } else {
                lockedView
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .presentationDetents([.medium])
        .presentationBackground(BaziTheme.cardSurface)
    }

    // MARK: 锁定态(免费)

    private var lockedView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                SealStamp(character: "解", size: 36, rotation: -4, stampDelay: 0.2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.DailyFortune.historyFreeTitle)
                        .font(BaziFont.display(size: 15.5))
                        .foregroundStyle(BaziTheme.ink)
                    Text(L10n.DailyFortune.historyUnlockNote)
                        .font(BaziFont.caption(size: 13))
                        .foregroundStyle(BaziTheme.inkMuted)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PrimaryCTAButton(
                title: L10n.DailyFortune.historyUnlockCTA,
                loadingTitle: L10n.DailyFortune.historyUnlockCTA,
                isLoading: false,
                action: {
                    dismiss()
                    onUnlock()
                }
            )
            .padding(.top, 18)
        }
    }

    // MARK: 清单态(已购)

    private var earlierList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(earlierDates.enumerated()), id: \.element) { idx, date in
                    Button {
                        onSelect(date)
                        dismiss()
                    } label: {
                        earlierRow(date)
                    }
                    .buttonStyle(.plain)
                    if idx < earlierDates.count - 1 {
                        Rectangle().fill(BaziTheme.hairline).frame(height: 0.5)
                    }
                }
            }
        }
    }

    private func earlierRow(_ date: Date) -> some View {
        let hasSnapshot = snapshots.contains {
            calendar.isDate($0.targetDate, inSameDayAs: date)
        }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(Self.dayFormatter.string(from: date))
                .font(BaziFont.display(size: 15))
                .foregroundStyle(BaziTheme.ink)
            Text(Self.weekdayFormatter.string(from: date))
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            Spacer()
            if hasSnapshot {
                Circle().fill(BaziTheme.cinnabar).frame(width: 4, height: 4)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    /// 日期行:locale 感知(zh "8月23日" / en "Aug 23"),不带年份。
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f
    }()

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "E"
        return f
    }()
}
