import SwiftUI

/// 五行条形图(方案 §一 ElementBalanceBar)。
///
/// 横向 5 段,按五行计数比例显示,5 色 + 图例。
struct ElementBalanceBar: View {
    let balance: ElementBalanceDTO

    private var total: Int {
        max(1, balance.wood + balance.fire + balance.earth + balance.metal + balance.water)
    }

    private var segments: [(element: ElementColors, value: Int)] {
        [
            (.wood, balance.wood),
            (.fire, balance.fire),
            (.earth, balance.earth),
            (.metal, balance.metal),
            (.water, balance.water),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("五行分布")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)

            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(segments.indices, id: \.self) { idx in
                        let seg = segments[idx]
                        Rectangle()
                            .fill(seg.element.color)
                            .frame(width: max(2, geo.size.width * CGFloat(seg.value) / CGFloat(total)))
                    }
                }
                .frame(height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 24)

            HStack(spacing: 8) {
                ForEach(segments.indices, id: \.self) { idx in
                    let seg = segments[idx]
                    legendItem(color: seg.element.color, label: seg.element.label, value: seg.value)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BaziTheme.cardBorder, lineWidth: 1))
    }

    private func legendItem(color: Color, label: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label)\(value)")
                .font(.caption2)
                .foregroundStyle(BaziTheme.text)
        }
    }
}
