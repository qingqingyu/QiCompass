import SwiftUI

/// 五行条形图(DESIGN.md §Color 五行色保持 + 方案 §一 ElementBalanceBar)。
///
/// 横向 5 段,按五行计数比例显示,5 色 + 图例。
/// 五行色由 `ElementColors.color` 提供,已是降饱和版本(适配宣纸米底)。
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
                .zcoolCardTitle()

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
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.cardBorder, lineWidth: 0.5))
    }

    private func legendItem(color: Color, label: String, value: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text("\(label)\(value)")
                .font(.caption2)
                .foregroundStyle(BaziTheme.ink)
        }
    }
}
