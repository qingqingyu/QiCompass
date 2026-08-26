import SwiftUI

/// 明日预告(水墨孤本 T1:hairline 单行,参考 daily-t1.html——「明日 · 干支 · 关系 ›」)。
struct TomorrowPreviewSection: View {
    let preview: TomorrowPreviewDTO

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L10n.DailyFortune.tomorrowTitle)
                .font(BaziFont.caption(size: 10))
                .tracking(3)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Text(preview.dayPillar)
                .font(BaziFont.ganzhi(size: 13))
                .tracking(1)
                .foregroundStyle(BaziTheme.ink)
            Text(preview.dayRelation)
                .font(.caption.weight(.medium))
                .foregroundStyle(BaziTheme.jade)
            if let chong = preview.dayChong {
                Text(L10n.DailyFortune.chongLabel(chong: chong, targets: []))
                    .font(.caption)
                    .foregroundStyle(BaziTheme.shenshaInauspicious)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .padding(.top, 14)
        .overlay(alignment: .top) {
            Rectangle().fill(BaziTheme.hairline).frame(height: 0.5)
        }
    }
}
