import SwiftUI

/// AI 解读区(50-80 字 Medium voice)。
///
/// 子状态独立(决策 §3.1;2026-09-07 起主路径 = 进入页面自动生成):
/// - .idle → 仅离线兜底/达限可达:离线且有次数 → CTA 手动入口;
///   次数耗尽 → 达限卡(自动触发前 VM 会查次数,不发起空调用)
/// - .fetching → 静默推演指示(ProgressView + 「推演中…」,无按钮)
/// - .okFree(text, cached) → 解读文本 + cached 标识
/// - .failed(msg) → 2026-09-24 失败降级拍板:正文位显示按 dayRelation 的
///   排盘引擎确定性文案(引擎产物,AI 失败不影响),底部小注如实标注状态——
///   静默重试在飞 →「AI 解读未生成,重试中」;最终失败 → 原始错误 + Retry。
///   模板永不单独出现(小注常驻),不拿引擎文案冒充 AI 解读。
struct DailyInterpretationSection: View {
    let state: InterpretState
    /// 流日十神关系(后端简体 key,同 HeroYiJiColumns 口径),失败降级模板查表用。
    let dayRelation: String
    /// 一次后台静默重试是否在飞(VM 单一事实源;true 时隐藏 Retry 防双触发)。
    let isSilentRetrying: Bool
    let remainingReads: Int
    let nextReset: Date
    let onGenerate: () -> Void
    let onRetry: () -> Void

    var body: some View {
        // 今日运势 V1「三框全载」:解读入框,正文楷体宽行距;全免费不上「剩余次数」
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.DailyFortune.interpretTitle)
                .font(BaziFont.caption(size: 10))
                .tracking(4)
                .foregroundStyle(BaziTheme.inkMutedSecondary)

