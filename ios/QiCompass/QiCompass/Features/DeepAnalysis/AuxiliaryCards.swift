import SwiftUI

/// 命宫 / 身宫 / 胎元 三小卡(方案 §一 AuxiliaryCards + DESIGN.md §Color + §Ganzhi)。
struct AuxiliaryCards: View {
    let mingGong: GanZhiNaYinDTO
    let shenGong: GanZhiNaYinDTO
    let taiYuan: GanZhiNaYinDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("辅柱")
                .zcoolCardTitle()
            HStack(spacing: 10) {
                AuxiliaryCard(title: "命宫", ganzhi: mingGong)
                AuxiliaryCard(title: "身宫", ganzhi: shenGong)
                AuxiliaryCard(title: "胎元", ganzhi: taiYuan)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.cardBorder, lineWidth: 0.5))
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
        .padding(10)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.sm).stroke(BaziTheme.cardBorder, lineWidth: 0.5))
    }
}
