import SwiftUI

/// 4 项定性评估的 2×2 网格(水墨孤本 H3:hairline 网格,无卡片底,参考 hepan-h3-detail.html)。
///
/// 每格:标题(淡灰小标)+ 点名行(确定性干支/五行事实,BP #2 2026-10-01;
/// 派生不出时回落评估枚举值)+ 一行简短解释。日主关系卡是例外(2026-10-07
/// 去重):方向短语归双盘表中轴独占,此卡只显枚举术语 + 解释。
/// **不给数字分、不引入百分比**(定性不给分决策不变)。
struct AssessmentCardGrid: View {
    let assessment: QualitativeAssessmentDTO
    /// 确定性「点名干支」详情(nil = 老盘字段不足,全部回落枚举值)。
    var detail: CompatibilityRelationDetail? = nil

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
                value: detail?.fiveElements
                    ?? BaziTerms.display(assessment.fiveElements),
                explanation: Self.explanation(for: assessment.fiveElements)
            ),
            Card(
                title: String(localized: "日主关系"),
                // 2026-10-07 去重:方向点名短语归双盘表中轴独占(「日主 甲木生丁火」),
                // 此卡回落枚举术语 + 人话解释——一屏不说两遍
                value: BaziTerms.display(assessment.dayMasterRelation),
                explanation: Self.explanation(for: assessment.dayMasterRelation)
            ),
            Card(
                title: String(localized: "生肖匹配"),
                value: detail?.zodiac
                    ?? BaziTerms.display(assessment.zodiacMatch),
                explanation: Self.explanation(for: assessment.zodiacMatch)
            ),
            Card(
                title: String(localized: "地支合冲"),
                value: detail?.branch
                    ?? BaziTerms.display(assessment.branchHarmony),
                explanation: Self.explanation(for: assessment.branchHarmony)
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("合拍定性 · 无评分")
                .font(BaziFont.caption(size: 10))
                .tracking(1.5)
                .foregroundStyle(BaziTheme.inkMutedSecondary)

            LazyVGrid(
                columns: [
                    // 行内 .top 对齐(2026-10-07):GridItem 默认 .center,左右格
                    // 高度不一时(生肖 1 行 vs 地支点名 3 行)整行错位
                    GridItem(.flexible(), spacing: 10, alignment: .top),
                    GridItem(.flexible(), spacing: 10, alignment: .top),
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

            // 刑害提示行(BP #10,2026-10-01):确定性派生的具体刑/害对 + 一句
            // 静态相处建议(不让 LLM 写;文案映射同 explanation 先例)
            if let pairs = detail?.frictionPairs, !pairs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(height: 0.5)
                    Text(Self.frictionNote(branchHarmony: assessment.branchHarmony, pairs: pairs))
                    .font(BaziFont.caption(size: 12))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                }
            }
        }
        .fadeIn()
    }

    /// 刑害提示行文案(internal 供测试)。按合冲标签分两档(2026-10-07):
    /// 「多刑多害」标签下若沿用「习惯与小事」轻语气,会与同屏卡解释
    /// 「刑害偏多,近距离相处消耗较大」打架——判定序修复(backend 89c3489,
    /// 合不得掩盖刑害)后该标签才真正可达,本行写于其不可达时(2026-10-01
    /// BP #10);其余标签(略有冲刑害 / 多合少冲带零星刑害)卡解释本就轻
    /// 语气,保留原句。
    static func frictionNote(branchHarmony: String, pairs: [String]) -> String {
        let format: String
        if branchHarmony == "多刑多害" {
            format = String(localized: "两人地支见刑害(%1$@):相处消耗偏大,有摩擦要早点说开,别积压。")
        } else {
            format = String(localized: "两人地支见刑害(%1$@):摩擦多在习惯与小事上,早点说开。")
        }
        return String(format: format, pairs.joined(separator: "、"))
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
        // five_elements(2026-10-07 口径标注:第二行点名是**盘面字数**,本行结论
        // 是**喜忌交集**——两套口径,不标来源会被读成因果)
        "互补佳": "从喜忌来看,你们的五行正好补上彼此缺的那部分。",
        "有一定互补": "从喜忌来看,五行有互补,也有重叠的部分。",
        "互补较弱": "从喜忌来看,你们的五行重叠较多,相似多于互补。",
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
