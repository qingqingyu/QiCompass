import SwiftUI

/// 命盘头部:命主信息 + 真太阳时偏差 + 边界 warning(DESIGN.md §Color + 方案 §一 ChartHeaderView)。
struct ChartHeaderView: View {
    let response: BaziResponse
    let request: BaziCalculateRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Q16 δ:主标嵌入年柱干支(乾造(男) · 庚辰年)。ganZhi 来自后端 lunar_python,确定性。
                // 不加公历年注释:birthDatetime 公历年跟年柱农历年在立春边界附近会冲突,
                // 阶段 2 数据层若需要可加后端字段 gregorian_year_for_year_pillar 再 wire up。
                Text("\(genderLabel) · \(yearPillarLabel)")
                    .font(BaziFont.display(size: 20))
                    .foregroundStyle(BaziTheme.ink)
                    // 重写 VoiceOver 文案:中点 · 和括号会让读屏不连贯,改用空格分隔 + 去括号
                    .accessibilityLabel("\(genderLabelVoiceOver) \(yearPillarLabel)")
                Spacer()
                Text("真太阳时偏差 \(offsetString)")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            Text("真太阳时:\(trueSolarTimeString)")
                .font(.subheadline)
                .foregroundStyle(BaziTheme.ink)
            Text("出生地:\(cityDisplay)")
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            Text("hash: \(String(response.contentHash.prefix(12)))…")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(BaziTheme.inkMuted)
            if let warning = response.boundaryWarning {
                Text("⚠ \(warning)")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.cinnabar)
                    .padding(BaziTheme.Spacing.sm)
                    .background(BaziTheme.cinnabarSoft, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BaziTheme.Spacing.md)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.hairline, lineWidth: 0.5))
    }

    private var genderLabel: String {
        request.gender == "male" ? "乾造(男)" : "坤造(女)"
    }

    /// VoiceOver 用:去括号,空格分隔,避免读屏读"左括号 男 右括号"不连贯。
    private var genderLabelVoiceOver: String {
        genderLabel
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: "")
    }

    /// Q16 δ + Q12/13:年柱文字(如 `庚辰年`)。ganZhi 来自后端 lunar_python 确定性推算。
    /// 仅显示年柱干支 + "年"字,不加公历年注释(避免立春边界冲突)。
    /// 防御 ganZhi 为空(对齐项目范式:LuckPillarsTimeline / PromptContextBuilder 都做防御)。
    private var yearPillarLabel: String {
        let gz = response.pillars.year.ganZhi
        return gz.isEmpty ? "—" : "\(gz)年"
    }

    private var cityDisplay: String {
        request.city ?? "手动经度 \(request.longitude ?? 0)"
    }

    private var offsetString: String {
        let mins = response.trueSolarOffsetMinutes
        let sign = mins >= 0 ? "+" : ""
        return String(format: "%@%.1f 分", sign, mins)
    }

    private var trueSolarTimeString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = .current
        return f.string(from: response.trueSolarTime)
    }
}
