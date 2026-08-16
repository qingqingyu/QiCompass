import SwiftUI

/// 每日运势空态:命盘存档缺失。首启被 onboarding sheet 盖住、完成即自动重载,
/// 通常仅重置后重走 onboarding 前/存档异常时可见;不引导"先做深度解析"——那不是本模块的前置。
/// DESIGN.md §Color 浓墨主色。
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
