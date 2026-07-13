import SwiftUI

/// 每日运势头部:公历 + 农历 + 流日柱 + 关系 chip + 冲 chip(DESIGN.md §Color + 含 chong_targets 个性化提示)。
struct DailyFortuneHeaderView: View {
    let businessDate: Date
    let lunarDate: String
    let dayPillar: String
    let dayRelation: String
    let dayChong: String?
    let dayChongTargets: [String]

    private static let gregorianFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy年M月d日 EEEE"
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = .current
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 公历 + 农历
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(Self.gregorianFormatter.string(from: businessDate))
                    .font(BaziFont.display(size: 17, weight: .medium))
                    .foregroundStyle(BaziTheme.ink)
                Text("农历 \(lunarDate)")
                    .font(.subheadline)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            // 流日柱(大字,cinnabar 强调 — 流日柱是本日核心)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("流日柱")
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
                    let label = dayChongTargets.isEmpty
                        ? "冲\(chong)"
                        : "冲\(chong) (\(dayChongTargets.joined(separator: "、")))"
                    ChipView(text: label, tint: BaziTheme.shenshaInauspicious)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.cardBorder, lineWidth: 0.5)
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
