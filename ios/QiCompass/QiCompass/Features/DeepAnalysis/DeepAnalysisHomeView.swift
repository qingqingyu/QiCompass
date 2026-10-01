import SwiftUI

/// 深度解析主页(2026-10-01 按 mock「QiCompass Chart」重构):
/// hero 四柱横排四列(年|月|日|时,日列 1.35 倍宽;干支分字五行着色;
/// 柱底 hairline 十神块;墨圆居中垫底)→ 喜忌一行(玄印 + 五行着色)→
/// 锚句 → 捌章目录(命书大标题 + 已读进度条)→ 沉底 CTA → 盘面细目入口。
///
/// 读查分离:「读」push ChapterReadingView,「查」push ChartDetailView。
/// 长文排版全部在阅读页解决,主页只做索引与仪式感。
///
/// 时辰未知(S07/S10 产品语义,与设计稿 ④ 的差异已按产品事实修正):
/// 日柱确定 → M0/M1 免费章照给;付费章点击 → PaywallView(其内部对
/// hourUnknownDayDetermined 显示「时」印补时辰拦截态,不卖)。hero 时柱
/// 空位 = dashed 圆位,点击进补时辰 sheet(D7 触点 1,同 PillarsTable)。
struct DeepAnalysisHomeView: View {
    @Bindable var vm: DeepAnalysisViewModel
    let response: BaziResponse
    let request: BaziCalculateRequest
    /// 补时辰触点(hero 时柱空位点击),宿主 DeepAnalysisView 装配 AddHourSheet。
    var onAddHour: () -> Void
    /// 阅读页跳转唯一入口(开卷/续读/目录行点击):宿主写 navigation path。
    var onOpenChapter: (ModuleID) -> Void
    /// 付费墙触点(解印 CTA / 锁章行):sheet 挂在宿主根上,阅读页 push 中也可触发。
    var onShowPaywall: () -> Void

    /// S5 术语释义:hero 十神/旺衰旁标点击 → BaziTermNoteSheet(共享词表)。
    @State private var termNote: TermNoteRequest?

    /// 从格:hero 竖注与喜忌行降级(喜忌留空,详见命书)。
    private var isSpecialPattern: Bool {
        response.dayMasterStrength == "special_pattern"
    }

    /// 已读章数(moduleStates 中 .ok 的数量,含免费与付费)。
    private var readCount: Int {
        ModuleID.allCases.filter { vm.moduleStates[$0]?.isOk == true }.count
    }

