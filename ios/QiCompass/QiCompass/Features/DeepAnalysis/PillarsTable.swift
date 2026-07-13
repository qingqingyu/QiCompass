import SwiftUI

/// 四柱表(方案 §一 PillarsTable)。
///
/// 每柱一列:天干上 / 地支下,天干十神 + 地支十神标旁,
/// 纳音小字,十二长生,旬空,藏干 chip(五行色)。
struct PillarsTable: View {
    let pillars: PillarsDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("四柱")
                .zcoolCardTitle()
            HStack(alignment: .top, spacing: 10) {
                PillarColumn(title: "年", pillar: pillars.year)
                PillarColumn(title: "月", pillar: pillars.month)
                PillarColumn(title: "日", pillar: pillars.day)
                PillarColumn(title: "时", pillar: pillars.hour)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BaziTheme.cardBorder, lineWidth: 1))
    }
}

private struct PillarColumn: View {
    let title: String
    let pillar: PillarDTO

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(BaziTheme.textDim)
            // 天干
            Text(pillar.gan)
                .font(BaziFont.zcoolTitle(size: 22))
                .foregroundStyle(ganColor)
            Text(pillar.shishenGan)
                .font(.caption2)
                .foregroundStyle(BaziTheme.textDim)
            // 地支
            Text(pillar.zhi)
                .font(BaziFont.zcoolTitle(size: 22))
                .foregroundStyle(zhiColor)
            // 地支十神(可能多个)
            VStack(spacing: 2) {
                ForEach(pillar.shishenZhi, id: \.self) { s in
                    Text(s)
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.textDim)
                }
            }
            // 纳音
            Text(pillar.nayin)
                .font(.caption2)
                .foregroundStyle(BaziTheme.gold.opacity(0.8))
            // 十二长生
            Text("长生:\(pillar.dishi)")
                .font(.caption2)
                .foregroundStyle(BaziTheme.textDim)
            // 旬空
            Text("旬空:\(pillar.xunkong)")
                .font(.caption2)
                .foregroundStyle(BaziTheme.textDim)
            // 藏干 chip
            HStack(spacing: 4) {
                ForEach(pillar.hideGan, id: \.self) { gan in
                    Text(gan)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(hideGanColor(gan))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(hideGanColor(gan).opacity(0.15), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(8)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var ganColor: Color {
        guard let key = ElementColors.ofGan(pillar.gan) else { return BaziTheme.text }
        return ElementColors.from(key)?.color ?? BaziTheme.text
    }

    private var zhiColor: Color {
        ElementColors.from(pillar.zhiElement)?.color ?? BaziTheme.text
    }

    private func hideGanColor(_ gan: String) -> Color {
        guard let key = ElementColors.ofGan(gan) else { return BaziTheme.textDim }
        return ElementColors.from(key)?.color ?? BaziTheme.textDim
    }
}
