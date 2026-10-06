import SwiftUI

/// AI 解读区(S6 结构化今日洞察,2026-09-30 BP 评审)。
///
/// v4 起后端输出 JSON 五段(headline/work/relationships/energy/reminder),
/// 本区按「今日一句 + 三领域行 + 今日信号 + 收尾提醒」渲染;今日信号
/// (流日五行对喜忌的 ↑↓)是后端确定性规则产物,随 response 透传,0 AI 成本。
///
/// 子状态独立(决策 §3.1;2026-09-07 起主路径 = 进入页面自动生成):
/// - .idle → 仅离线兜底/达限可达:离线且有次数 → CTA 手动入口;
///   次数耗尽 → 达限卡(自动触发前 VM 会查次数,不发起空调用)
/// - .fetching → 静默推演指示(ProgressView + 「推演中…」,无按钮)
/// - .okFree(text, cached) → v4 JSON 解析成功 → 结构化洞察;解析失败 →
///   与 .failed 同款引擎模板降级(错误显式传播:不静默当散文渲染 JSON 裸奔,
///   原始文本进日志 + accessibilityValue)
/// - .offlineLegacy(text) → 离线兜底:快照里的历史解读正文 + 小注(2026-09-28;
///   此前塞 .failed 会被失败降级渲染成引擎模板,「已保留历史解读」名不副实)。
///   v4 起快照存 JSON 五段原文:解析成功走结构化正文,解析失败=v3 散文快照
///   维持原渲染(两代快照共存期,离线不裸奔 JSON)
/// - .failed(msg) → 2026-09-24 失败降级拍板:正文位显示按 dayRelation 的
///   排盘引擎确定性文案(引擎产物,AI 失败不影响),底部小注如实标注状态——
///   2026-09-28 S02 起两态均说清「以上为今日通用参考」:静默重试在飞 →
///   「以上为今日通用参考 · AI 解读重试中」;最终失败 →「AI 解读暂未生成 ·
///   以上为今日通用参考」(原始错误进 accessibilityValue + VM 日志;**无
///   Retry 按钮**——2026-10-06 用户拍板移除,静默重试兜底 + 下拉刷新手动恢复)。
///   模板永不单独出现(小注常驻),不拿引擎文案冒充 AI 解读。
struct DailyInterpretationSection: View {
    let state: InterpretState
    /// 流日十神关系(后端简体 key,同 HeroYiJiColumns 口径),失败降级模板查表用。
    let dayRelation: String
    /// S6 今日信号数据(确定性):流日天干/地支五行。nil(老后端/老快照)→ 信号行隐藏。
    var dayElements: DayElementsDTO? = nil
    /// S6 今日信号:流日五行对喜忌的命中(空表 = 时辰未知/从格,只显五行不标 ↑↓)。
    var daySignal: [DaySignalItemDTO]? = nil
    /// 信号行降级注释(daySignal 为空时的原因,宿主按 hourGate 判;nil = 不显示)。
    var signalNote: String? = nil
    /// 一次后台静默重试是否在飞(VM 单一事实源;true 时小注切「AI 解读重试中」
    /// + 微指示器,false 走最终失败小注。2026-10-06 起 Retry 按钮已移除,
    /// 此参数只剩切小注形态一职)。
    let isSilentRetrying: Bool
    let remainingReads: Int
    let nextReset: Date
    let onGenerate: () -> Void

