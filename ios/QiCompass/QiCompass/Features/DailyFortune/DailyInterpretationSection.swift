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
                        // v3 散文快照:字号随 2026-10-25 字号梯度对齐 zh 族正常态
                        // 正文 17(EN 离线散文快照维持既有字号差,罕见路径,待走查)
                        Text(MarkdownSanitizer.rendered(text))
                            .bodySerifText(size: 17)
                            .lineSpacing(5)
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
            case .dailyLimitReached(let nextReset, let serverPool):
                DailyLimitReachedView(nextReset: nextReset, suggestsLogin: serverPool)
                // 达上限:**禁用生成按钮、不显示重试**(方案 step 4)
            case .contextTokenExpired:
                // 凭证失效(2026-10-08):403 重试无意义,「重新排盘」出口
                ContextTokenExpiredView()
            }
        }
    }

    /// 区标 kicker(**2026-10-25 字号梯度**:并入统一小标——sans 13 medium
    /// tracking 1.5、inkMuted,与领域行/信号行/宜忌表头同一种;原 zh 10+4pt
    /// 字距小标与 EN 9.5 semibold 双口径退役,EN 仅保留全大写惯例。
    /// 修订 D5「全屏唯一字距标签」与 2026-09-28 S04 中文口径)。
    private var kicker: some View {
        Text(L10n.DailyFortune.interpretTitle)
            .font(.system(size: 13, weight: .medium))
            .textCase(AppLanguage.current.isChinese ? nil : .uppercase)
            .tracking(1.5)
            .foregroundStyle(BaziTheme.inkMuted)
    }

    // MARK: - S6 结构化洞察正文(v4 JSON 五段)

    /// 今日一句(标题句)+ 事业/关系/精力三行 + 今日信号(确定性)+ 收尾提醒。
    /// 2026-10-01 D5 定稿:headline serif 17(2026-10-18 S3 改 19,**2026-10-25
    /// 字号梯度改 24**——全页大字第二处,仅次于日期 72;zh 族 24,EN 19 待
    /// 走查)、领域行固定标签列(宽按语言 58/92,2026-10-25 随标签 13pt 放宽,
    /// 原 52/92)+ hairline 行分隔;
    /// **signal 行 2026-10-18 S2
    /// 修订 D5「左右分立」**:改与领域行同构(标签列 + 左对齐值),三行与
    /// 信号行同列对齐;reminder EN serif italic;
    /// 与降级态同构(EngineReadingTemplates 同样输出五段),正常/降级不跳形态。
    private func insightBody(_ insight: DailyInsight) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.headlineText(insight.headline))
                .font(BaziFont.display(size: AppLanguage.current.isChinese ? 24 : 19))
                .foregroundStyle(BaziTheme.ink)
                .lineSpacing(AppLanguage.current.isChinese ? 6 : 7)
                .fixedSize(horizontal: false, vertical: true)
                .fadeIn()

            VStack(alignment: .leading, spacing: 0) {
                domainRow(label: L10n.DailyFortune.insightWork, text: insight.work)
                domainRow(label: L10n.DailyFortune.insightRelationships, text: insight.relationships)
                domainRow(label: L10n.DailyFortune.insightEnergy, text: insight.energy)
            }
            .padding(.top, 16)

            signalRow

            // 收尾句(2026-10-18 S3 评审:整页唯一可带走的一句,原 caption
            // 小灰字被埋在底部)——短墨横 + 宋体大字,作为整页的收尾。
            // **2026-10-25 字号梯度:居中改左对齐**——20pt 中文十余字近占满
            // 行时居中不可辨,读作比正文多缩进一截(外评 #3「结语看起来歪了」);
            // 改与正文同左缘,墨横随左,EN italic 同步。
            // 位置不动仍在信号行之后(不挪顶部、不做「签」,10-15 刚删今日一签)。
            VStack(alignment: .leading, spacing: 14) {
                Rectangle()
                    .fill(BaziTheme.ink.opacity(0.35))
                    .frame(width: 16, height: 1.5)
                Text(MarkdownSanitizer.rendered(insight.reminder))
                    .font(reminderFont)
                    .foregroundStyle(BaziTheme.ink)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 标签列宽(2026-10-25 字号梯度):中文 52→58——统一小标升 13pt +
    /// tracking 1.5 后 4 字「今日信号/今日信號」在 52pt 会触发 ~0.9 缩放
    /// (SwiftUI 路径是 lineLimit(1)+minimumScaleFactor 缩放而非换行;
    /// HTML 对比稿无 lineLimit 才表现为换行,不迁移),故放宽到 58;
    /// EN 维持 92(原按 "Relationships" 定的宽,"Today's signal" 同档)。
    /// 配 lineLimit(1) + minimumScaleFactor(0.85) 缩放兜底不变。
    private var labelColumnWidth: CGFloat {
        AppLanguage.current.isChinese ? 58 : 92
    }

    /// 领域行(D5,2026-10-18 S2 修订;**2026-10-25 字号梯度**):固定标签列
    /// 宽按语言 58/92;标签并入统一小标 sans 13 medium inkMuted,tracking 1.5
    /// 仅 zh 族(EN 无字距防 92pt 列宽截断,见行内注释;原 12.5 无字距——
    /// 外评「粗黑小标签贴细宋体旁生硬」,四类标签归一);
    /// 正文 zh 族 17(原 14;行高 ≈1.65)EN 14 不动待走查;行顶 hairline、
    /// 上下 padding 13(S3.2 纵向节奏)不变;今日信号行同步。
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
                    .font(.system(size: 13, weight: .medium))
                    // tracking 1.5 仅 zh 族:EN "Today's signal" 13pt+tracking1.5
                    // ≈109pt,92pt 列宽 ÷109 < 0.85 缩放地板 → 截断;EN 13pt
                    // 无字距 ≈84-90pt 100% 装下(2026-10-25 字号梯度,EN 走查后再定)
                    .tracking(AppLanguage.current.isChinese ? 1.5 : 0)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: labelColumnWidth, alignment: .leading)
                Text(MarkdownSanitizer.rendered(text))
                    .font(BaziFont.body(size: AppLanguage.current.isChinese ? 17 : 14))
                    .foregroundStyle(BaziTheme.ink)
                    .lineSpacing(AppLanguage.current.isChinese ? 5 : 6)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 13)
        }
    }

    /// 收尾句字体(2026-10-18 S3 提升):zh/zh-Hant 宋体 20(整页收尾大字,
    /// 原 caption 12 小灰字);EN serif italic 17 medium(衬线一族,原 13)。
    /// 不加 tracking(中文大字疏排靠 lineSpacing,不靠字距)。
    private var reminderFont: Font {
        AppLanguage.current.isChinese
            ? BaziFont.display(size: 20)
            : .system(size: 17, weight: .medium, design: .serif).italic()
    }

    /// 今日信号行(确定性,非 AI)。**2026-10-18 S2 修订 D5「左右分立」**:
    /// 改与 domainRow 完全同构——行顶 hairline、上下 padding 13(S3.2 同步
    /// domainRow)、标签列(labelColumnWidth,统一小标 13 medium inkMuted
    /// tracking 1.5 仅 zh 族,2026-10-25 字号梯度随 domainRow 同步,原 12.5)+
    /// 值**左对齐**紧随标签列,
    /// 事业/关系/精力三行与信号行同列对齐;方向着色沿用 ↑=墨青 / ↓=朱红。
    /// - daySignal 非空:Water ↑ · Wood ↓
    /// - daySignal 空但 dayElements 在:只显五行 + 降级注释(时辰未知/从格,
    ///   注释左缘与正文列对齐 = labelColumnWidth + 行距 10)
    /// - dayElements nil(老后端/老快照):整行隐藏
    @ViewBuilder
    private var signalRow: some View {
        if let elements = dayElements {
            VStack(alignment: .leading, spacing: 4) {
                Rectangle()
                    .fill(BaziTheme.hairline)
                    .frame(height: 0.5)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(L10n.DailyFortune.insightSignal)
                        .font(.system(size: 13, weight: .medium))
                        // tracking 1.5 仅 zh 族(EN 列宽预算,同 domainRow 标签注释)
                        .tracking(AppLanguage.current.isChinese ? 1.5 : 0)
                        .foregroundStyle(BaziTheme.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: labelColumnWidth, alignment: .leading)
                    HStack(spacing: 8) {
                        let items = daySignal ?? []
                        if items.isEmpty {
                            // 无方向:只显流日五行(天干/地支去重),不标 ↑↓
                            ForEach(uniqueElements(elements), id: \.self) { elem in
                                Text(BaziTerms.display(elem))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(BaziTheme.ink)
                            }
                        } else {
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                let isUp = item.direction == "up"
                                HStack(spacing: 2) {
                                    Text(BaziTerms.display(item.element))
                                    Text(verbatim: isUp ? "↑" : "↓")
                                }
                                .font(.system(size: 13, weight: .semibold))
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
                .padding(.vertical, 13)
                if let note = signalNote, (daySignal ?? []).isEmpty {
                    Text(note)
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                        .padding(.leading, labelColumnWidth + 10)
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

    /// v6 headline 两短句渲染:先按换行拆行、逐行过 MarkdownSanitizer,再用
    /// 未解析的 AttributedString("\n") 拼回——`AttributedString(markdown:)`
    /// 按 CommonMark soft-break 语义把 `\n` 折叠成空格(实测:两短句会静默
    /// 并成一行且中间多一个半角空格),v6 的两行主句在渲染层必须自保。
    /// v5 老缓存单句无换行,拆分退化为原路径,行为逐字不变。同 M0 v11
    /// `leadParagraphs` 的「渲染层拆段」先例(那边逐段独立 Text;这里两短句
    /// 属同一主句,保持单个 Text 共享 lineSpacing)。
    /// internal:回归锁在 DailyFortuneFailureFallbackTests(换行存活断言)。
    static func headlineText(_ headline: String) -> AttributedString {
        let lines = headline
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
        guard !lines.isEmpty else { return MarkdownSanitizer.rendered(headline) }
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += MarkdownSanitizer.rendered(line)
        }
        return result
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
/// v6(2026-10-25)新增**可选**第六键 "ask_suggestions"(问事候选问题,\n 分隔)
/// 与 headline 的两短句 \n 分隔——五键契约不变(老 v5 缓存照常解析),
/// ask_suggestions 缺键/空 → nil,调用方回落 `EngineReadingTemplates.suggestions`。
/// 解析规则:剥 ```json 围栏(prompt 已禁但防御,对齐 ChapterContent 口径)→
/// JSON 对象五键全非空字符串;任一缺失/为空/非 JSON → nil(调用方走降级,不静默)。
struct DailyInsight: Equatable {
    let headline: String
    let work: String
    let relationships: String
    let energy: String
    let reminder: String
    /// v6 起 AI 搭车输出的「问事」候选问题(已按换行拆好、去空白行;模型
    /// 约定三条,条数不设上限——有几条收几条);
    /// v5 老缓存/降级模板无此键 → nil。`var ... = nil` 保住 memberwise 默认值,
    /// EngineReadingTemplates 既有 .init 五参构造零改动(neirong 批次教训:
    /// optional let 无 memberwise 默认会连坐改 30 处构造)。
    var askSuggestions: [String]? = nil

    static func parse(_ text: String) -> DailyInsight? {
        guard let value = OrderedJSONParser.parse(
            OrderedJSONParser.stripCodeFences(text)
        ), case .object(let pairs) = value else { return nil }
        var dict: [String: String] = [:]
        var suggestionsFromArray: [String]? = nil
        for (key, v) in pairs {
            switch v {
            case .string(let s):
                dict[key] = s
            case .array(let values):
                // 模型偶发把 ask_suggestions 写成字符串数组(prompt 要求 \n
                // 连接的单字符串,「三条问题」天然诱导数组)——照收,拼回
                // 换行分隔与字符串形态同路;其余键的数组值维持忽略(五键
                // 契约仍由下方 guard 把关,不因数组形态放松)。
                if key == "ask_suggestions" {
                    let items = values.compactMap {
                        if case .string(let s) = $0 { return s } else { return nil }
                    }
                    if !items.isEmpty { suggestionsFromArray = items }
                }
            default:
                break
            }
        }
        guard let headline = dict["headline"], !headline.isEmpty,
              let work = dict["work"], !work.isEmpty,
              let relationships = dict["relationships"], !relationships.isEmpty,
              let energy = dict["energy"], !energy.isEmpty,
              let reminder = dict["reminder"], !reminder.isEmpty
        else { return nil }
        var insight = DailyInsight(
            headline: Self.normalizeEscapedNewlines(headline), work: work,
            relationships: relationships, energy: energy, reminder: reminder
        )
        if let raw = dict["ask_suggestions"] ?? suggestionsFromArray?.joined(separator: "\n") {
            // 宽容拆分:键在但值空/全空白 → 保持 nil(UI 回落确定性候选);
            // 1-2 条也照收,不倒扣(有多少显示多少,不假装失败)。
            let items = Self.normalizeEscapedNewlines(raw)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !items.isEmpty { insight.askSuggestions = items }
        }
        return insight
    }

    /// 字面 `\n`(反斜杠+n 两字符)→ 真换行。v6 模板要求模型把换行写成 JSON
    /// 转义;模型偶发多转一层时值里会留字面 `\n` 两字符,渲染会显出「\n」
    /// ——在这里归一(m0 v11 同款风险的客户端纵深,非静默吞错:形状修复,
    /// 内容不丢)。headline 与 ask_suggestions 共用。
    private static func normalizeEscapedNewlines(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
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
    /// 兜底态同样带问事候选(通用三条,不冒充十神特化)。
    static func fallbackInsight(for language: AppLanguage) -> DailyInsight {
        switch language {
        case .en:
            var insight = DailyInsight(
                headline: "Read the day from the lists above",
                work: "Pick what matters; let the rest wait.",
                relationships: "Keep words easy; friction costs twice.",
                energy: "Move within your means today.",
                reminder: "For reference only.")
            insight.askSuggestions = fallbackSuggestions(for: language)
            return insight
        case .zhHant:
            var insight = DailyInsight(
                headline: "從上方宜忌一覽讀出今日基調",
                work: "先做要緊的,其餘可以等。",
                relationships: "話留三分,摩擦就少一半。",
                energy: "今天按自己的節奏來。",
                reminder: "解讀僅供參照。")
            insight.askSuggestions = fallbackSuggestions(for: language)
            return insight
        case .zh:
            var insight = DailyInsight(
                headline: "从上方宜忌一览读出今日基调",
                work: "先做要紧的,其余可以等。",
                relationships: "话留三分,摩擦就少一半。",
                energy: "今天按自己的节奏来。",
                reminder: "解读仅供参照。")
            insight.askSuggestions = fallbackSuggestions(for: language)
            return insight
        }
    }

    static func insight(for relation: String) -> DailyInsight {
        let table: [String: DailyInsight]
        switch AppLanguage.current {
        case .zh: table = zh
        case .zhHant: table = hant
        case .en: table = en
        }
        if var hit = table[relation] {
            // 降级态也带问事候选(v6 起 AI 侧搭车 ask_suggestions;降级与
            // 正常态不跳形态——AI 缺的由确定性表补,角度对齐宜忌词条表)。
            hit.askSuggestions = suggestions(for: relation)
            return hit
        }
        AppLogger.app.warning(
            "op=engineReading.lookupMiss day_relation=\(relation, privacy: .public) -> fallback"
        )
        return fallbackInsight()
    }

    // MARK: 问事候选问题(2026-10-25 问事窗 S2;v6 AI 缺键/降级态的确定性回落)

    /// 三条候选问题的确定性回落表:角度对齐 `HeroYiJiColumns` 宜忌词条
    /// (宜向一件 / 忌向一件 / 关系向一件),口吻 = 用户自己想问的话,
    /// 直接可点发。键 = 后端简体十神(同上表);查 miss 走
    /// `fallbackSuggestions` + 日志(不静默)。EN 条目零 CJK(D4 扫描同源约束)。
    static let suggestionsZh: [String: [String]] = [
        "比肩": ["今天适合自己单干吗？", "有争执要避一避吗？", "和同伴分利该注意什么？"],
        "劫财": ["今天适合带头开拓吗？", "借钱给人稳当吗？", "今天容易冲动花钱吗？"],
        "食神": ["今天适合创作表达吗？", "和老友聚一聚好吗？", "今天熬夜行吗？"],
        "伤官": ["今天适合把想法说出来吗？", "说话容易冲撞人吗？", "今天能拿出新东西吗？"],
        "偏财": ["今天适合拓展新客户吗？", "有便宜该不该占？", "今天投资稳当吗？"],
        "正财": ["今天适合按部就班做事吗？", "记账理一理好吗？", "今天签约守约好吗？"],
        "七杀": ["今天适合接难事吗？", "压力大了怎么解？", "今天容易和人硬碰吗？"],
        "正官": ["今天适合守规矩办事吗？", "该复命的事今天办吗？", "今天越级行事好吗？"],
        "偏印": ["今天适合独处想事吗？", "想太多会内耗吗？", "今天温故知新好吗？"],
        "正印": ["今天适合学习纳言吗？", "长辈的话要听吗？", "今天早睡养神好吗？"],
    ]

    /// 繁体(用词对齐 mappingHant 惯例:記帳/覆命)。
    static let suggestionsHant: [String: [String]] = [
        "比肩": ["今天適合自己單幹嗎？", "有爭執要避一避嗎？", "和同伴分利該注意什麼？"],
        "劫财": ["今天適合帶頭開拓嗎？", "借錢給人穩當嗎？", "今天容易衝動花錢嗎？"],
        "食神": ["今天適合創作表達嗎？", "和老友聚一聚好嗎？", "今天熬夜行嗎？"],
        "伤官": ["今天適合把想法說出來嗎？", "說話容易衝撞人嗎？", "今天能拿出新東西嗎？"],
        "偏财": ["今天適合拓展新客戶嗎？", "有便宜該不該佔？", "今天投資穩當嗎？"],
        "正财": ["今天適合按部就班做事嗎？", "記帳理一理好嗎？", "今天簽約守約好嗎？"],
        "七杀": ["今天適合接難事嗎？", "壓力大了怎麼解？", "今天容易和人硬碰嗎？"],
        "正官": ["今天適合守規矩辦事嗎？", "該覆命的事今天辦嗎？", "今天越級行事好嗎？"],
        "偏印": ["今天適合獨處想事嗎？", "想太多會內耗嗎？", "今天溫故知新好嗎？"],
        "正印": ["今天適合學習納言嗎？", "長輩的話要聽嗎？", "今天早睡養神好嗎？"],
    ]

    /// EN(每条 ≤12 words、零 CJK,问事窗点选直发)。
    static let suggestionsEn: [String: [String]] = [
        "比肩": ["Should I go my own way today?", "Is there an argument to sidestep?", "How should I split stakes with a peer?"],
        "劫财": ["Should I take the lead today?", "Is it safe to lend money today?", "Will I spend on impulse today?"],
        "食神": ["Should I make something today?", "Is it a good day to see friends?", "Can I stay up late tonight?"],
        "伤官": ["Should I speak my mind today?", "Might my words rub people wrong?", "Can I show new work today?"],
        "偏财": ["Should I chase new clients today?", "Is that bargain worth taking?", "Is it a safe day to invest?"],
        "正财": ["Should I keep to routine today?", "Is it a good day to do the books?", "Should I sign and keep my word today?"],
        "七杀": ["Should I take on the hard thing?", "How do I release the pressure?", "Might I clash with someone today?"],
        "正官": ["Should I play by the rules today?", "Should I close the loop today?", "Is it wise to skip the line today?"],
        "偏印": ["Should I sit with it alone today?", "Am I overthinking things today?", "Is it a good day to review old notes?"],
        "正印": ["Should I learn something today?", "Should I take that advice?", "Is tonight good for an early sleep?"],
    ]

    /// 通用候选(查表 miss / 从格类盘):不冒充十神特化问题。
    static func fallbackSuggestions(for language: AppLanguage) -> [String] {
        switch language {
        case .zh:     return ["今天做事顺利吗？", "要避开什么人和事？", "什么时候状态最好？"]
        case .zhHant: return ["今天做事順利嗎？", "要避開什麼人和事？", "什麼時候狀態最好？"]
        case .en:     return ["Will things go smoothly today?", "What should I steer around?", "When am I at my best today?"]
        }
    }

    /// 候选问题查询:查不到显式回落通用三条 + 日志(同 insight 查询哲学)。
    static func suggestions(
        for relation: String, language: AppLanguage = AppLanguage.current
    ) -> [String] {
        let table: [String: [String]]
        switch language {
        case .zh: table = suggestionsZh
        case .zhHant: table = suggestionsHant
        case .en: table = suggestionsEn
        }
        if let hit = table[relation] { return hit }
        AppLogger.app.warning(
            "op=engineAskSuggestions.lookupMiss day_relation=\(relation, privacy: .public) -> fallback"
        )
        return fallbackSuggestions(for: language)
    }
}
