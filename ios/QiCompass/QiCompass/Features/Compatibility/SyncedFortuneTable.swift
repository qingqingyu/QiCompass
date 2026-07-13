import SwiftUI

/// 3 年流年同步表(D8)。
///
/// 颜色编码:
/// - 同步走强 → gold 背景
/// - 同步承压 → 红色文字
/// - 运势分化 / 难以定性 → textDim
struct SyncedFortuneTable: View {
    let synced: [SyncedFortuneDTO]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("流年同步(未来 3 年)")
                .zcoolCardTitle()

            VStack(spacing: 0) {
                // 表头
                HStack {
                    Text("年份").frame(maxWidth: .infinity, alignment: .leading)
                    Text("A 流年").frame(maxWidth: .infinity, alignment: .leading)
                    Text("B 流年").frame(maxWidth: .infinity, alignment: .leading)
                    Text("同步").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(BaziTheme.textDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                ForEach(Array(synced.enumerated()), id: \.element.year) { idx, sf in
                    Divider().background(BaziTheme.separator)
                    row(sf)
                }
            }
            .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BaziTheme.cardBorder, lineWidth: 1))
        }
        .fadeIn()
    }

    /// 单行:年份 + A + B + 同步标签(颜色编码)。
    private func row(_ sf: SyncedFortuneDTO) -> some View {
        let isStrong = sf.sync == "同步走强"
        let isPressure = sf.sync == "同步承压"

        return HStack(alignment: .top) {
            Text(String(sf.year))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(sf.personA)
                .font(.caption)
                .foregroundStyle(BaziTheme.text.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(sf.personB)
                .font(.caption)
                .foregroundStyle(BaziTheme.text.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(sf.sync)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(
                    isStrong ? BaziTheme.bgTop :
                    isPressure ? BaziTheme.pressureWarning :
                    BaziTheme.textDim
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    isStrong ? BaziTheme.gold : Color.clear,
                    in: Capsule()
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
