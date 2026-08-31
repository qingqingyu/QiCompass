import SwiftUI

/// 明日预告(今日运势 V1:不入框,hairline 单行——「明日预告 · 干支 · 关系 ›」,参考 daily-fortune-v1.html)。
struct TomorrowPreviewSection: View {
    let preview: TomorrowPreviewDTO

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L10n.DailyFortune.tomorrowTitle)
                .font(BaziFont.caption(size: 10))
                .tracking(3)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Text(preview.dayPillar)
                .font(BaziFont.ganzhi(size: 14))
                .tracking(1.4)
                .foregroundStyle(BaziTheme.ink)
            Text(preview.dayRelation)
                .font(.caption.weight(.medium))
                .foregroundStyle(BaziTheme.jade)
            if let chong = preview.dayChong {
                Text(L10n.DailyFortune.chongLabel(chong: chong, targets: []))
                    .font(.caption)
                    .foregroundStyle(BaziTheme.cinnabar)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .padding(.top, 18)
        .overlay(alignment: .top) {
            Rectangle().fill(BaziTheme.hairline).frame(height: 0.5)
        }
    }
}
