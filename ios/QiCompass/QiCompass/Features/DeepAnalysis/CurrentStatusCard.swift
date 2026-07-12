import SwiftUI

/// 当前柱状态卡(方案 §一 CurrentStatusCard)。
///
/// 展示当前大运/流年/流日/流时。字段可能为 nil(后端未排或边界),
/// nil 时显示"未排"(不静默用假数据)。
struct CurrentStatusCard: View {
    let response: BaziResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前柱")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)
            row("大运", response.currentLuckPillar?.ganZhi)
            row("流年", response.currentYearPillar)
            row("流日", response.currentDayPillar)
            row("流时", response.currentHourPillar)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BaziTheme.cardBorder, lineWidth: 1))
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(BaziTheme.textDim)
            Spacer()
            Text(value ?? "未排")
                .font(.body.weight(.medium))
                .foregroundStyle(value != nil ? BaziTheme.goldLight : BaziTheme.textDim)
        }
    }
}