    var body: some View {
        ZStack {
            BaziTheme.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    xijiLine
                    anchorSentence
                    chainBanner
                    // D10.5(S7):命中其它语言原文时,目录上方提示条——先显示原文,
                    // 点按钮才翻译(不自动批量)
                    if let offer = vm.translationOffer {
                        TranslateHintBar(
                            sourceLanguage: offer.sourceLanguage,
                            targetLanguage: AppLanguage.currentWire,
                            isTranslating: vm.isTranslatingChain,
                            onTranslate: { vm.acceptTranslation() }
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)
                    }
                    tocHeader
                    tocRows
                    ctaArea
                }
            }
        }
    }

    // MARK: - Hero(四柱横排)

    /// 四柱列间距(mock .pillars 无显式 gap,由 1fr 比例自然分距;取窄距保日列宽度)。
    private static let pillarGap: CGFloat = 8

    private var hero: some View {
        ZStack {
            // 淡墨圆:居中垫底(mock .enso opacity .07,略偏左上),常驻极缓呼吸
            // (DESIGN.md breathe 7-8s;此透明度下呼吸几不可察,保留品牌指纹不抢戏)
            EnsoView(size: 300, breathing: true)
                .opacity(0.07)
                .offset(x: -16, y: -8)
            // 四柱四列:1 : 1 : 1.35 : 1(mock grid-template-columns,日列加宽)
            GeometryReader { geo in
                let unit = (geo.size.width - 3 * Self.pillarGap) / 4.35
                HStack(alignment: .top, spacing: Self.pillarGap) {
                    pillarColumn(label: L10n.DeepChart.pillarYear, pillar: response.pillars.year, isDay: false, width: unit)
                    pillarColumn(label: L10n.DeepChart.pillarMonth, pillar: response.pillars.month, isDay: false, width: unit)
                    pillarColumn(label: L10n.DeepChart.pillarDay, pillar: response.pillars.day, isDay: true, width: unit * 1.35)
                    pillarColumn(label: L10n.DeepChart.pillarHour, pillar: response.pillars.hour, isDay: false, width: unit)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
        .frame(height: 185)
        .padding(.horizontal, 34)
        .padding(.top, 24)
        // S5 术语释义(交互先例 = 今日页 HeroShiShenNoteSheet,2026-09-29 D3)
        .sheet(item: $termNote) { req in
            BaziTermNoteSheet(term: req.term)
                .presentationDetents([.height(250), .large])
                .presentationBackground(BaziTheme.paper)
        }
    }

    /// 单柱列:柱标 → 干/支两行各自五行着色 → en 带调拼音 → hairline 十神块。
    /// 日列放大并携朱红「日主」与左缘竖排旺衰。
    /// 柱未知(时辰未知/节气歧义)→ dashed 圆位占干支之位,点击进补时辰(S05 同语义)。
    /// L3 接入(§3 矩阵):干支三语汉字主标,en 附加小字拼音;十神/旺衰走 BaziTerms。
    @ViewBuilder
    private func pillarColumn(label: String, pillar: PillarDTO?, isDay: Bool, width: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 0) {
            Text(label)
                .font(BaziFont.caption(size: 10.5))
                .tracking(2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .padding(.bottom, 12)
            if let pillar {
                VStack(spacing: isDay ? 1 : 2) {
                    Text(pillar.gan)
                        .font(BaziFont.ganzhi(size: isDay ? 34 : 25))
                        .foregroundStyle(elementTextColor(pillar.ganElement))
                    Text(pillar.zhi)
                        .font(BaziFont.ganzhi(size: isDay ? 34 : 25))
                        .foregroundStyle(elementTextColor(pillar.zhiElement))
                }
                // en 小字带调拼音(§3:只在 hero 首次出现处给;zh/zh-hant 不渲染)
                if AppLanguage.current == .en, let pinyin = BaziTerms.romanized(pillar.ganZhi) {
                    Text(pinyin)
                        .font(BaziFont.caption(size: 9.5))
                        .italic()
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                        .padding(.top, 5)
                }
                godBlock(pillar: pillar, isDay: isDay, columnWidth: width)
            } else {
                // 柱位空缺:dashed 圆环 = 干支之位空着。常态是时柱未知(D7 触点 1);
                // 年/月柱也可能因节气边界歧义(S02,立春日+时辰未知)留空——
                // 点击同样进补时辰(补上确定时辰即一并解年/月歧义)。
                Circle()
                    .stroke(
                        BaziTheme.hairlineDashed,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                    .onTapGesture {
                        HapticEngine.light()
                        onAddHour()
                    }
                    .accessibilityLabel(label == L10n.DeepChart.pillarHour ? L10n.Common.hourUnknown : L10n.DeepChart.pillarUndetermined(label))
                    .padding(.top, 14)
            }
        }
        .frame(width: width)
        // 日列左缘竖排旺衰(mock .strength:vertical-rl,列左内缘)。
        // 仅 CJK 渲染:VText 对拉丁词横排回退,长词会压到日柱大字——
        // EN 的旺衰改走 god 副行「Day Master · Strong」(见 godBlock)。
        .overlay(alignment: .topLeading) {
            if isDay, let strength = dayStrengthTerm, AppLanguage.current != .en {
                Group {
                    // S5 释义入口:旺衰可点 → 一句人话;词表未收录不挂入口(宁缺毋滥)
                    if BaziTermNotes.note(for: strength) != nil {
                        Button {
                            HapticEngine.light()
                            termNote = TermNoteRequest(term: strength)
                        } label: {
                            VText(phrase: BaziTerms.display(strength), size: 12.5, tracking: 4, color: BaziTheme.inkMuted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(String(localized: "查看释义"))
                    } else {
                        VText(phrase: BaziTerms.display(strength), size: 12.5, tracking: 4, color: BaziTheme.inkMuted)
                    }
                }
                .offset(x: -10, y: 32)
            }
        }
    }

    /// 柱底十神块:顶部 hairline(列宽 70%,mock .god border-top),日柱「日主」朱红;
    /// en 追加意译小字(zh/zh-hant 只有汉字主行)。
    /// S5 释义入口保留:非日柱十神可点 → 一句人话(词表未收录不挂入口)。
    @ViewBuilder
    private func godBlock(pillar: PillarDTO, isDay: Bool, columnWidth: CGFloat) -> some View {
        VStack(spacing: 1.5) {
            // 十神汉字主标:en 也保持汉字(§3 决策:术语主标汉字,意译在旁)
            let han = godHan(isDay ? "日主" : pillar.shishenGan)
            if !isDay, BaziTermNotes.note(for: pillar.shishenGan) != nil {
                Button {
                    HapticEngine.light()
                    termNote = TermNoteRequest(term: pillar.shishenGan)
                } label: {
                    godMainText(han, isDay: isDay)
                }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "查看释义"))
            } else {
                godMainText(han, isDay: isDay)
            }
            if AppLanguage.current == .en {
                // EN 副行:日柱合并旺衰(VText 竖排位 EN 不渲染,旺衰语义在此承载)
                Text(isDay ? enDayGodSubline : BaziTerms.display(pillar.shishenGan))
                    .font(BaziFont.caption(size: 10))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        }
        .padding(.top, 9)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(width: columnWidth * 0.7, height: 0.5)
        }
    }

    private func godMainText(_ han: String, isDay: Bool) -> some View {
        Text(han)
            .font(BaziFont.display(size: 12.5))
            .tracking(1)
            .foregroundStyle(isDay ? BaziTheme.cinnabar : BaziTheme.ink)
    }

    /// 十神汉字主标:zh/zh-hant 用本语汉字,en 用简体汉字作字形主标(§3)。
    private func godHan(_ term: String) -> String {
        BaziTerms.display(term, language: AppLanguage.current == .en ? .zh : AppLanguage.current)
    }

    /// EN 日柱 god 副行:「Day Master · Strong」;旺衰未知 → 只 Day Master。
    private var enDayGodSubline: String {
        guard let strength = dayStrengthTerm else { return BaziTerms.display("日主") }
        return "\(BaziTerms.display("日主")) · \(BaziTerms.display(strength))"
    }

    /// 干支五行着色(2026-10-01 拍板:hero 干支全上五行色,DESIGN.md 五行色映射)。
    /// element key 未知 → 浓墨回落(与 ElementColors 兜底同哲学:不静默套强调色)。
    private func elementTextColor(_ elementKey: String) -> Color {
        ElementColors.from(elementKey)?.color ?? BaziTheme.ink
    }

    /// 旺衰 zh key(S5:hero 日柱旺衰释义入口用;未知值 → nil 不渲染)。
    private var dayStrengthTerm: String? {
        switch response.dayMasterStrength {
        case "strong":          return "身强"
        case "weak":            return "身弱"
        case "balanced":        return "中和"
        case "special_pattern": return "从格"
        default:                return nil
        }
    }

    // MARK: - 喜忌行(玄印 + 五行着色)

    /// 喜忌一行:左「玄」印(从 09-01 版 hero 左下移来),右单行「喜 火 土 · 忌 木」,
    /// 每个元素字各自五行着色。从格 → 整行降级文案(喜忌留空,详见命书)。
    /// 替代 09-01 版右下竖排喜忌小注。
    private var xijiLine: some View {
        HStack(alignment: .center, spacing: 12) {
            SealStamp(character: "玄", size: 30, rotation: -4, stampDelay: 0.3)
            if isSpecialPattern {
                Text(L10n.DeepChart.sideNoteSpecialPattern)
                    .font(BaziFont.body(size: 14.5))
                    .foregroundStyle(BaziTheme.inkMuted)
            } else {
                xijiText
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .padding(.top, 24)
    }

    /// 喜忌拼接 Text:label 灰墨 + 元素字五行色(Kaiti Medium,模拟 mock em 加重)。
    /// 五行值经 BaziTerms 取显示语;未知值显式回落灰墨着色,不吞。
    private var xijiText: Text {
        var t = Text("").font(BaziFont.body(size: 14.5))
        if !response.favorableElements.isEmpty {
            t = t + Text(L10n.DeepChart.xijiFavorableLabel)
                .foregroundStyle(BaziTheme.inkMuted)
            for element in response.favorableElements {
                t = t + Text(" ")
                    .foregroundStyle(BaziTheme.inkMuted)
                    + Text(BaziTerms.display(element))
                        .font(BaziFont.display(size: 14.5))
                        .foregroundStyle(elementColorFromZh(element))
            }
        }
        if !response.unfavorableElements.isEmpty {
            if !response.favorableElements.isEmpty {
                t = t + Text(" · ")
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
            t = t + Text(L10n.DeepChart.xijiUnfavorableLabel)
                .foregroundStyle(BaziTheme.inkMuted)
            for element in response.unfavorableElements {
                t = t + Text(" ")
                    .foregroundStyle(BaziTheme.inkMuted)
                    + Text(BaziTerms.display(element))
                        .font(BaziFont.display(size: 14.5))
                        .foregroundStyle(elementColorFromZh(element))
            }
        }
        return t
    }

    /// 喜忌元素(zh key 如「木」)→ 五行色;未知 key 回落灰墨(不静默套强调色)。
    private func elementColorFromZh(_ zhKey: String) -> Color {
        guard let rawKey = ElementColors.fromZh(zhKey),
              let color = ElementColors(rawValue: rawKey)?.color else {
            return BaziTheme.inkMuted
        }
        return color
    }

    // MARK: - 锚句

    /// 锚句 = mock verdict:display 级大字(2026-10-01 从 body 15pt 放大)。
    @ViewBuilder
    private var anchorSentence: some View {
        if let anchor = response.anchorSentence {
            Text(MarkdownSanitizer.rendered(anchor))
                .font(BaziFont.display(size: 17))
                .foregroundStyle(BaziTheme.ink)
                .lineSpacing(8)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.top, 14)
                .padding(.bottom, 12)
        }
    }

    // MARK: - 命书链进度横幅(2026-09-08 自动起链 + 断点续跑)

    /// 链在跑期间的进度横幅(临时态,dashed hairline 盒,DESIGN.md §Layout;
    /// 禁渐变禁大卡片):主行 = 已成 i/N 章 + 预计耗时(`ChainProgress` 纯派生),
    /// 副行 = 可离开提示(收起心智:不必守着,回来续读)。
    /// 链结束(完成/中断)自动隐藏;收尾一瞬 remaining 归 0 也不再显示
    /// (避免「约需 0 分钟」的傻文案闪现)。章节逐章点亮由目录行状态自行呈现。
    /// 注意 CTA 不挂 isLoading——`PrimaryCTAButton` 的 isLoading 会整体禁点,
    /// 而链跑中恰要允许点「开卷/续读」进章观看生成。
    @ViewBuilder
    private var chainBanner: some View {
        if vm.isChainRunning {
            let progress = ChainProgress.resolve(
                moduleStates: vm.moduleStates,
                hasEntitlement: hasEntitlementForPaid,
                hasM4Input: vm.m4UserInput != nil,
                hasM5Input: vm.m5UserInput != nil
            )
            if progress.remaining > 0 {
                VStack(spacing: 4) {
                    Text(L10n.DeepChain.bannerProgress(
                        done: progress.done,
                        total: progress.total,
                        minutes: progress.estimatedMinutes,
                        isOwned: hasEntitlementForPaid
                    ))
                        .font(BaziFont.caption(size: 11))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMuted)
                        .frame(maxWidth: .infinity)
                    Text(L10n.DeepChain.bannerLeaveHint)
                        .font(BaziFont.caption(size: 10))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(BaziTheme.hairlineDashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .padding(.horizontal, 34)
                .padding(.top, 10)
            }
        }
    }

    // MARK: - 命书目录(大标题 + 进度条)

    private var tocHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                // 命书大标题(EN "Your Reading",S4 弃 book 比喻;mock 基准 28px serif;zh 两字楷体 22pt 同分量)
                Text(L10n.DeepChart.tocTitle)
                    .font(BaziFont.display(size: 22))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.ink)
                Spacer(minLength: 12)
                Text(tocStatusText)
                    .font(BaziFont.numeric(size: 11))
                    .foregroundStyle(tocStatusIsLimit ? BaziTheme.cinnabar : BaziTheme.inkMuted)
            }
            // 已读进度条(mock .progress:2pt 线,已读比例填墨;未读满时 0 宽不可见,天然成立)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(BaziTheme.hairline)
                    Rectangle()
                        .fill(BaziTheme.ink)
                        .frame(width: geo.size.width * CGFloat(readCount) / CGFloat(ModuleID.allCases.count))
                }
            }
            .frame(height: 2)
            .accessibilityElement()
            .accessibilityLabel(L10n.DeepChart.readProgressA11y)
            .accessibilityValue("\(readCount) / \(ModuleID.allCases.count)")
            // 次数口径小注(2026-09-19 S05):「今日剩余 N 次」单看不知在消耗什么;
            // 达限态重置信息已在 tocStatusText,不重复。
            // S4 命书框架(2026-09-30):未读完时先说清「命书 = 按章节生成的完整
            // 命盘解读」,消灭 EN "book" 比喻与 zh「命书」首次出现无铺垫的问题。
            if readCount < ModuleID.allCases.count {
                Text(L10n.DeepChain.tocIntro)
                    .font(BaziFont.caption(size: 10))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(L10n.DeepChain.tocQuotaNote)
                .font(BaziFont.caption(size: 10))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .padding(.horizontal, 34)
        .padding(.top, 14)
        .padding(.bottom, 2)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)
                .padding(.horizontal, 34)
        }
    }

    /// 目录右侧状态:已读 x/8 → 次数余量 → 达上限(cinnabar)。
    private var tocStatusText: String {
        if readCount > 0 {
            return String(format: String(localized: "已读 %lld / %lld"), readCount, ModuleID.allCases.count)
        }
        if vm.remainingReads <= 0 {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return String(format: String(localized: "今日次数已用尽 · 明日 %@ 重置"), f.string(from: vm.nextDailyReset))
        }
        return String(format: String(localized: "今日剩余 %lld 次"), vm.remainingReads)
    }

    /// 达上限判定:一次未读且次数耗尽(已读过 → 缓存命中不耗次,不吓用户)。
    private var tocStatusIsLimit: Bool {
        readCount == 0 && vm.remainingReads <= 0
    }

    private var tocRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(ModuleID.allCases.enumerated()), id: \.element) { idx, module in
                if idx > 0 {
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(height: 0.5)
                }
                tocRow(index: idx, module: module)
            }
        }
        .padding(.horizontal, 34)
    }

    @ViewBuilder
    private func tocRow(index: Int, module: ModuleID) -> some View {
        let state = vm.moduleStates[module]
        let row = ChapterRowModel.resolve(
            module: module,
            state: state,
            hasEntitlement: hasEntitlementForPaid
        )

        Button {
            HapticEngine.light()
            AppLogger.app.info(
                "deepHome.tocRow.tap module=\(module.rawValue, privacy: .public) row=\(row, privacy: .public)"
            )
            switch row {
            case .lockedPaid:
                // 付费未解锁 → 付费墙(时辰未知时墙内自动转补时辰拦截态,S07)
                onShowPaywall()
            case .read, .generating, .retryable, .needsInput:
                // 已生成/生成中/失败/需输入 → 进阅读页(四态自呈现)
                onOpenChapter(module)
            case .unreadFree:
                if state == nil {
                    // 一章未开始 → 开卷语义:起链;上游 pending(链在跑)只进章
                    vm.generateV1AllModules()
                }
                onOpenChapter(module)
            }
        } label: {
            // 2026-10-01 mock .row 放大:徽 38 / 章名 16.5 / 行距 15 / 行尾 › 指示可进
            HStack(spacing: 16) {
                // 章号 M0=壹 … M7=捌(2026-09-02 修 off-by-one,对齐设计稿①与 PaywallView 口径)
                NumeralBadge(index: index + 1, locked: row.isBadgeLocked, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.chapterName)
                        .font(BaziFont.display(size: 16.5))
                        .tracking(1.5)
                        .foregroundStyle(row.isDim ? BaziTheme.inkMuted : BaziTheme.ink)
                    Text(module.subtitle)
                        .font(BaziFont.caption(size: 11))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                switch row {
                case .read:
                    HStack(spacing: 8) {
                        Circle()
                            .fill(BaziTheme.ink)
                            .frame(width: 6, height: 6)
                        rowChevron
                    }
                case .lockedPaid:
                    PaidTag()
                case .generating:
                    Text("生成中…")
                        .font(BaziFont.caption(size: 10))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                case .unreadFree, .retryable, .needsInput:
                    rowChevron
                }
            }
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 可点行行尾 ›(与「盘面细目」链接同语言;锁定行不挂,付费标已自表意)。
    private var rowChevron: some View {
        Text("›")
            .font(BaziFont.caption(size: 13))
            .foregroundStyle(BaziTheme.inkMutedSecondary)
    }

    // MARK: - 沉底 CTA

    @ViewBuilder
    private var ctaArea: some View {
        VStack(spacing: 7) {
            ctaButton
            NavigationLink {
                ChartDetailView(response: response, request: request, onAddHour: onAddHour)
            } label: {
                HStack(spacing: BaziTheme.Spacing.xs) {
                    Text("盘面细目(辅柱 · 五行 · 神煞 · 大运全表)")
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                    Text("›")
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, BaziTheme.Spacing.sm)
            }
            .buttonStyle(.plain)
            Button("重新排盘") {
                vm.reset()
            }
            .font(BaziFont.caption(size: 11))
            .foregroundStyle(BaziTheme.cinnabar)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 34)
        .padding(.top, 16)
    }

    /// 主 CTA(状态派生在 HomeCTAModel,视图只渲染):开卷 / 续读 /
    /// 解印全本 / 次数用尽 ghost / 重读 ghost。
    @ViewBuilder
    private var ctaButton: some View {
        switch HomeCTAModel.resolve(
            moduleStates: vm.moduleStates,
            remainingReads: vm.remainingReads,
            hasEntitlement: hasEntitlementForPaid
        ) {
        case .openFirst(let next):
            // 开卷:起全链 + 进首章
            PrimaryCTAButton(
                title: String(format: String(localized: "开卷 · %@"), next.chapterName),
                loadingTitle: String(localized: "生成中…"),
                isLoading: false,
                action: {
                    vm.generateV1AllModules()
                    onOpenChapter(next)
                }
            )
        case .resume(let next):
            // 续读:单章触发(不重置整链——已 ok 章保持,缓存不闪 pending);
            // 链正在跑该章(.fetching)时只进章观看,不重复发请求
            PrimaryCTAButton(
                title: String(format: String(localized: "续读 · %@"), next.chapterName),
                loadingTitle: String(localized: "生成中…"),
                isLoading: false,
                action: {
                    if vm.moduleStates[next] != .fetching {
                        vm.retryV1Module(next)
                    }
                    onOpenChapter(next)
                }
            )
        case .unlockAll:
            PrimaryCTAButton(
                title: String(localized: "解印全本 · 叁至捌章"),
                loadingTitle: String(localized: "处理中…"),
                isLoading: false,
                action: onShowPaywall
            )
        case .reread:
            ghostButton("重读 · 壹 \(ModuleID.m0.chapterName)") {
                onOpenChapter(.m0)
            }
        case .limitReached:
            // 次数用尽(已读章走缓存不耗次,仍可从目录行点入)
            ghostButton("今日免费次数已用尽 · 已读章节仍可重读", action: nil)
        }
    }

    /// dashed ghost 形态(锁定/临时态语义,DESIGN.md §Layout)。
    @ViewBuilder
    private func ghostButton(_ title: String, action: (() -> Void)?) -> some View {
        if let action {
            Button(action: action) {
                Text(title)
                    .font(BaziFont.caption(size: 12))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(BaziTheme.hairlineDashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            }
            .buttonStyle(.plain)
        } else {
            Text(title)
                .font(BaziFont.caption(size: 12))
                .foregroundStyle(BaziTheme.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(BaziTheme.hairlineDashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
        }
    }

    /// 本地 entitlement 查询:VM 单源方法(与付费守卫/阅读页翻章同口径),只读。
    private var hasEntitlementForPaid: Bool {
        vm.hasDeepEntitlement(contentHash: response.contentHash)
    }
}
