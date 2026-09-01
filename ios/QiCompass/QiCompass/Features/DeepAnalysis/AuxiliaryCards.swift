import SwiftUI

/// 命宫 / 身宫 / 胎元 三小卡(方案 §一 AuxiliaryCards + DESIGN.md §Color + §Ganzhi)。
struct AuxiliaryCards: View {
    let mingGong: GanZhiNaYinDTO
    let shenGong: GanZhiNaYinDTO
    let taiYuan: GanZhiNaYinDTO

    var body: some View {
        // 盘面小景 S1 卸卡:节标「辅柱」移入 HairlineSection,外层卡壳移除
        HStack(spacing: 10) {
            AuxiliaryCard(title: "命宫", ganzhi: mingGong)
            AuxiliaryCard(title: "身宫", ganzhi: shenGong)
            AuxiliaryCard(title: "胎元", ganzhi: taiYuan)
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
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            Text(ganzhi.ganZhi)
                .font(BaziFont.ganzhi(size: 20))
                .foregroundStyle(BaziTheme.ink)
            Text(ganzhi.nayin)
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(BaziTheme.Spacing.sm)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.sm).stroke(BaziTheme.hairline, lineWidth: 0.5))
    }
}
