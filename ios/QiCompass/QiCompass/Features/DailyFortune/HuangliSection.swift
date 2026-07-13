import SwiftUI

/// 黄历宜/忌 chip 区(DESIGN.md §Color 宜 jade 吉 / 忌 cinnabar 凶)。
struct HuangliSection: View {
    let yi: [String]
    let ji: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(label: "宜", items: yi, tint: BaziTheme.jade)
            Divider().background(BaziTheme.separator)
            row(label: "忌", items: ji, tint: BaziTheme.shenshaInauspicious)
        }
        .padding(16)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.cardBorder, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func row(label: String, items: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(BaziFont.display(size: 17, weight: .medium))
                .foregroundStyle(tint)
            if items.isEmpty {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
            } else {
                FlexibleChipsView(items: items, tint: tint)
            }
        }
    }
}

/// 多行排列的 chip 列表(简单 flow layout)。
struct FlexibleChipsView: View {
    let items: [String]
    let tint: Color

    var body: some View {
        // 简化:用 LazyVGrid 3 列;后续若需 flow layout 可换 ViewThatFits
        let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.caption)
                    .foregroundStyle(BaziTheme.ink)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(tint.opacity(0.3), lineWidth: 0.5))
            }
        }
    }
}
