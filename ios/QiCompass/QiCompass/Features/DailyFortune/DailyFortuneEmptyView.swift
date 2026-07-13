import SwiftUI

/// 每日运势 CTA 空态:无命盘时引导先完成深度解析。DESIGN.md §Color 浓墨主色。
struct DailyFortuneEmptyView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sun.and.moon")
                .font(.system(size: 48))
                .foregroundStyle(BaziTheme.ink.opacity(0.4))
            Text("今日流日运势")
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
            Text("需先完成深度解析,基于命盘推演流日。")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text("完成深度解析后,本页将自动生成每日运势。")
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted.opacity(0.8))
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
