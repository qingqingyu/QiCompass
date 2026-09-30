import SwiftUI

/// 喜忌卡(DESIGN.md §Color + 方案 §一 XijiCard + §4.7 special_pattern 降级)。
///
/// 正常盘:喜用(jade)/忌神(cinnabar)chips + 旺衰 + 调候触发标记 + 算法说明。
/// 从格(special_pattern):标题改"命局呈现从格特征",不显示喜忌 chips,
/// 显示"喜忌结论留空,详见命书"(LLM 文本由后端追加降级段)。
struct XijiCard: View {
    let response: BaziResponse

    private var isSpecialPattern: Bool {
        response.dayMasterStrength == "special_pattern"
    }

    var body: some View {
        // 盘面小景 S1 卸卡:节标「喜忌分析」与身弱 badge 移入 HairlineSection
        // (title + trailing 小注);这里只留内容行。从格降级文案保留。
        VStack(alignment: .leading, spacing: 10) {
            if isSpecialPattern {
                Text("喜忌结论留空,详见命书。")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
                if let hint = response.patternHint {
                    Text(L10n.DeepChart.patternHint(BaziTerms.display(hint == "zhuanwang" ? "专旺" : "从格")))
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            } else {
                if !response.favorableElements.isEmpty {
                    elementRow(label: L10n.DeepChart.xijiFavorable, elements: response.favorableElements, isFavorable: true)
                }
                if !response.unfavorableElements.isEmpty {
                    elementRow(label: L10n.DeepChart.xijiUnfavorable, elements: response.unfavorableElements, isFavorable: false)
                }
            }

            if response.tiaoshouApplied {
                Text(L10n.DeepChart.tiaoshouAppliedBody)
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.jade)
            }
            if let method = response.xijiMethod {
                Text(L10n.DeepChart.xijiMethod(BaziTerms.display(method)))
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            if !isSpecialPattern {
                // S1 喜忌去绝对化:常驻一行释义,化解"喜/忌 = 生活禁忌"的读法
                Text(L10n.DeepChart.xijiDisclaimer)
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func elementRow(label: String, elements: [String], isFavorable: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            ForEach(elements, id: \.self) { elem in
                elementChip(elem, isFavorable: isFavorable)
            }
            Spacer()
        }
    }

    /// 五行 chip(US-DA-02 混合方案):文字保留五行色,底色/描边用喜忌色(jade 喜用 / cinnabar 忌神)。
    /// 五行信息(文字)+ 喜忌区分(底色/描边)两者兼顾。显示值走 BaziTerms(取色仍按
    /// 中文稳定 id 查 ElementColors,与显示语言解耦)。
    private func elementChip(_ elem: String, isFavorable: Bool) -> some View {
        let elementColor: Color = {
            guard let key = ElementColors.fromZh(elem) else { return BaziTheme.inkMuted }
            return ElementColors.from(key)?.color ?? BaziTheme.inkMuted
        }()
        let polarityColor = isFavorable ? BaziTheme.jade : BaziTheme.cinnabar
        let xijiLabel = isFavorable ? L10n.DeepChart.xijiFavorableA11y : L10n.DeepChart.xijiUnfavorableA11y
        let displayElem = BaziTerms.display(elem)
        return Text(displayElem)
            .font(.caption.weight(.medium))
            .foregroundStyle(elementColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(polarityColor.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(polarityColor.opacity(0.4), lineWidth: 0.5))
            .accessibilityLabel("\(xijiLabel) \(displayElem)")
    }
}
