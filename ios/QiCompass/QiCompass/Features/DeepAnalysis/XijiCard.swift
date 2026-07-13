import SwiftUI

/// 喜忌卡(DESIGN.md §Color + 方案 §一 XijiCard + §4.7 special_pattern 降级)。
///
/// 正常盘:喜用(jade)/忌讳(cinnabar)chips + 旺衰 + 调候触发标记 + 算法说明。
/// 从格(special_pattern):标题改"命局呈现从格特征",不显示喜忌 chips,
/// 显示"喜忌结论留空,详见命书"(LLM 文本由后端追加降级段)。
struct XijiCard: View {
    let response: BaziResponse

    private var isSpecialPattern: Bool {
        response.dayMasterStrength == "special_pattern"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isSpecialPattern ? "命局呈现从格特征" : "喜忌分析")
                    .zcoolCardTitle()
                Spacer()
                strengthBadge
            }

            if isSpecialPattern {
                Text("喜忌结论留空,详见命书。")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
                if let hint = response.patternHint {
                    Text("特征:\(hint == "zhuanwang" ? "专旺" : "从格")")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            } else {
                if !response.favorableElements.isEmpty {
                    elementRow(label: "喜用", elements: response.favorableElements, isFavorable: true)
                }
                if !response.unfavorableElements.isEmpty {
                    elementRow(label: "忌讳", elements: response.unfavorableElements, isFavorable: false)
                }
            }

            if response.tiaoshouApplied {
                Text("◎ 调候用神已触发")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.jade)
            }
            if let method = response.xijiMethod {
                Text("算法:\(method)")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.cardBorder, lineWidth: 0.5))
    }

    /// 旺衰 badge:jade 底 + jade 字(吉兆语义,DESIGN.md §Color 墨青)。
    private var strengthBadge: some View {
        let text: String
        switch response.dayMasterStrength {
        case "strong":           text = "身强"
        case "weak":             text = "身弱"
        case "balanced":         text = "中和"
        case "special_pattern":  text = "从格"
        default:                 text = "—"
        }
        return Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(BaziTheme.jade.opacity(0.15), in: Capsule())
            .foregroundStyle(BaziTheme.jade)
    }

    private func elementRow(label: String, elements: [String], isFavorable: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            ForEach(elements, id: \.self) { elem in
                elementChip(elem)
            }
            Spacer()
        }
    }

    /// 五行 chip:五行色描边 + 半透明底(Capsule 留给 chip)。
    private func elementChip(_ elem: String) -> some View {
        let color: Color = {
            guard let key = ElementColors.fromZh(elem) else { return BaziTheme.inkMuted }
            return ElementColors.from(key)?.color ?? BaziTheme.inkMuted
        }()
        return Text(elem)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 0.5))
    }
}
