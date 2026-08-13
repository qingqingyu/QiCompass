import SwiftUI

/// 每日运势头部:公历 + 农历 + 流日柱 + 关系 chip + 冲 chip(DESIGN.md §Color + 含 chong_targets 个性化提示)。
///
/// i18n 改造(Slice 1.11):
/// - 公历日期:`BaziDateFormatter.gregorianWithWeekday`(按 user locale 显示)
/// - "农历" 前缀:`L10n.DailyFortune.lunarPrefix`(zh="农历",en="Lunar")
/// - "流日柱" 标签:`L10n.DailyFortune.dayPillarLabel`(zh="流日柱",en="Day Pillar")
/// - "冲" 前缀:`L10n.DailyFortune.chongLabel(chong:targets:)`(zh="冲X",en="Clashes: X")
/// - 农历日期本身(`lunarDate` 参数)永远来自后端中文格式(决策 7:农历是术语不翻译)
/// - 流日柱/关系/冲字符(`dayPillar`/`dayRelation`/`dayChong`)由后端按 language 翻译
struct DailyFortuneHeaderView: View {
    let businessDate: Date
    let lunarDate: String
    let dayPillar: String
    let dayRelation: String
    let dayChong: String?
    let dayChongTargets: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 公历 + 农历
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(BaziDateFormatter.gregorianWithWeekday.string(from: businessDate))
                    .font(BaziFont.display(size: 17, weight: .medium))
                    .foregroundStyle(BaziTheme.ink)
                // 农历前缀本地化,日期本身保留中文(术语)
                Text(verbatim: "\(L10n.DailyFortune.lunarPrefix) \(lunarDate)")
                    .font(.subheadline)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            // 流日柱(大字,cinnabar 强调 — 流日柱是本日核心)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(L10n.DailyFortune.dayPillarLabel)
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
                Text(dayPillar)
                    .font(BaziFont.ganzhi(size: 32))
                    .foregroundStyle(BaziTheme.cinnabar)
            }

            // 关系 + 冲 chip
            HStack(spacing: 8) {
                ChipView(text: dayRelation, tint: BaziTheme.jade)
                if let chong = dayChong {
                    let label = L10n.DailyFortune.chongLabel(
                        chong: chong,
                        targets: dayChongTargets
                    )
                    ChipView(text: label, tint: BaziTheme.shenshaInauspicious)
                }
                Spacer()
            }
        }
        .padding(BaziTheme.Spacing.md)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.hairline, lineWidth: 0.5)
        )
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
            .background(tint.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 0.5))
    }
}
