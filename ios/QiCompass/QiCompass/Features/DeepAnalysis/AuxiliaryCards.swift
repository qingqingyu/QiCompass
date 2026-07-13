import SwiftUI

/// 命宫 / 身宫 / 胎元 三小卡(方案 §一 AuxiliaryCards)。
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
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BaziTheme.cardBorder, lineWidth: 1))
    }
}

private struct AuxiliaryCard: View {
    let title: String
    let ganzhi: GanZhiNaYinDTO

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(BaziTheme.textDim)
            Text(ganzhi.ganZhi)
                .font(BaziFont.zcoolTitle(size: 20))
                .foregroundStyle(BaziTheme.goldLight)
            Text(ganzhi.nayin)
                .font(.caption2)
                .foregroundStyle(BaziTheme.gold.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BaziTheme.cardBorder, lineWidth: 1))
    }
}
