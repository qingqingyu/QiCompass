import SwiftUI

/// 每日运势 CTA 空态:无命盘时引导先完成深度解析。
struct DailyFortuneEmptyView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sun.and.moon")
                .font(.system(size: 48))
                .foregroundStyle(BaziTheme.gold.opacity(0.6))
            Text("今日流日运势")
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)
            Text("需先完成深度解析,基于命盘推演流日。")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text("完成深度解析后,本页将自动生成每日运势。")
                .font(.caption)
                .foregroundStyle(BaziTheme.textDim.opacity(0.8))
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
