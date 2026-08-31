import SwiftUI

/// 每日运势头部(V4 三行式,2026-08-30 重排,参考 v4-reference.html):
/// L1 公历大字(含星期)→ L2 农历 · 干支日 → L3 短标签 chip + 关系 chip(朱)+ 冲 chip(灰)。
/// 三行紧凑合并沉在 hero 插画上方,与图融为一体(用户参考图 IMG_5129 排布)。
///
/// i18n 改造(Slice 1.11)保持:
/// - 公历日期:`BaziDateFormatter.gregorianWithWeekday`(按 user locale 显示)
/// - "农历" 前缀:`L10n.DailyFortune.lunarPrefix`(zh="农历",en="Lunar")
/// - 短标签:`L10n.DailyFortune.shortLabel`(zh="今日运势",en="Daily Fortune")
/// - 干支后缀:`L10n.DailyFortune.dayPillarSuffix`(zh="日",en=" Day")
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
        VStack(alignment: .leading, spacing: 5) {
            // L1 公历大字(含星期;V4 字号 24→19 收敛,视觉主角让位给下方 hero 插画)
            Text(BaziDateFormatter.gregorianWithWeekday.string(from: businessDate))
                .font(BaziFont.display(size: 19))
                .foregroundStyle(BaziTheme.ink)

            // L2 农历 · 干支日(灰墨小字)
            Text(verbatim: "\(L10n.DailyFortune.lunarPrefix) \(lunarDate) · \(dayPillar)\(L10n.DailyFortune.dayPillarSuffix)")
                .font(BaziFont.caption(size: 12.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)

            // L3 短标签 chip + 关系 chip(朱色描边,印章级)+ 冲 chip(灰)
            HStack(spacing: 8) {
                Text(L10n.DailyFortune.shortLabel)
                    .font(BaziFont.caption(size: 10))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(BaziTheme.hairline, lineWidth: 0.5)
                    )
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
            .padding(.top, 2)
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
