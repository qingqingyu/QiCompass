import SwiftUI

/// 神煞 chip 列表(方案 §一 ShenshaChips)。
///
/// 吉凶两色(吉神金色 / 凶煞暗红)。空时显式 empty 状态。
/// 吉凶分类与后端 `backend/app/engine/shensha.py:AUSPICIOUS` 同步(11 吉 + 9 凶)。
struct ShenshaChips: View {
    let shensha: [ShenshaItemDTO]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("神煞")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)

            if shensha.isEmpty {
                Text("本命盘未命中神煞")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(12)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 90), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(Array(shensha.enumerated()), id: \.offset) { _, item in
                        chip(item)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BaziTheme.cardBorder, lineWidth: 1))
    }

    private func chip(_ item: ShenshaItemDTO) -> some View {
        let isAuspicious = ShenshaPolarity.isAuspicious(item.name)
        let color = isAuspicious ? BaziTheme.shenshaAuspicious : BaziTheme.shenshaInauspicious
        return HStack(spacing: 4) {
            Text(item.name)
                .font(.caption.weight(.medium))
            Text(item.position)
                .font(.caption2)
                .foregroundStyle(BaziTheme.textDim)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
    }
}

/// 神煞吉凶分类(与后端 `SHENSHA_NAMES` / `AUSPICIOUS` 同步)。
enum ShenshaPolarity {
    private static let auspiciousSet: Set<String> = [
        "天乙贵人", "太极贵人", "文昌", "天德", "月德",
        "驿马", "桃花", "将星", "华盖", "金舆", "禄神",
    ]

    static func isAuspicious(_ name: String) -> Bool {
        auspiciousSet.contains(name)
    }
}
