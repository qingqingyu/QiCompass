import SwiftUI

/// 五行条形图(2026-10-14 仿盘面细目 HTML 目标稿重构)。
///
/// - 比例条:10pt 细 Capsule 段(间距 3),按计数占比;**计 0 的行不出段**
///   (零行由图例「缺」徽章表达,条上不留假段)。
/// - 图例:五等宽列,大数字(>0 五行色 / =0 inkMutedSecondary)+ 圆点行名,
///   =0 加「缺」描边小徽章。
/// - 脚注:按天干地支本气计。
///
/// 五行色由 `ElementColors.color` 提供(降饱和版,适配宣纸米底);
/// 行名经 `BaziTerms.display`(en = Wood/Fire/…)。
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
        // 盘面小景 S1 卸卡:节标「五行分布」在 HairlineSection,这里只渲染内容
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                HStack(spacing: 3) {
                    ForEach(segments.indices, id: \.self) { idx in
                        let seg = segments[idx]
                        if seg.value > 0 {
                            Capsule()
                                .fill(seg.element.color)
                                .frame(width: geo.size.width * CGFloat(seg.value) / CGFloat(total))
                        }
                    }
                }
            }
            .frame(height: 10)

            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { idx in
                    legendItem(segments[idx])
                }
            }
            .padding(.top, 16)

            Text(L10n.DeepChart.elementCaption)
                .font(BaziFont.caption(size: 11))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .padding(.top, 12)
                .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 单列图例:大数字(+ 0 行「缺」徽章)+ 圆点行名。
    /// 缺徽章跟数字同排(而非跟行名):EN "Wood Lacking" 同排会溢出 1/5 列宽
    /// (390pt 屏列宽 ~65pt),数字排恒有富余,任何语言都放得下。
    private func legendItem(_ seg: (element: ElementColors, value: Int)) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(seg.value)")
                    .font(BaziFont.numeric(size: 22, weight: .medium))
                    .foregroundStyle(seg.value > 0 ? seg.element.color : BaziTheme.inkMutedSecondary)
                if seg.value == 0 {
                    Text(L10n.DeepChart.lackLabel)
                        .font(BaziFont.caption(size: 10))
                        .foregroundStyle(ElementColors.fire.color)
                        .padding(.horizontal, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(ElementColors.fire.color.opacity(0.6), lineWidth: 0.5)
                        )
                }
            }
            HStack(spacing: 5) {
                Circle()
                    .fill(seg.element.color)
                    .frame(width: 7, height: 7)
                // L3:图例五行名走 BaziTerms(en = Wood/Fire/…);label 形参保留中文
                // 稳定 id 契约,显示语在此处转换
                Text(BaziTerms.display(seg.element.label))
                    .font(BaziFont.caption(size: 12))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(BaziTerms.display(seg.element.label)) \(seg.value)")
    }
}
