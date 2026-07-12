import SwiftUI

/// 合盘空态:无已存档命盘 → 引导去深度解析 Tab。
///
/// 决策 D3:CTA 触发 `.switchTab` Notification,RootTabView 监听切到深度解析。
struct CompatibilityEmptyView: View {
    let onSwitchToDeepAnalysis: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2")
                .font(.system(size: 48))
                .foregroundStyle(BaziTheme.gold.opacity(0.6))
            Text("双人合盘")
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)
            Text("需先在深度解析中创建命盘,才能选择 A/B 盘合盘。")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.textDim)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(action: onSwitchToDeepAnalysis) {
                HStack {
                    Image(systemName: "arrow.right.circle")
                    Text("去深度解析")
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(BaziTheme.bgTop)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(BaziTheme.gold, in: Capsule())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
