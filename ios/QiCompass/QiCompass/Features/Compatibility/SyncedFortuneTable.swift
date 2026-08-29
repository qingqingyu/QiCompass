import SwiftUI

/// 3 年流年同步表(D8 + DESIGN.md §Color/§Layout,水墨孤本 hairline 语言)。
///
/// 去卡片化(卡片让位 hairline,同屏 DualPillarsTable/AssessmentCardGrid 同族):
/// kicker 小标 + hairline 行分隔 + 底部 hairline 收边,无容器底色、无圆角描边框,
/// 列头规格与 DualPillarsTable 柱位行一致。取数/数据绑定不变(SyncedFortuneDTO 原样)。
///
/// 颜色编码(token 化,不自造颜色):
/// - 同步走强 → jade 文字(吉兆墨青)
/// - 同步承压 → pressureWarning 文字
/// - 运势分化 / 难以定性 → inkMuted
struct SyncedFortuneTable: View {
    let synced: [SyncedFortuneDTO]

    /// 年份列固定宽(4 位数字对齐),A/B 均分余宽,同步列尾对齐;
    /// 表头与数据行共用同一列框架保证纵向对齐。
    private let yearColumnWidth: CGFloat = 44
    private let syncColumnWidth: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("流年同步 · 未来三年")
                .font(BaziFont.caption(size: 10))
                .tracking(4)
                .foregroundStyle(BaziTheme.inkMutedSecondary)

            VStack(spacing: 0) {
                header

                ForEach(Array(synced.enumerated()), id: \.element.year) { _, sf in
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(height: 0.5)
                    row(sf)
                }
            }
            .padding(.bottom, 16)
            .overlay(alignment: .bottom) {
                // 段落收边 hairline(与 DualPillarsTable 底部收边同一语言)
                Rectangle()
                    .fill(BaziTheme.hairline)
                    .frame(height: 0.5)
            }
        }
        .fadeIn()
    }

    /// 列头:年份 / A 流年 / B 流年 / 同步(caption2 弱墨,同 DualPillarsTable 柱位行)。
    private var header: some View {
        HStack(spacing: 8) {
            Text("年份")
                .frame(width: yearColumnWidth, alignment: .leading)
            Text("A 流年")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("B 流年")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("同步")
                .frame(width: syncColumnWidth, alignment: .trailing)
        }
        .font(.caption2)
        .foregroundStyle(BaziTheme.inkMuted)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    /// 单行:年份(SF tabular 数字)+ A + B + 同步状态(纯文字颜色编码,无底色块)。
    private func row(_ sf: SyncedFortuneDTO) -> some View {
        let isStrong = sf.sync == "同步走强"
        let isPressure = sf.sync == "同步承压"

        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(sf.year))
                .font(BaziFont.numeric(size: 13, weight: .medium))
                .foregroundStyle(BaziTheme.ink)
                .frame(width: yearColumnWidth, alignment: .leading)

            Text(sf.personA)
                .font(.caption)
                .foregroundStyle(BaziTheme.ink.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(sf.personB)
                .font(.caption)
                .foregroundStyle(BaziTheme.ink.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(sf.sync)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    isStrong ? BaziTheme.jade :
                    isPressure ? BaziTheme.pressureWarning :
                    BaziTheme.inkMuted
                )
                .frame(width: syncColumnWidth, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }
}
