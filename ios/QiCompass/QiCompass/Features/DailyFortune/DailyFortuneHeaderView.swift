import SwiftUI

/// 每日运势头部(V4 三行式 + V1 元素整合,2026-08-31,参考 v4-reference.html +
/// daily-fortune-v1.html):L1 公历大字(gregorianShort)+ 周几小字(weekdayShort)→
/// L2 符牌图 + 农历 · 干支日 → L3 短标签 chip + 关系 chip(符牌可选)+ 冲 chip(双兽符牌)。
/// 三行紧凑沉在 hero 插画上方;不入框(V4 参考图口径——框只留给宜忌与解读两块)。
///
/// i18n 改造(Slice 1.11)保持:
/// - 公历日期:`BaziDateFormatter.gregorianShort` + `weekdayShort`(按 user locale 显示)
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

    /// 关系 chip 配图:刃(PlaqueSha)= 克身之压力,只配官杀族(七杀/正官);
    /// 其余十神(印/财/食伤/比劫)语义不合,回纯文字 chip。
    /// 后续若补全十神符牌图,删 gate 恢复全配(V1 拍板口径)。
    static func relationIcon(for relation: String) -> String? {
        relation == "七杀" || relation == "正官" ? "PlaqueSha" : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // L1 公历大字 + 周几次级(V1 拆分采纳;字号 21 收敛,视觉主角让位下方 hero)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(BaziDateFormatter.gregorianShort.string(from: businessDate))
                    .font(BaziFont.display(size: 21))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.ink)
                Text(BaziDateFormatter.weekdayShort.string(from: businessDate))
                    .font(BaziFont.caption(size: 12))
                    .tracking(1.3)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            // L2 符牌图(日轮)+ 农历 · 干支日(灰墨小字)
            HStack(spacing: 7) {
                PlaqueIcon(iconName: "PlaqueLiuri", height: 17)
                Text(verbatim: "\(L10n.DailyFortune.lunarPrefix) \(lunarDate) · \(dayPillar)\(L10n.DailyFortune.dayPillarSuffix)")
                    .font(BaziFont.caption(size: 12.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            // L3 短标签 chip + 关系 chip(刃符牌,gate 官杀族)+ 冲 chip(双兽符牌)
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
                ChipView(text: dayRelation, tint: BaziTheme.cinnabar, iconName: Self.relationIcon(for: dayRelation))
                if let chong = dayChong {
                    let label = L10n.DailyFortune.chongLabel(
                        chong: chong,
                        targets: dayChongTargets
                    )
                    ChipView(text: label, tint: BaziTheme.inkMuted, iconName: "PlaqueChong")
                }
                Spacer()
            }
            .padding(.top, 2)
        }
    }
}

/// 古篆符牌小图(V1,2026-08-31 拍板):Asset Catalog 双 variant,
/// 夜宣纸自动切亮迹版,无需运行时 blend 处理。
struct PlaqueIcon: View {
    let iconName: String
    let height: CGFloat

    var body: some View {
        Image(iconName)
            .resizable()
            .scaledToFit()
            .frame(height: height)
    }
}

/// 通用 chip:小标签 + 可选符牌小图 + tint 描边(Capsule 留给 chip,DESIGN.md §Layout)。
struct ChipView: View {
    let text: String
    let tint: Color
    var iconName: String?

    init(text: String, tint: Color, iconName: String? = nil) {
        self.text = text
        self.tint = tint
        self.iconName = iconName
    }

    var body: some View {
        HStack(spacing: 4) {
            if let iconName {
                PlaqueIcon(iconName: iconName, height: 13)
            }
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(tint.opacity(0.06), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 0.5))
    }
}