    var body: some View {
        // 2026-10-01 D5 定稿:去卡片底直接排纸面(页边距 24 与 hero 下间距
        // 由宿主注入);全免费不上「剩余次数」。
        VStack(alignment: .leading, spacing: 12) {
            kicker

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
                //
                // v4:输出是 JSON 五段;解析失败 → 引擎模板降级(同 .failed 形态,
                // 错误显式传播——不静默把半截 JSON 当散文渲染)。
                if let insight = DailyInsight.parse(text) {
                    insightBody(insight)
                    if cached {
                        HStack {
                            Image(systemName: "checkmark.seal")
                            Text(L10n.DailyFortune.interpretCached)
                        }
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                    }
                } else {
                    degradedBody(
                        message: L10n.DailyFortune.insightFormatDegraded,
                        rawText: text
                    )
                }
            case .lockedPaid:
                // 每日运势 v1 全免费,.lockedPaid 永不触发;保留 case 维护 switch 完整性。
                EmptyView()
            case .offlineLegacy(let text, let languageNote):
                // 离线兜底(2026-09-28):正文 = 快照里的历史解读原文(不拿引擎模板
                // 冒充),底部小注如实说明「已保留历史解读,联网后可确认当前 AI 来源」。
                // 无 Retry——离线重试必失败,还会把已保留的正文挤成模板。
                // v4(S6):快照存的是 JSON 五段原文——解析成功走结构化正文;
                // 解析失败且是 JSON 形态 = 畸形 v4 快照(缓存毒化残留,2026-09-30
                // review 修复),引擎模板兜底不裸奔;否则才是 v3 时代散文快照,
                // 维持原渲染(两代快照共存期)。
                VStack(alignment: .leading, spacing: 14) {
                    if let insight = DailyInsight.parse(text) {
                        insightBody(insight)
                    } else if DailyInsight.looksLikeJSON(text) {
                        insightBody(EngineReadingTemplates.insight(for: dayRelation))
                    } else {
                        Text(MarkdownSanitizer.rendered(text))
                            .bodySerifText(size: 16)
                            .lineSpacing(9)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .fadeIn()
                    }
                    if let languageNote {
                        // L6/F7:快照语言 ≠ 生效语言(离线兜底没有更好的选择,
                        // 如实标注显示的是哪个语言版本)
                        Text(languageNote)
                            .font(BaziFont.caption(size: 12))
                            .tracking(1)
                            .foregroundStyle(BaziTheme.inkMuted)
                    }
                    Text(L10n.DailyFortune.interpretOfflineLegacy)
                        .font(BaziFont.caption(size: 12))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onAppear {
                    // 畸形 v4 快照走引擎模板兜底时留痕(对齐 degradedBody 的
                    // onAppear 手法:原始文本只进日志,不进正文)。
                    // 须同时判 parse 失败——合法 v4 快照同样 looksLikeJSON。
                    if DailyInsight.parse(text) == nil,
                       DailyInsight.looksLikeJSON(text) {
                        AppLogger.app.error(
                            "op=dailyInsight.offlineLegacyMalformedJSON raw_prefix=\(String(text.prefix(80)), privacy: .public)"
                        )
                    }
                }
            case .failed(let message):
                degradedBody(message: message, rawText: nil)
            case .dailyLimitReached(let nextReset):
                DailyLimitReachedView(nextReset: nextReset)
                // 达上限:**禁用生成按钮、不显示重试**(方案 step 4)
            }
        }
    }

    /// 区标 kicker(D5 定稿):**全屏唯一字距标签**——EN 全大写 9.5 semibold、
    /// letter-spacing 0.14em(≈1.3pt)、inkMuted;zh/zh-Hant 维持小标 10 + 4pt
    /// 字距(2026-09-28 S04 中文口径不变)。
    private var kicker: some View {
        Text(L10n.DailyFortune.interpretTitle)
            .font(
                AppLanguage.current.isChinese
                    ? BaziFont.caption(size: 10)
                    : .system(size: 9.5, weight: .semibold)
            )
            .textCase(AppLanguage.current.isChinese ? nil : .uppercase)
            .tracking(AppLanguage.current.isChinese ? 4 : 1.3)
            .foregroundStyle(BaziTheme.inkMuted)
    }

    // MARK: - S6 结构化洞察正文(v4 JSON 五段)

    /// 今日一句(标题句)+ 事业/关系/精力三行 + 今日信号(确定性)+ 收尾提醒。
    /// 2026-10-01 D5 定稿:headline serif 17、领域行 92pt 固定标签列 +
    /// hairline 行分隔、signal 行左右分立、reminder EN serif italic;
    /// 与降级态同构(EngineReadingTemplates 同样输出五段),正常/降级不跳形态。
    private func insightBody(_ insight: DailyInsight) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(MarkdownSanitizer.rendered(insight.headline))
                .font(BaziFont.display(size: 17))
                .foregroundStyle(BaziTheme.ink)
                .lineSpacing(7)
                .fixedSize(horizontal: false, vertical: true)
                .fadeIn()

            VStack(alignment: .leading, spacing: 0) {
                domainRow(label: L10n.DailyFortune.insightWork, text: insight.work)
                domainRow(label: L10n.DailyFortune.insightRelationships, text: insight.relationships)
                domainRow(label: L10n.DailyFortune.insightEnergy, text: insight.energy)
            }
            .padding(.top, 11)

            signalRow

