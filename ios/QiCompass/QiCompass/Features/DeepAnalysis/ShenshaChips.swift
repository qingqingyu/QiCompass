import SwiftUI

/// 神煞 chip 列表(DESIGN.md §Color 吉 jade / 凶 cinnabar + 方案 §一 ShenshaChips)。
///
/// 吉凶两色:吉神 jade(墨青,ElementColors.shenshaAuspicious)/ 凶煞暗朱砂(shenshaInauspicious)。
/// 空时显式 empty 状态。吉凶分类与后端 `backend/app/engine/shensha.py:AUSPICIOUS` 同步(11 吉 + 9 凶)。
struct ShenshaChips: View {
    let shensha: [ShenshaItemDTO]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("神煞")
                .zcoolCardTitle()

            if shensha.isEmpty {
                Text("本命盘未命中神煞")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(12)
                    .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
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
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.cardBorder, lineWidth: 0.5))
    }

    /// 单个神煞 chip(Capsule 留给 chip):吉 jade / 凶 暗朱砂。
    private func chip(_ item: ShenshaItemDTO) -> some View {
        let isAuspicious = ShenshaPolarity.isAuspicious(item.name)
        let color = isAuspicious ? BaziTheme.shenshaAuspicious : BaziTheme.shenshaInauspicious
        return HStack(spacing: 4) {
            Text(item.name)
                .font(.caption.weight(.medium))
            Text(item.position)
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 0.5))
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
