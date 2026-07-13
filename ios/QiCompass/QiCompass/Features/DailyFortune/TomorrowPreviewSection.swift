import SwiftUI

/// 明日预告(单行展示流日柱 / 关系 / 冲)。
struct TomorrowPreviewSection: View {
    let preview: TomorrowPreviewDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("明日预告")
                    .zcoolCardTitle()
                Spacer()
                Image(systemName: "moon.stars")
                    .foregroundStyle(BaziTheme.gold.opacity(0.7))
            }
            HStack(spacing: 12) {
                Text(preview.dayPillar)
                    .font(BaziFont.zcoolTitle(size: 18))
                    .foregroundStyle(BaziTheme.gold)
                Text(preview.dayRelation)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(BaziTheme.gold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(BaziTheme.gold.opacity(0.1), in: Capsule())
                if let chong = preview.dayChong {
                    Text("冲\(chong)")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.shenshaInauspicious)
                }
            }
        }
        .padding(16)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(BaziTheme.cardBorder, lineWidth: 1)
        )
    }
}
