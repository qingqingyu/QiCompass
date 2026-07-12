import SwiftUI

/// 4 项定性评估的 2×2 网格(D7)。
///
/// 每张卡:标题 + 评估值(goldLight 高亮)+ 一行简短解释(ViewModel 维护映射)。
/// **不给数字分、不引入百分比**。
struct AssessmentCardGrid: View {
    let assessment: QualitativeAssessmentDTO

    private struct Card: Identifiable {
        let id = UUID()
        let title: String
        let value: String
        let explanation: String
    }

    private var cards: [Card] {
        [
            Card(
                title: "五行互补",
                value: assessment.fiveElements,
                explanation: Self.explanations[assessment.fiveElements] ?? ""
            ),
            Card(
                title: "日主关系",
                value: assessment.dayMasterRelation,
                explanation: Self.explanations[assessment.dayMasterRelation] ?? ""
            ),
            Card(
                title: "生肖匹配",
                value: assessment.zodiacMatch,
                explanation: Self.explanations[assessment.zodiacMatch] ?? ""
            ),
            Card(
                title: "地支合冲",
                value: assessment.branchHarmony,
                explanation: Self.explanations[assessment.branchHarmony] ?? ""
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("定性评估")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.goldLight)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                ],
                spacing: 8
            ) {
                ForEach(cards) { card in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(card.title)
                            .font(.caption)
                            .foregroundStyle(BaziTheme.textDim)
                        Text(card.value)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(BaziTheme.goldLight)
                        if !card.explanation.isEmpty {
                            Text(card.explanation)
                                .font(.system(size: 10))
                                .foregroundStyle(BaziTheme.textDim.opacity(0.85))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BaziTheme.cardBorder, lineWidth: 1))
                }
            }
        }
    }

    /// 评估值 → 简短解释映射(后端枚举取值集,见 compatibility.py:107-119)。
    /// 未知值留空(UI 不展示,避免编造)。
    private static let explanations: [String: String] = [
        // five_elements
        "互补佳": "五行互補,彼此补足",
        "有一定互补": "部分互补,稍有重叠",
        "互补较弱": "五行重叠较多",
        "信息不足": "信息不足,从格区间",

        // day_master_relation
        "同气": "日主同五行,性情相近",
        "相生": "日主相生,彼此扶助",
        "相克": "日主相克,易起摩擦",
        "生扶偏单向": "生扶单向,需留意平衡",

        // zodiac_match
        "六合": "地支六合,性情默契",
        "三合": "地支三合,节奏相合",
        "六冲": "地支六冲,易生矛盾",
        "三刑": "地支三刑,需多包容",
        "相害": "地支相害,沟通受阻",
        "无特殊合冲": "无特殊合冲,中性",

        // branch_harmony
        "无冲无刑": "四柱无冲无刑",
        "一冲一合": "略有冲,亦有合",
        "多冲少合": "多冲少合,需多调理",
        "多合少冲": "多合少冲,性情和谐",
        "多刑多害": "刑害较多,需谨慎",
    ]
}
