import SwiftUI

/// 每日运势 CTA 空态:无命盘时引导先完成深度解析。DESIGN.md §Color 浓墨主色。
struct DailyFortuneEmptyView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sun.and.moon")
                .font(.system(size: 48))
                .foregroundStyle(BaziTheme.ink.opacity(0.4))
            Text(L10n.DailyFortune.emptyTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
            Text(L10n.DailyFortune.emptySubtitle1)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text(L10n.DailyFortune.emptySubtitle2)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted.opacity(0.8))
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
