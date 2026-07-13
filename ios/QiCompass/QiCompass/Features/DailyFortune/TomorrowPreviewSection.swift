import SwiftUI

/// 明日预告(单行展示流日柱 / 关系 / 冲)。DESIGN.md §Color 流日柱 cinnabar 强调。
struct TomorrowPreviewSection: View {
    let preview: TomorrowPreviewDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("明日预告")
                    .zcoolCardTitle()
                Spacer()
                Image(systemName: "moon.stars")
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            HStack(spacing: 12) {
                Text(preview.dayPillar)
                    .font(BaziFont.ganzhi(size: 18))
                    .foregroundStyle(BaziTheme.cinnabar)
                Text(preview.dayRelation)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(BaziTheme.jade)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(BaziTheme.cinnabarSoft, in: Capsule())
                if let chong = preview.dayChong {
                    Text("冲\(chong)")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                }
            }
        }
        .padding(16)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.cardBorder, lineWidth: 0.5)
        )
    }
}
