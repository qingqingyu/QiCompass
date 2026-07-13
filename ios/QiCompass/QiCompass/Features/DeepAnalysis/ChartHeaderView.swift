import SwiftUI

/// 命盘头部:命主信息 + 真太阳时偏差 + 边界 warning(DESIGN.md §Color + 方案 §一 ChartHeaderView)。
struct ChartHeaderView: View {
    let response: BaziResponse
    let request: BaziCalculateRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(genderLabel)
                    .font(BaziFont.display(size: 20))
                    .foregroundStyle(BaziTheme.ink)
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
                    .padding(8)
                    .background(BaziTheme.cinnabarSoft, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.cardBorder, lineWidth: 0.5))
    }

    private var genderLabel: String {
        request.gender == "male" ? "乾造(男)" : "坤造(女)"
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
