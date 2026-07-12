import SwiftUI

/// 已存档命盘选择器(A 盘 / B 模式 A 复用)。
///
/// 单选 List 行:alias + birthDate + dayMaster。点击行切换选中态。
/// 决策 D3:iPhone 屏宽适配,内联 List 行而非大卡片。
struct ChartArchivePickerView: View {
    let title: String
    let charts: [ArchivedChart]
    @Binding var selectedIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)

            VStack(spacing: 0) {
                ForEach(Array(charts.enumerated()), id: \.element.id) { idx, chart in
                    Button {
                        selectedIndex = idx
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chart.alias)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(BaziTheme.text)
                                HStack(spacing: 8) {
                                    Text(Self.dateFormatter.string(from: chart.birthDate))
                                        .font(.caption)
                                        .foregroundStyle(BaziTheme.textDim)
                                    Text("日主 \(chart.dayMaster)")
                                        .font(.caption)
                                        .foregroundStyle(BaziTheme.gold.opacity(0.85))
                                }
                            }
                            Spacer()
                            if idx == selectedIndex {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(BaziTheme.gold)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(BaziTheme.textDim.opacity(0.5))
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            idx == selectedIndex
                                ? BaziTheme.gold.opacity(0.08)
                                : Color.clear
                        )
                    }
                    if idx < charts.count - 1 {
                        Divider().background(BaziTheme.separator)
                    }
                }
            }
            .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BaziTheme.cardBorder, lineWidth: 1))
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}
