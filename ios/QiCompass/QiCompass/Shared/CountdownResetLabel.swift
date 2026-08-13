import SwiftUI

/// 倒计时标签(每日上限重置到本地午夜,DESIGN.md §Color)。
///
/// `TimelineView(.periodic)` 每分钟刷新,无 Timer 泄漏。
/// 三模块(深度解析 / 合盘 / 每日运势)的达上限态共用此组件,
/// 消除 `countdownView` + `formatCountdown` 在四个 View 文件里的重复拷贝。
struct CountdownResetLabel: View {
    let nextReset: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let remaining = nextReset.timeIntervalSince(context.date)
            let secs = max(0, remaining)
            let h = Int(secs) / 3600
            let m = (Int(secs) % 3600) / 60
            Text(L10n.Common.countdownLabel(hours: h, minutes: m))
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }
}

// MARK: - DailyLimitReachedView

/// 达上限态共用视图(三模块 AI 解读复用)。
///
/// 显示"今日机缘已尽,明日再来" + 倒计时到本地午夜。
/// 用在:
/// - idle 态 + remainingReads <= 0(避免误导点击 CTA)
/// - .dailyLimitReached 态
struct DailyLimitReachedView: View {
    let nextReset: Date

    var body: some View {
        VStack(spacing: 4) {
            Text(L10n.Common.limitReached)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.shenshaInauspicious)
            CountdownResetLabel(nextReset: nextReset)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
