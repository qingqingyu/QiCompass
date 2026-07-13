import SwiftUI

/// 四柱表(DESIGN.md §Typography + §Color + 方案 §一 PillarsTable)。
///
/// 每柱一列:天干上 / 地支下,天干十神 + 地支十神标旁,
/// 纳音小字,十二长生,旬空,藏干 chip(五行色)。
/// 日柱高亮:cinnabarSoft 底 + cinnabar 文字(替代五行色,DESIGN.md §04 mockup)。
struct PillarsTable: View {
    let pillars: PillarsDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("四柱")
                .zcoolCardTitle()
            HStack(alignment: .top, spacing: 10) {
                PillarColumn(title: "年", pillar: pillars.year)
                PillarColumn(title: "月", pillar: pillars.month)
                PillarColumn(title: "日", isDay: true, pillar: pillars.day)
                PillarColumn(title: "时", pillar: pillars.hour)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.cardBorder, lineWidth: 0.5))
    }
}

private struct PillarColumn: View {
    let title: String
    var isDay: Bool = false
    let pillar: PillarDTO

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            // 天干
            Text(pillar.gan)
                .font(BaziFont.ganzhi(size: 22))
                .foregroundStyle(ganColor)
            Text(pillar.shishenGan)
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
            // 地支
            Text(pillar.zhi)
                .font(BaziFont.ganzhi(size: 22))
                .foregroundStyle(zhiColor)
            // 地支十神(可能多个)
            VStack(spacing: 2) {
                ForEach(pillar.shishenZhi, id: \.self) { s in
                    Text(s)
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }
            // 纳音(次要信息,inkMuted)
            Text(pillar.nayin)
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
            // 十二长生
            Text("长生:\(pillar.dishi)")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
            // 旬空
            Text("旬空:\(pillar.xunkong)")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
            // 藏干 chip(Capsule 留给 chip)
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
        .background(
            isDay ? BaziTheme.cinnabarSoft : BaziTheme.cardBackground,
            in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                .stroke(isDay ? BaziTheme.cinnabar.opacity(0.4) : BaziTheme.cardBorder,
                        lineWidth: 0.5)
        )
    }

    /// 日柱天干用 cinnabar(日主强调);其他柱走五行色。
    private var ganColor: Color {
        if isDay { return BaziTheme.cinnabar }
        guard let key = ElementColors.ofGan(pillar.gan) else { return BaziTheme.ink }
        return ElementColors.from(key)?.color ?? BaziTheme.ink
    }

    /// 日柱地支用 cinnabar(日主强调);其他柱走五行色。
    private var zhiColor: Color {
        if isDay { return BaziTheme.cinnabar }
        return ElementColors.from(pillar.zhiElement)?.color ?? BaziTheme.ink
    }

    private func hideGanColor(_ gan: String) -> Color {
        guard let key = ElementColors.ofGan(gan) else { return BaziTheme.inkMuted }
        return ElementColors.from(key)?.color ?? BaziTheme.inkMuted
    }
}