            Text(MarkdownSanitizer.rendered(insight.reminder))
                .font(reminderFont)
                .tracking(AppLanguage.current.isChinese ? 1 : 0)
                .foregroundStyle(BaziTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 领域行(D5):92pt 固定标签列(sans medium 12.5 inkMuted,常规大小写
    /// 不拉字距)+ 正文(sans 14 ink;zh 经 BaziFont.body 走楷体「文中楷」),
    /// 行顶 hairline、上下 padding 11。
    /// alignment 必须 .leading(2026-10-01 真机截图修复):hairline Rectangle
    /// 贪宽占满行宽,而 HStack 是固有宽——VStack 默认 .center 会把每行内容
    /// 各自水平居中(实测三行标签起点 28/61/52pt 各不相同,Work 行只因内容
    /// 最宽才看似近齐)。
    private func domainRow(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .frame(width: 92, alignment: .leading)
                Text(MarkdownSanitizer.rendered(text))
                    .font(BaziFont.body(size: 14))
                    .foregroundStyle(BaziTheme.ink)
                    .lineSpacing(6)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 11)
        }
    }

    /// 收尾提醒字体:EN serif italic 13 medium(mockup .reminder 衬线一族);
    /// zh/zh-Hant 维持 sans caption 12(中文楷/宋斜体是伪斜,不取)。
    private var reminderFont: Font {
        AppLanguage.current.isChinese
            ? BaziFont.caption(size: 12)
            : .system(size: 13, weight: .medium, design: .serif).italic()
    }

