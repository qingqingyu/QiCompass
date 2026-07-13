import SwiftUI

/// 每日运势头部:公历 + 农历 + 流日柱 + 关系 chip + 冲 chip(含 chong_targets 个性化提示)。
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
                    .font(BaziFont.zcoolTitle(size: 17))
                    .foregroundStyle(BaziTheme.goldLight)
                Text("农历 \(lunarDate)")
                    .font(.subheadline)
                    .foregroundStyle(BaziTheme.textDim)
            }

            // 流日柱(大字)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("流日柱")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.textDim)
                Text(dayPillar)
                    .font(BaziFont.zcoolTitle(size: 32))
                    .foregroundStyle(BaziTheme.gold)
            }

            // 关系 + 冲 chip
            HStack(spacing: 8) {
                ChipView(text: dayRelation, tint: BaziTheme.gold)
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
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(BaziTheme.cardBorder, lineWidth: 1)
        )
    }
}

/// 通用 chip:小标签 + tint 描边。
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
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
    }
}