            switch state {
            case .idle:
                if remainingReads <= 0 {
                    DailyLimitReachedView(nextReset: nextReset)
                } else {
                    // 自动生成时代 .idle 仅剩离线兜底一条路(联网后手动点)
                    interpretationCTABlock()
                }
            case .fetching:
                // 自动生成(2026-09-07):推演中不再渲染 CTA 按钮,
                // 静默指示即可——按钮暗示「还要点一下」,与免点击语义相悖
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(BaziTheme.inkMuted)
                    Text(L10n.DailyFortune.interpretLoading)
                        .font(BaziFont.caption(size: 12))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            case .okFree(let text, let cached), .okPaid(let text, let cached):
                // 每日运势 v1 全免费(MONETIZATION.md 不在 SKU 列表),后端只调 daily_fortune module,
                // .okPaid 永不触发;合并处理避免重复代码。
                Text(MarkdownSanitizer.rendered(text))
                    .bodySerifText(size: 16)
                    .lineSpacing(9)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .fadeIn()
                if cached {
                    HStack {
                        Image(systemName: "checkmark.seal")
                        Text(L10n.DailyFortune.interpretCached)
                    }
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
                }
            case .lockedPaid:
                // 每日运势 v1 全免费,.lockedPaid 永不触发;保留 case 维护 switch 完整性。
                EmptyView()
            case .failed(let message):
                // 2026-09-24 失败降级拍板:正文位 = 引擎模板文案(与 .okFree 同排版,
                // 正文样式一致才不显得「这屏坏了」),底部小注如实标注状态。
                // 卡片外框保留(维持与 hero 两框左右对齐的 09-07 拍板)。
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: EngineReadingTemplates.text(for: dayRelation))
                        .bodySerifText(size: 16)
                        .lineSpacing(9)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .fadeIn()
                    if isSilentRetrying {
                        // 静默重试在飞:小注 + 微指示器,隐藏 Retry(防双触发)
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(BaziTheme.inkMuted)
                            Text(L10n.DailyFortune.interpretRetrying)
                                .font(BaziFont.caption(size: 12))
                                .tracking(1)
                                .foregroundStyle(BaziTheme.inkMuted)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(message)
                                .font(BaziFont.caption(size: 12))
                                .tracking(1)
                                .foregroundStyle(BaziTheme.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(L10n.DailyFortune.interpretRetry, action: onRetry)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(BaziTheme.ink)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .dailyLimitReached(let nextReset):
                DailyLimitReachedView(nextReset: nextReset)
                // 达上限:**禁用生成按钮、不显示重试**(方案 step 4)
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

private extension DailyInterpretationSection {
    /// .idle(离线兜底)手动 CTA 区:说明文字 + 按钮。
    @ViewBuilder
    func interpretationCTABlock() -> some View {
        VStack(spacing: 12) {
            Text(L10n.DailyFortune.interpretCTA)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)

            PrimaryCTAButton(
                title: L10n.DailyFortune.interpretTitle,
                loadingTitle: L10n.DailyFortune.interpretLoading,
                isLoading: false,
                action: onGenerate
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

// MARK: - 失败降级引擎模板文案(2026-09-24 拍板)

/// AI 解读失败时正文位的确定性参考文案,按流日十神关系查表(引擎产物,
/// 与 AI 无关,失败时照常可得)。key = 后端简体十神(同 HeroYiJiColumns /
/// i18n 决策 7 口径);三语静态表,不进 xcstrings(对齐 HeroYiJiColumns 词表
/// 的既定模式)。查表 miss 记日志 + fallback,不静默(错误显式传播约束)。
internal enum EngineReadingTemplates {
    static let zh: [String: String] = [
        "比肩": "流日与你的日主同根同气,是自立自守的一天。今天适合按自己的节奏推进,把界限立清楚;不必随众而行,更不必卷入无谓的争执。",
        "劫财": "流日的能量与日主明面相竞,劲头足而散。今天适合放开手脚去开拓,但须提防冲动冒进;借贷与分利之事,尤其慢一拍。",
        "食神": "流日的能量向外流淌,灵感与口福俱开。今天适合创造、表达、与老友相见;熬夜与争辩,都留到别的日子。",
        "伤官": "流日的能量锋芒外露,言语自带锋。今天适合说出真想法、拿出新作品;只是进退有度,话慢半拍,锋就不伤人。",
        "偏财": "流日的能量向外飘,机会在外面。今天适合拓展、尝新、让利三分;不孤注一掷,也不贪多嚼不烂。",
        "正财": "流日的能量踏实务本,是积小胜的一天。今天适合守成、记账、种好自己的田;不图短线快利,也不轻易弃约。",
        "七杀": "流日的能量带着压力而来,挑战与魄力并存。今天适合接下难事、当机立断;只是别硬扛到底,对自己也别太狠——对事不对人。",
        "正官": "流日的能量有序有度,是把事情做规矩的一天。今天适合履职尽责、守约复命,把分内之事做扎实;不退缩,也不越级冒进。",
        "偏印": "流日的能量向内收,是静思的一天。今天适合温故知新、独处养神;别把事情想成结,也别固执己见。",
        "正印": "流日的能量滋养护佑,是补养的一天。今天适合学习、纳言、调理身心;不空想,也不拖延。",
    ]

    /// 繁体表:用词对齐 mappingHant 惯例(覆命/賒帳等此处不涉及,机械转写即可)。
    static let hant: [String: String] = [
        "比肩": "流日與你的日主同根同氣,是自立自守的一天。今天適合按自己的節奏推進,把界限立清楚;不必隨眾而行,更不必捲入無謂的爭執。",
        "劫财": "流日的能量與日主明面相競,勁頭足而散。今天適合放開手腳去開拓,但須提防衝動冒進;借貸與分利之事,尤其慢一拍。",
        "食神": "流日的能量向外流淌,靈感與口福俱開。今天適合創造、表達、與老友相見;熬夜與爭辯,都留到別的日子。",
        "伤官": "流日的能量鋒芒外露,言語自帶鋒。今天適合說出真想法、拿出新作品;只是進退有度,話慢半拍,鋒就不傷人。",
        "偏财": "流日的能量向外飄,機會在外面。今天適合拓展、嘗新、讓利三分;不孤注一擲,也不貪多嚼不爛。",
        "正财": "流日的能量踏實務本,是積小勝的一天。今天適合守成、記帳、種好自己的田;不圖短線快利,也不輕易棄約。",
        "七杀": "流日的能量帶著壓力而來,挑戰與魄力並存。今天適合接下難事、當機立斷;只是別硬扛到底,對自己也別太狠——對事不對人。",
        "正官": "流日的能量有序有度,是把事情做規矩的一天。今天適合履職盡責、守約覆命,把分內之事做紮實;不退縮,也不越級冒進。",
        "偏印": "流日的能量向內收,是靜思的一天。今天適合溫故知新、獨處養神;別把事情想成結,也別固執己見。",
        "正印": "流日的能量滋養護佑,是補養的一天。今天適合學習、納言、調理身心;不空想,也不拖延。",
    ]

    static let en: [String: String] = [
        "比肩": "The day shares your day master's element — a day to stand on your own. Move at your own pace, hold your boundaries, and skip the crowd.",
        "劫财": "The day's energy runs bold and competitive. Good for new ground and open moves; just don't rush, and think twice before lending or splitting stakes.",
        "食神": "The day flows outward — ideas and appetite both open. Create, speak, see friends; just don't stay up late or fall into debates.",
        "伤官": "The day sharpens your words. Good for speaking out and showing new work; mind the line, and let words sit a beat before they land.",
        "偏财": "The day's energy drifts outward — opportunity is out there. Explore, try new things, leave room for others; don't bet it all or overreach.",
        "正财": "The day is steady and practical — small gains, well kept. Tend your ground and keep your books; don't chase quick wins or drop promises.",
        "七杀": "The day arrives with pressure — and the nerve to match. Take on the hard thing and make the call; just don't burn yourself out or make enemies along the way.",
        "正官": "The day asks for order and follow-through. Do your part, keep your word, and finish things properly; don't shrink from it, and don't step over the line.",
        "偏印": "The day turns inward — a quiet one for reflection. Review the old, sit with your thoughts, find your own calm; don't overthink it into a knot.",
        "正印": "The day is nourishing — made for restoring. Study, take advice, rest well; don't drift into daydreams or keep dragging your feet.",
    ]

    static func text(for relation: String) -> String {
        let table: [String: String]
        switch AppLanguage.current {
        case .zh: table = zh
        case .zhHant: table = hant
        case .en: table = en
        }
        if let hit = table[relation] { return hit }
        AppLogger.app.warning(
            "op=engineReading.lookupMiss day_relation=\(relation, privacy: .public) -> fallback"
        )
        switch AppLanguage.current {
        case .en: return "Read the day's tone from the Do & Don't lists above, and move within your means."
        case .zhHant: return "今日基調可從上方宜忌一覽讀出,量力而行、順勢而為。"
        case .zh: return "今日基调可从上方宜忌一览读出,量力而行、顺势而为。"
        }
    }
}
