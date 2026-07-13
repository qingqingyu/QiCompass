import SwiftUI

/// 大运横向时间轴(DESIGN.md §Color 当前柱 cinnabar + 方案 §一 LuckPillarsTimeline + §4.8 童限过滤)。
///
/// 后端已跳过 index=0 童限(ganZhi=""),前端仍防御性过滤 ganZhi 为空的项,
/// 避免后端契约变化或老快照 payload 残留童限项导致 UI 渲染空白柱。
/// 当前柱高亮:cinnabarSoft 底 + cinnabar 文字 + cinnabar 描边。
struct LuckPillarsTimeline: View {
    let luckPillars: [LuckPillarDTO]
    let currentLuckPillar: CurrentPillarDTO?

    private var validPillars: [LuckPillarDTO] {
        luckPillars.filter { !$0.ganZhi.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("大运")
                .zcoolCardTitle()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(validPillars.enumerated()), id: \.offset) { _, lp in
                        luckColumn(lp, isCurrent: isCurrent(lp))
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.cardBorder, lineWidth: 0.5))
    }

    private func luckColumn(_ lp: LuckPillarDTO, isCurrent: Bool) -> some View {
        VStack(spacing: 4) {
            Text("\(lp.startAge)-\(lp.endAge)岁")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
            Text(lp.ganZhi)
                .font(BaziFont.ganzhi(size: 17))
                .foregroundStyle(isCurrent ? BaziTheme.cinnabar : BaziTheme.ink)
            Text("\(lp.startYear)-\(lp.endYear)")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
            if isCurrent {
                Text("当前")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(BaziTheme.cinnabar)
            }
        }
        .frame(width: 64)
        .padding(8)
        .background(
            isCurrent ? BaziTheme.cinnabarSoft : BaziTheme.cardBackground,
            in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                .stroke(isCurrent ? BaziTheme.cinnabar.opacity(0.5) : BaziTheme.cardBorder,
                        lineWidth: 0.5)
        )
    }

    private func isCurrent(_ lp: LuckPillarDTO) -> Bool {
        guard let current = currentLuckPillar else { return false }
        return lp.ganZhi == current.ganZhi
    }
}
