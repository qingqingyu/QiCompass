import SwiftUI

/// 每日运势头部(水墨孤本 T1,2026-08-26 重排,参考 daily-t1.html):
/// 开放布局无卡片——日期行(公历大字 + 农历/年月右对齐)→ 流日行
/// (小标 + 干支 + 关系 chip 朱色描边 + 冲 chip 灰)。
///
/// i18n 改造(Slice 1.11)保持:
/// - 公历日期:`BaziDateFormatter.gregorianWithWeekday`(按 user locale 显示)
/// - "农历" 前缀:`L10n.DailyFortune.lunarPrefix`(zh="农历",en="Lunar")
/// - "流日柱" 标签:`L10n.DailyFortune.dayPillarLabel`(zh="流日柱",en="Day Pillar")
/// - "冲" 前缀:`L10n.DailyFortune.chongLabel(chong:targets:)`
/// - 农历日期本身(`lunarDate` 参数)永远来自后端中文格式(决策 7:农历是术语不翻译)
struct DailyFortuneHeaderView: View {
    let businessDate: Date
    let lunarDate: String
    let dayPillar: String
    let dayRelation: String
    let dayChong: String?
    let dayChongTargets: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 日期行:公历大字左,农历 + 干支年月右(两端)
            HStack(alignment: .firstTextBaseline) {
                Text(BaziDateFormatter.gregorianWithWeekday.string(from: businessDate))
                    .font(BaziFont.display(size: 24))
                    .foregroundStyle(BaziTheme.ink)
                Spacer(minLength: 12)
                Text(verbatim: "\(L10n.DailyFortune.lunarPrefix) \(lunarDate)")
                    .font(BaziFont.caption(size: 10.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
            }

            // 流日行:小标 + 干支(浓墨)+ 关系 chip(朱色描边,印章级)+ 冲 chip(灰)
            HStack(spacing: 10) {
                Text(L10n.DailyFortune.dayPillarLabel)
                    .font(BaziFont.caption(size: 10))
                    .tracking(3)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Text(dayPillar)
                    .font(BaziFont.ganzhi(size: 17))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.ink)
                ChipView(text: dayRelation, tint: BaziTheme.cinnabar)
                if let chong = dayChong {
                    let label = L10n.DailyFortune.chongLabel(
                        chong: chong,
                        targets: dayChongTargets
                    )
                    ChipView(text: label, tint: BaziTheme.inkMuted)
                }
                Spacer()
            }
        }
    }
}

/// 通用 chip:小标签 + tint 描边(Capsule 留给 chip,DESIGN.md §Layout)。
struct ChipView: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 0.5))
    }
}
