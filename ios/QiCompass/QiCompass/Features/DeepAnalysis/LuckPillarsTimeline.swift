import SwiftUI

/// 大运横向时间轴(DESIGN.md §Color 当前柱 cinnabar + 方案 §一 LuckPillarsTimeline + §4.8 童限过滤)。
///
/// 后端已跳过 index=0 童限(ganZhi=""),前端仍防御性过滤 ganZhi 为空的项,
/// 避免后端契约变化或老快照 payload 残留童限项导致 UI 渲染空白柱。
/// 当前柱高亮:cinnabarSoft 底 + cinnabar 文字 + cinnabar 描边。
/// 四行固定(年龄 / 干支 / 年份 / 当前占位),整排等高(2026-10-17 对齐修复)。
struct LuckPillarsTimeline: View {
    let luckPillars: [LuckPillarDTO]
    let currentLuckPillar: CurrentPillarDTO?

    /// 卡内容宽:随 Dynamic Type 放大(原写死 64,大字号下年龄/年份被挤成两行)。
    /// Scaled 后缀 = DeepAnalysisHomeView @ScaledMetric 命名先例。
    @ScaledMetric(relativeTo: .caption2) private var columnWidthScaled: CGFloat = 64

    private var validPillars: [LuckPillarDTO] {
        luckPillars.filter { !$0.ganZhi.isEmpty }
    }

    var body: some View {
        // 盘面小景 S1 卸卡:节标「大运」移入 HairlineSection,外层卡壳移除
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(validPillars.enumerated()), id: \.offset) { _, lp in
                    luckColumn(lp, isCurrent: isCurrent(lp))
                }
            }
            // 行高 = 最高那张卡,其余卡由 luckColumn 内 maxHeight 拉齐
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func luckColumn(_ lp: LuckPillarDTO, isCurrent: Bool) -> some View {
        VStack(spacing: 4) {
            // 保留本地化键 "%lld-%lld岁"(en "yrs" / zh-Hant「歲」),不可改 verbatim
            Text("\(lp.startAge)-\(lp.endAge)岁")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(lp.ganZhi)
                .font(BaziFont.ganzhi(size: 17))
                .foregroundStyle(isCurrent ? BaziTheme.cinnabar : BaziTheme.ink)
                .lineLimit(1)
            // verbatim:LocalizedStringKey 的 Int 插值会按 locale 加千分位(1,998)
            Text(verbatim: "\(lp.startYear)-\(lp.endYear)")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            // 每张卡都占「当前」这一行,非当前卡隐藏 → 整排等高
            Text("当前")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(BaziTheme.cinnabar)
                .opacity(isCurrent ? 1 : 0)
                .accessibilityHidden(!isCurrent)
        }
        .frame(width: columnWidthScaled)
        // 等高兜底:须在 padding/background 之前,否则只拉高布局框、底色描边不跟
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(BaziTheme.Spacing.sm)
        .background(
            isCurrent ? BaziTheme.cinnabarSoft : BaziTheme.cardSurface,
            in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                .stroke(isCurrent ? BaziTheme.cinnabar.opacity(0.5) : BaziTheme.hairline,
                        lineWidth: 0.5)
        )
    }

    /// 「当前大运」判定(纯函数供单测,A4):比 startYear 而非 ganZhi——
    /// 60 甲子一轮回, ganZhi 相同的两柱(如 60 年前后两步同干支大运)会双高亮;
    /// startYear 是后端给的单调定位键,与 CurrentPillarDTO 逐柱唯一对齐。
    /// 同 startYear 不同 ganZhi(防御:后端契约异常)不高亮,不猜。
    static func isCurrent(_ lp: LuckPillarDTO, current: CurrentPillarDTO?) -> Bool {
        guard let current else { return false }
        return lp.startYear == current.startYear
    }

    private func isCurrent(_ lp: LuckPillarDTO) -> Bool {
        Self.isCurrent(lp, current: currentLuckPillar)
    }
}
