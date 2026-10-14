import SwiftUI

/// 命宫 / 身宫 / 胎元 三小卡(2026-10-14 仿盘面细目 HTML 目标稿:去描边、
/// Radius.lg 圆角、干支两字逐字五行着色,与四柱配色语义统一)。
struct AuxiliaryCards: View {
    let mingGong: GanZhiNaYinDTO
    let shenGong: GanZhiNaYinDTO
    let taiYuan: GanZhiNaYinDTO

    var body: some View {
        // 盘面小景 S1 卸卡:节标「辅柱」移入 HairlineSection,外层卡壳移除
        HStack(spacing: 8) {
            AuxiliaryCard(title: L10n.DeepChart.auxMingGong, ganzhi: mingGong)
            AuxiliaryCard(title: L10n.DeepChart.auxShenGong, ganzhi: shenGong)
            AuxiliaryCard(title: L10n.DeepChart.auxTaiYuan, ganzhi: taiYuan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AuxiliaryCard: View {
    let title: String
    let ganzhi: GanZhiNaYinDTO

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(BaziFont.caption(size: 11))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            ganzhiText
            Text(BaziTerms.display(ganzhi.nayin))
                .font(BaziFont.caption(size: 12))
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.lg))
    }

    /// 干支逐字五行着色(首字天干表 / 次字地支表;查不到的字符回落 ink,
    /// ganZhi 长度异常(非 2)整串 ink 直显,不猜不裁)。
    @ViewBuilder
    private var ganzhiText: some View {
        let chars = Array(ganzhi.ganZhi)
        if chars.count == 2,
           let ganColor = ElementColors.ofGan(String(chars[0])).flatMap(ElementColors.from)?.color,
           let zhiColor = ElementColors.ofZhi(String(chars[1])).flatMap(ElementColors.from)?.color {
            HStack(spacing: 2) {
                Text(String(chars[0]))
                    .foregroundStyle(ganColor)
                Text(String(chars[1]))
                    .foregroundStyle(zhiColor)
            }
            .font(BaziFont.ganzhi(size: 22))
            .fontWeight(.semibold)
        } else {
            Text(ganzhi.ganZhi)
                .font(BaziFont.ganzhi(size: 22))
                .fontWeight(.semibold)
                .foregroundStyle(BaziTheme.ink)
        }
    }
}
