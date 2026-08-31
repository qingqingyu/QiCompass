import SwiftUI

/// 每日运势头部(今日运势 V1「三框全载」,2026-08-31,参考 daily-fortune-v1.html):
/// 历法信息整体入框(亮纸面浮在国画旧宣纸底上)——日期行(公历大字 + 周几小字)→
/// 流日行(小标 + 符牌图 + 干支 + 关系 chip + 冲 chip + 农历右对齐收进行内)。
///
/// i18n 改造(Slice 1.11)保持:
/// - 公历日期:`BaziDateFormatter.gregorianShort` + `weekdayShort`(按 user locale 显示)
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

    /// 关系 chip 配图:刃(PlaqueSha)= 克身之压力,只配官杀族(七杀/正官);
    /// 其余十神(印/财/食伤/比劫)语义不合,回纯文字 chip。
    /// 画布 mock 恒为七杀(2026-08-31 拍板),此 gate 保证实数据语义不错位;
    /// 后续若补全十神符牌图,删 gate 恢复全配。
    static func relationIcon(for relation: String) -> String? {
        relation == "七杀" || relation == "正官" ? "PlaqueSha" : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 日期行:公历大字 + 周几小字(V1 拍板:周几降为次级层级,年份不上头部)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(BaziDateFormatter.gregorianShort.string(from: businessDate))
                    .font(BaziFont.display(size: 26))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.ink)
                Text(BaziDateFormatter.weekdayShort.string(from: businessDate))
                    .font(BaziFont.caption(size: 13))
                    .tracking(1.3)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            // 流日行:小标 + 符牌图(日轮,D 方向)+ 干支 + 关系 chip(刃)+ 冲 chip(双兽)+ 农历右收
            HStack(spacing: 7) {
                Text(L10n.DailyFortune.dayPillarLabel)
                    .font(BaziFont.caption(size: 10))
                    .tracking(3.5)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                PlaqueIcon(iconName: "PlaqueLiuri", height: 24)
                Text(dayPillar)
                    .font(BaziFont.ganzhi(size: 19))
                    .tracking(3.8)
                    .foregroundStyle(BaziTheme.ink)
                ChipView(text: dayRelation, tint: BaziTheme.cinnabar, iconName: Self.relationIcon(for: dayRelation))
                if let chong = dayChong {
                    let label = L10n.DailyFortune.chongLabel(
                        chong: chong,
                        targets: dayChongTargets
                    )
                    ChipView(text: label, tint: BaziTheme.inkMuted, iconName: "PlaqueChong")
                }
                Spacer(minLength: 8)
                Text(verbatim: "\(L10n.DailyFortune.lunarPrefix) \(lunarDate)")
                    .font(BaziFont.caption(size: 10))
                    .tracking(0.8)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.hairline, lineWidth: 0.5)
        )
    }
}

/// 古篆符牌小图(D 方向,2026-08-31 拍板):Asset Catalog 双 variant,
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
