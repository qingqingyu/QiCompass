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
            Text("距重置:\(Self.format(max(0, remaining)))")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return String(format: "%d 时 %d 分", h, m)
    }
}