    /// 今日信号行(确定性,非 AI;D5 定稿:左右分立)——左标签 sans medium
    /// 13 ink,右值 12 semibold,方向着色沿用现有 ↑=墨青 / ↓=朱红口径。
    /// - daySignal 非空:Water ↑ · Wood ↓
    /// - daySignal 空但 dayElements 在:只显五行 + 降级注释(时辰未知/从格)
    /// - dayElements nil(老后端/老快照):整行隐藏
    @ViewBuilder
    private var signalRow: some View {
        if let elements = dayElements {
            VStack(alignment: .leading, spacing: 4) {
                Rectangle()
                    .fill(BaziTheme.hairline)
                    .frame(height: 0.5)
                HStack(spacing: 10) {
                    Text(L10n.DailyFortune.insightSignal)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(BaziTheme.ink)
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        let items = daySignal ?? []
                        if items.isEmpty {
                            // 无方向:只显流日五行(天干/地支去重),不标 ↑↓
                            ForEach(uniqueElements(elements), id: \.self) { elem in
                                Text(BaziTerms.display(elem))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(BaziTheme.ink)
                            }
                        } else {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                let isUp = item.direction == "up"
                                HStack(spacing: 2) {
                                    Text(BaziTerms.display(item.element))
                                    Text(verbatim: isUp ? "↑" : "↓")
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isUp ? BaziTheme.jade : BaziTheme.cinnabar)
                                // a11y(先例 = XijiCard chip):裸 ↑↓ 对 VoiceOver
                                // 只是"上/下箭头"字符,合成"喜用 火 / 忌神 木"语义朗读
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(
                                    "\(isUp ? L10n.DeepChart.xijiFavorableA11y : L10n.DeepChart.xijiUnfavorableA11y) \(BaziTerms.display(item.element))"
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 2)
                if let note = signalNote, (daySignal ?? []).isEmpty {
                    Text(note)
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
            }
        }
    }

    private func uniqueElements(_ elements: DayElementsDTO) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for elem in [elements.stemElement, elements.branchElement] where !seen.contains(elem) {
            seen.insert(elem)
            out.append(elem)
        }
        return out
    }

    // MARK: - 降级正文(.failed / v4 解析失败共用)

    /// 引擎模板五段(按 dayRelation 查表,与 insightBody 同构)+ 状态小注。
    /// rawText 非 nil(v4 解析失败)时进日志 + message 进 accessibilityValue,不进正文;
    /// 日志挂 onAppear(每次降级视图插入打一次)而非 body——body 重算会被
    /// TimelineView/状态变化反复触发,同一条 error 放大成日志噪音。
    private func degradedBody(message: String, rawText: String?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            insightBody(EngineReadingTemplates.insight(for: dayRelation))
            if isSilentRetrying {
                // 静默重试在飞:小注切「重试中」+ 微指示器
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
                // 2026-09-28 S02:小注说清「上面是通用参考」,不再直接露
                // `.failed(message)` 的原始错误标题(EN「Reading failed」
                // 与正文并存像自相矛盾);原错误进 accessibilityValue +
                // VM 日志(2026-09-29 review 修正:hint 受 VoiceOver
                // 「Speak Hints」开关控制且语义属交互元素,静态文本
                // 改 value 无条件朗读)。可折两行。
                // 2026-10-06 用户拍板移除 Retry 按钮:静默重试已兜底自动恢复,
                // 手动恢复路径 = 下拉刷新;quota 耗尽态下按钮重试必再失败,
                // 只会教用户反复点(错误显式传播不回退——小注 + a11y value +
                // VM 日志三通道保留)。
                Text(L10n.DailyFortune.interpretFallbackNote)
                    .font(BaziFont.caption(size: 12))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityValue(Text(message))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if let raw = rawText {
                AppLogger.app.error(
                    "op=dailyInsight.parseFailed raw_prefix=\(String(raw.prefix(80)), privacy: .public)"
                )
            }
        }
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

// MARK: - v4 结构化今日洞察模型(S6)

/// daily_fortune v4 输出契约:{"headline","work","relationships","energy","reminder"}。
/// 解析规则:剥 ```json 围栏(prompt 已禁但防御,对齐 ChapterContent 口径)→
/// JSON 对象五键全非空字符串;任一缺失/为空/非 JSON → nil(调用方走降级,不静默)。
struct DailyInsight: Equatable {
    let headline: String
    let work: String
    let relationships: String
    let energy: String
    let reminder: String

    static func parse(_ text: String) -> DailyInsight? {
        guard let value = OrderedJSONParser.parse(
            OrderedJSONParser.stripCodeFences(text)
        ), case .object(let pairs) = value else { return nil }
        var dict: [String: String] = [:]
        for (key, v) in pairs {
            guard case .string(let s) = v else { continue }
            dict[key] = s
        }
        guard let headline = dict["headline"], !headline.isEmpty,
              let work = dict["work"], !work.isEmpty,
              let relationships = dict["relationships"], !relationships.isEmpty,
              let energy = dict["energy"], !energy.isEmpty,
              let reminder = dict["reminder"], !reminder.isEmpty
        else { return nil }
        return DailyInsight(
            headline: headline, work: work,
            relationships: relationships, energy: energy, reminder: reminder
        )
    }

    /// 文本是否「JSON 形态」(剥围栏后首非空白字符为 `{`)。
    /// offlineLegacy 兜底用:区分 v3 散文快照(原样渲染)与 v4 畸形 JSON
    /// (引擎模板兜底,不裸奔;2026-09-30 review 缓存毒化修复)。
    /// 只看形态不看契约——五键校验归 parse,两者组合决定三分支渲染。
    static func looksLikeJSON(_ text: String) -> Bool {
        OrderedJSONParser.stripCodeFences(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("{")
    }
}

// MARK: - 失败降级引擎模板文案(2026-09-24 拍板;S6 起五段化)

/// AI 解读失败时正文位的确定性参考文案,按流日十神关系查表(引擎产物,
/// 与 AI 无关,失败时照常可得)。S6(2026-09-30)起与 v4 正常态**同构**:
/// 同样输出五段(headline + 三领域 + reminder),降级不跳形态。
/// key = 后端简体十神(同 HeroYiJiColumns / i18n 决策 7 口径);三语静态表,
/// 不进 xcstrings(对齐 HeroYiJiColumns 词表的既定模式)。查表 miss 记日志 +
/// fallback,不静默(错误显式传播约束)。
internal enum EngineReadingTemplates {
    static let zh: [String: DailyInsight] = [
        "比肩": .init(
            headline: "同根同气,自立自守的一天",
            work: "按自己的节奏推进,把界限立清楚。",
            relationships: "不随众而行,避开无谓的争执。",
            energy: "精力平稳,靠自己回血最有效。",
            reminder: "量力而行,顺势而为。"),
        "劫财": .init(
            headline: "劲头足而散的一天",
            work: "放开手脚去开拓,但提防冲动冒进。",
            relationships: "借贷与分利之事,尤其慢一拍。",
            energy: "劲头来得快去得快,留半分余力。",
            reminder: "量力而行,顺势而为。"),
        "食神": .init(
            headline: "灵感与口福俱开的一天",
            work: "适合创造、表达、推进感兴趣的事。",
            relationships: "与老友相见,聊天比争论有收获。",
            energy: "熬夜与争辩都省着点用。",
            reminder: "量力而行,顺势而为。"),
        "伤官": .init(
            headline: "锋芒外露,才华与顶撞并存的一天",
            work: "说出真想法,拿出新作品。",
            relationships: "话慢半拍,锋就不伤人。",
            energy: "说话耗气,说完记得收神。",
            reminder: "量力而行,顺势而为。"),
        "偏财": .init(
            headline: "机会在外面的一天",
            work: "拓展、尝新、让利三分。",
            relationships: "合作多谈规则,少讲义气。",
            energy: "机会多诱惑也多,别贪多。",
            reminder: "量力而行,顺势而为。"),
        "正财": .init(
            headline: "踏实务本,积小胜的一天",
            work: "守成、记账、种好自己的田。",
            relationships: "守约复命,小事上也别失信。",
            energy: "节奏平缓,按部就班不累。",
            reminder: "量力而行,顺势而为。"),
        "七杀": .init(
            headline: "压力与魄力并存的一天",
            work: "接下难事,当机立断。",
            relationships: "对事不对人,别硬扛到底。",
            energy: "紧绷是常态,给自己留泄压口。",
            reminder: "量力而行,顺势而为。"),
        "正官": .init(
            headline: "有序有度,做规矩的一天",
            work: "履职尽责,把分内之事做扎实。",
            relationships: "守约复命,不越级不冒进。",
            energy: "秩序感回血,收尾比开工舒服。",
            reminder: "量力而行,顺势而为。"),
        "偏印": .init(
            headline: "向内收,静思的一天",
            work: "温故知新,梳理比开拓有效。",
            relationships: "独处养神,少下结论。",
            energy: "想多耗神,动手比空想回血。",
            reminder: "量力而行,顺势而为。"),
        "正印": .init(
            headline: "滋养护佑,补养的一天",
            work: "学习、纳言、定计划。",
            relationships: "多听少辩,长辈的话有养分。",
            energy: "调理身心,早睡是上策。",
            reminder: "量力而行,顺势而为。"),
    ]

    /// 繁体表:用词对齐 mappingHant 惯例,机械转写。
    static let hant: [String: DailyInsight] = [
        "比肩": .init(
            headline: "同根同氣,自立自守的一天",
            work: "按自己的節奏推進,把界限立清楚。",
            relationships: "不隨眾而行,避開無謂的爭執。",
            energy: "精力平穩,靠自己回血最有效。",
            reminder: "量力而行,順勢而為。"),
        "劫财": .init(
            headline: "勁頭足而散的一天",
            work: "放開手腳去開拓,但提防衝動冒進。",
            relationships: "借貸與分利之事,尤其慢一拍。",
            energy: "勁頭來得快去得快,留半分餘力。",
            reminder: "量力而行,順勢而為。"),
        "食神": .init(
            headline: "靈感與口福俱開的一天",
            work: "適合創造、表達、推進感興趣的事。",
            relationships: "與老友相見,聊天比爭論有收穫。",
            energy: "熬夜與爭辯都省著點用。",
            reminder: "量力而行,順勢而為。"),
        "伤官": .init(
            headline: "鋒芒外露,才華與頂撞並存的一天",
            work: "說出真想法,拿出新作品。",
            relationships: "話慢半拍,鋒就不傷人。",
            energy: "說話耗氣,說完記得收神。",
            reminder: "量力而行,順勢而為。"),
        "偏财": .init(
            headline: "機會在外面的一天",
            work: "拓展、嘗新、讓利三分。",
            relationships: "合作多談規則,少講義氣。",
            energy: "機會多誘惑也多,別貪多。",
            reminder: "量力而行,順勢而為。"),
        "正财": .init(
            headline: "踏實務本,積小勝的一天",
            work: "守成、記帳,種好自己的田。",
            relationships: "守約覆命,小事上也別失信。",
            energy: "節奏平緩,按部就班不累。",
            reminder: "量力而行,順勢而為。"),
        "七杀": .init(
            headline: "壓力與魄力並存的一天",
            work: "接下難事,當機立斷。",
            relationships: "對事不對人,別硬扛到底。",
            energy: "緊繃是常態,給自己留洩壓口。",
            reminder: "量力而行,順勢而為。"),
        "正官": .init(
            headline: "有序有度,做規矩的一天",
            work: "履職盡責,把分內之事做紮實。",
            relationships: "守約覆命,不越級不冒進。",
            energy: "秩序感回血,收尾比開工舒服。",
            reminder: "量力而行,順勢而為。"),
        "偏印": .init(
            headline: "向內收,靜思的一天",
            work: "溫故知新,梳理比開拓有效。",
            relationships: "獨處養神,少下結論。",
            energy: "想多耗神,動手比空想回血。",
            reminder: "量力而行,順勢而為。"),
        "正印": .init(
            headline: "滋養護佑,補養的一天",
            work: "學習、納言、定計劃。",
            relationships: "多聽少辯,長輩的話有養分。",
            energy: "調理身心,早睡是上策。",
            reminder: "量力而行,順勢而為。"),
    ]

    static let en: [String: DailyInsight] = [
        "比肩": .init(
            headline: "A day on your own ground",
            work: "Move at your own pace and hold your boundaries.",
            relationships: "Skip the crowd; skip pointless disputes.",
            energy: "Steady energy — you recharge best alone.",
            reminder: "Move within your means."),
        "劫财": .init(
            headline: "Bold, scattered energy",
            work: "Open new ground, but don't rush in.",
            relationships: "Slow down on lending and splitting stakes.",
            energy: "Comes fast, drains fast — keep a reserve.",
            reminder: "Move within your means."),
        "食神": .init(
            headline: "Ideas and appetite open",
            work: "Create, speak, push what interests you.",
            relationships: "See old friends; talk beats debate.",
            energy: "Skip the late night and the arguments.",
            reminder: "Move within your means."),
        "伤官": .init(
            headline: "Sharp words, sharp talent",
            work: "Say the real thing; show new work.",
            relationships: "Let words sit a beat before they land.",
            energy: "Speaking drains — recharge after.",
            reminder: "Move within your means."),
        "偏财": .init(
            headline: "Opportunity is outside today",
            work: "Explore, try new things, give margin.",
            relationships: "Terms over favors in deals.",
            energy: "Many chances, many lures — don't overreach.",
            reminder: "Move within your means."),
        "正财": .init(
            headline: "Steady and practical — small gains",
            work: "Tend your ground; keep your books.",
            relationships: "Keep small promises too.",
            energy: "Even pace; routine restores.",
            reminder: "Move within your means."),
        "七杀": .init(
            headline: "Pressure — and the nerve to match",
            work: "Take the hard thing; decide fast.",
            relationships: "Hard on the task, easy on the person.",
            energy: "Tension runs high; leave a release valve.",
            reminder: "Move within your means."),
        "正官": .init(
            headline: "A day for order and follow-through",
            work: "Do your part; finish things properly.",
            relationships: "Keep your word; don't overstep.",
            energy: "Order restores you — close loops.",
            reminder: "Move within your means."),
        "偏印": .init(
            headline: "Turned inward — a quiet day",
            work: "Review and sort beats starting new.",
            relationships: "Less advice-giving, fewer verdicts.",
            energy: "Overthinking drains; doing restores.",
            reminder: "Move within your means."),
        "正印": .init(
            headline: "Nourishing — made for restoring",
            work: "Study, take advice, set plans.",
            relationships: "Listen more than you argue.",
            energy: "Rest well; sleep early tonight.",
            reminder: "Move within your means."),
    ]

    /// 兜底(查表 miss):通用五段,不冒充十神特化文案。
    static func fallbackInsight() -> DailyInsight {
        fallbackInsight(for: AppLanguage.current)
    }

    /// 显式语言版(D4 EN 零 CJK 扫描测试用,不依赖设备语言)。
    static func fallbackInsight(for language: AppLanguage) -> DailyInsight {
        switch language {
        case .en:
            return DailyInsight(
                headline: "Read the day from the lists above",
                work: "Pick what matters; let the rest wait.",
                relationships: "Keep words easy; friction costs twice.",
                energy: "Move within your means today.",
                reminder: "For reference only.")
        case .zhHant:
            return DailyInsight(
                headline: "從上方宜忌一覽讀出今日基調",
                work: "先做要緊的,其餘可以等。",
                relationships: "話留三分,摩擦就少一半。",
                energy: "今天按自己的節奏來。",
                reminder: "解讀僅供參照。")
        case .zh:
            return DailyInsight(
                headline: "从上方宜忌一览读出今日基调",
                work: "先做要紧的,其余可以等。",
                relationships: "话留三分,摩擦就少一半。",
                energy: "今天按自己的节奏来。",
                reminder: "解读仅供参照。")
        }
    }

    static func insight(for relation: String) -> DailyInsight {
        let table: [String: DailyInsight]
        switch AppLanguage.current {
        case .zh: table = zh
        case .zhHant: table = hant
        case .en: table = en
        }
        if let hit = table[relation] { return hit }
        AppLogger.app.warning(
            "op=engineReading.lookupMiss day_relation=\(relation, privacy: .public) -> fallback"
        )
        return fallbackInsight()
    }
}
