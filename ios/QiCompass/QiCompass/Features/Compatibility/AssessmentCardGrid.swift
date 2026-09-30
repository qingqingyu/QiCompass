import SwiftUI

/// 4 项定性评估的 2×2 网格(水墨孤本 H3:hairline 网格,无卡片底,参考 hepan-h3-detail.html)。
///
/// 每格:标题(淡灰小标)+ 评估值(楷体浓墨)+ 一行简短解释。
/// **不给数字分、不引入百分比**(定性不给分决策不变)。
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
                title: String(localized: "五行互补"),
                value: BaziTerms.display(assessment.fiveElements),
                explanation: Self.explanation(for: assessment.fiveElements)
            ),
            Card(
                title: String(localized: "日主关系"),
                value: BaziTerms.display(assessment.dayMasterRelation),
                explanation: Self.explanation(for: assessment.dayMasterRelation)
            ),
            Card(
                title: String(localized: "生肖匹配"),
                value: BaziTerms.display(assessment.zodiacMatch),
                explanation: Self.explanation(for: assessment.zodiacMatch)
            ),
            Card(
                title: String(localized: "地支合冲"),
                value: BaziTerms.display(assessment.branchHarmony),
                explanation: Self.explanation(for: assessment.branchHarmony)
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("合拍定性 · 无评分")
                .font(BaziFont.caption(size: 10))
                .tracking(4)
                .foregroundStyle(BaziTheme.inkMutedSecondary)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10),
                ],
                spacing: 10
            ) {
                ForEach(cards) { card in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(card.title)
                            .font(BaziFont.caption(size: 10))
                            .tracking(2)
                            .foregroundStyle(BaziTheme.inkMutedSecondary)
                        Text(card.value)
                            .font(BaziFont.display(size: 14))
                            .tracking(1)
                            .foregroundStyle(BaziTheme.ink)
                        if !card.explanation.isEmpty {
                            // S3 人话化(2026-09-30):第三行承担"人话层"(两人视角
                            // + 一句结果),字号 10→12 且不截断——lineLimit(2) 会把
                            // 结论腰斩,半句话比没解释更糟
                            Text(card.explanation)
                                .font(BaziFont.caption(size: 12))
                                .foregroundStyle(BaziTheme.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(BaziTheme.hairline)
                            .frame(width: 0.5)
                    }
                }
            }
        }
        .fadeIn()
    }

    /// 评估值 → 简短解释(后端枚举取值集,见 compatibility.py:107-119)。
    /// 未知值留空(UI 不展示,避免编造)。解释文案走 xcstrings
    /// (zh 原句为 key 的 defaultValue;en 已登记)。
    private static func explanation(for value: String) -> String {
        guard let zh = explanations[value] else { return "" }
        return NSLocalizedString(zh, value: zh, comment: "合盘评估枚举解释")
    }

    /// S3 人话化(2026-09-30 BP 评审 R7):第二人称/两人视角 + 一句结果,
    /// 不带吉凶断言;评估值(第二行)保留术语作"专业层",解释承担"人话层"。
    /// zh 为 NSLocalizedString 的 key(en 走 xcstrings 同 key)。
    private static let explanations: [String: String] = [
        // five_elements
        "互补佳": "你们的五行正好补上彼此缺的那部分。",
        "有一定互补": "五行有互补,也有重叠的部分。",
        "互补较弱": "你们的五行重叠较多,相似多于互补。",
        "信息不足": "有一方命局属特殊格局,此项不下结论。",

        // day_master_relation
        "同气": "日主同气,做事方式相近,也容易较劲。",
        "相生": "一方的日主天然滋养另一方。",
        "相克": "一方的日主容易压住另一方,摩擦来得快。",

        // zodiac_match
        "六合": "你们生肖相合,默契来得自然。",
        "三合": "你们生肖成合,节奏容易踩到一起。",
        "六冲": "你们生肖相冲,意见容易正面撞上。",
        "三刑": "你们生肖相刑,相处要更多耐心。",
        "相害": "你们生肖相害,好意容易被误读。",
        "无特殊合冲": "生肖无合无冲,这一项不加分也不扣分。",

        // branch_harmony
        "无冲无刑": "两人四柱对得上,没有明显的冲撞。",
        "一冲一合": "有冲的地方,也有合的地方,拉扯中平稳。",
        "多冲少合": "冲多合少,相处要主动磨合。",
        "多合少冲": "合多冲少,整体合拍,偶有小摩擦。",
        "多刑多害": "刑害偏多,近距离相处消耗较大。",
        "略有冲刑害": "略有冲刑害,大事上多商量就好。",
    ]
}
