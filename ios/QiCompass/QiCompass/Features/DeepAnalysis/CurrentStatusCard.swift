import SwiftUI

/// 当前柱状态卡(方案 §一 CurrentStatusCard + DESIGN.md §Color)。
///
/// 展示当前大运/流年/流日/流时。字段可能为 nil(后端未排或边界),
/// nil 时显示"未排"(不静默用假数据)。
struct CurrentStatusCard: View {
    let response: BaziResponse

    var body: some View {
        // 盘面小景 S1 卸卡:节标「当前柱」移入 HairlineSection,外层卡壳移除
        VStack(alignment: .leading, spacing: 10) {
            row("大运", response.currentLuckPillar?.ganZhi)
            row("流年", response.currentYearPillar)
            row("流日", response.currentDayPillar)
            row("流时", response.currentHourPillar)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            Spacer()
            Text(value ?? "未排")
                .font(.body.weight(.medium))
                .foregroundStyle(value != nil ? BaziTheme.ink : BaziTheme.inkMuted)
        }
    }
}
