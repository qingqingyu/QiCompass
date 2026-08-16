import SwiftUI

/// 每日运势空态:无命盘存档。B2 之后 onboarding 出生表单即建盘,正常路径到不了
/// 这里(仅存档被清时出现);不再引导"先做深度解析"(旧口径,2026-08-16 改)。
struct DailyFortuneEmptyView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "sun.and.moon")
                .font(.system(size: 48))
                .foregroundStyle(BaziTheme.ink.opacity(0.4))
            Text("今日流日运势")
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
            Text("还没有你的命盘。")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Text("完成出生信息录入后,本页将自动生成每日运势。")
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted.opacity(0.8))
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
