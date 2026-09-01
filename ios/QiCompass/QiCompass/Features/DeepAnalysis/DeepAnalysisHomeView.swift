import SwiftUI

/// 深度解析主页(盘面小景 ①-②,2026-09-01 定稿 D):
/// hero 盘面仪式感(淡墨圆出血 + 四柱干支浓淡层次 + 竖排喜忌小注)
/// → 锚句 → 捌章目录 → 沉底 CTA(开卷/续读/解印/次数用尽)→ 盘面细目入口。
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

    @EnvironmentObject private var env: AppEnvironment

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
                    anchorSentence
                    tocHeader
                    tocRows
                    ctaArea
                }
            }
        }
    }

    // MARK: - Hero(盘面小景)

    private var hero: some View {
        ZStack(alignment: .topTrailing) {
            // 淡墨圆:右上出血,常驻极缓呼吸(DESIGN.md breathe 7-8s)
            EnsoView(size: 310, breathing: true)
                .offset(x: 88, y: -4)
            // 四柱竖列:年/月/时 灰墨 22pt,日主 34pt 浓墨
            VStack(alignment: .leading, spacing: 9) {
                heroRow(label: "年", pillar: response.pillars.year, isDay: false)
                heroRow(label: "月", pillar: response.pillars.month, isDay: false)
                heroRow(label: "日", pillar: response.pillars.day, isDay: true)
                heroRow(label: "时", pillar: response.pillars.hour, isDay: false)
            }
            .padding(.leading, 34)
            .padding(.top, 86)
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        // 左下品牌印
        .overlay(alignment: .bottomLeading) {
            SealStamp(character: "玄", size: 24, rotation: -4, stampDelay: 0.3)
                .padding(.leading, 34)
                .padding(.bottom, 18)
        }
        // 右下竖排喜忌小注
        .overlay(alignment: .bottomTrailing) {
            if !heroSideNote.isEmpty {
                VText(phrase: heroSideNote, size: 11.5, tracking: 4, color: BaziTheme.inkMuted)
                    .padding(.trailing, 18)
                    .padding(.bottom, 20)
            }
        }
    }

    /// 单柱行:干支大字 + 旁标十神;日主行放大并携带旺衰注。
    /// 柱未知(时辰未知)→ dashed 圆位占干支之位,点击进补时辰(S05 同语义)。
    @ViewBuilder
    private func heroRow(label: String, pillar: PillarDTO?, isDay: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(BaziFont.caption(size: 10.5))
                .tracking(2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .frame(width: 16, alignment: .leading)
            if let pillar {
                Text(pillar.ganZhi)
                    .font(BaziFont.ganzhi(size: isDay ? 34 : 22))
                    .tracking(isDay ? 4 : 5)
                    .foregroundStyle(isDay ? BaziTheme.ink : BaziTheme.ink.opacity(0.52))
                Text(isDay ? dayMasterNote : pillar.shishenGan)
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMuted)
            } else {
                // 时柱空位:dashed 圆环 = 干支之位空着(D7 触点 1)
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
                    .accessibilityLabel(L10n.Common.hourUnknown)
            }
        }
    }

    /// 日主旁注:「日主 · 身弱」;从格 → 「日主 · 从格」。
    private var dayMasterNote: String {
        let strength: String
        switch response.dayMasterStrength {
        case "strong":          strength = "身强"
        case "weak":            strength = "身弱"
        case "balanced":        strength = "中和"
        case "special_pattern": strength = "从格"
        default:                strength = ""
        }
        return strength.isEmpty ? "日主" : "日主 · \(strength)"
    }

    /// 右下竖注:喜木水 · 忌金;从格 → 从格 · 喜忌留空;无喜忌数据 → 空(不渲染)。
    private var heroSideNote: String {
        if isSpecialPattern {
            return "从格 · 喜忌留空"
        }
        var parts: [String] = []
        if !response.favorableElements.isEmpty {
            parts.append("喜" + response.favorableElements.joined())
        }
        if !response.unfavorableElements.isEmpty {
            parts.append("忌" + response.unfavorableElements.joined())
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 锚句

    @ViewBuilder
    private var anchorSentence: some View {
        if let anchor = response.anchorSentence {
            Text(MarkdownSanitizer.rendered(anchor))
                .bodySerifText(size: 15)
                .lineSpacing(11)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.top, 14)
                .padding(.bottom, 12)
        }
    }

    // MARK: - 捌章目录

    private var tocHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("命 书 · 捌 章")
                .font(BaziFont.caption(size: 10))
                .tracking(5)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Spacer(minLength: 12)
            Text(tocStatusText)
                .font(BaziFont.caption(size: 11))
                .foregroundStyle(tocStatusIsLimit ? BaziTheme.cinnabar : BaziTheme.inkMuted)
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
        if readCount > 0 || readCount == ModuleID.allCases.count {
            return "已读 \(readCount) / \(ModuleID.allCases.count)"
        }
        if vm.remainingReads <= 0 {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return "今日次数已用尽 · 明日 \(f.string(from: vm.nextDailyReset)) 重置"
        }
        return "今日剩余 \(vm.remainingReads) 次"
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
            HStack(spacing: 13) {
                NumeralBadge(index: index, locked: row.isBadgeLocked, size: 30)
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(chapterTitle(module))
                        .font(BaziFont.display(size: 15))
                        .tracking(1.5)
                        .foregroundStyle(row.isDim ? BaziTheme.inkMuted : BaziTheme.ink)
                    Text(module.subtitle)
                        .font(BaziFont.caption(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                switch row {
                case .read:
                    Circle()
                        .fill(BaziTheme.ink)
                        .frame(width: 4.5, height: 4.5)
                case .lockedPaid:
                    PaidTag()
                case .generating:
                    Text("生成中…")
                        .font(BaziFont.caption(size: 10))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                case .unreadFree, .retryable, .needsInput:
                    EmptyView()
                }
            }
            .padding(.vertical, 10.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 章名:displayName 去「M{N} · 」前缀(目录只留中文章名;不动
    /// ModuleDefinitions——它在 prompt 三边一致性守护栏清单里)。
    private func chapterTitle(_ module: ModuleID) -> String {
        let name = module.displayName
        guard let separator = name.range(of: "· ") else { return name }
        return String(name[separator.upperBound...])
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
                title: "开卷 · \(chapterTitle(next))",
                loadingTitle: "生成中…",
                isLoading: false,
                action: {
                    vm.generateV1AllModules()
                    onOpenChapter(next)
                }
            )
        case .resume(let next):
            // 续读:单章触发(不重置整链——已 ok 章保持,缓存不闪 pending)
            PrimaryCTAButton(
                title: "续读 · \(chapterTitle(next))",
                loadingTitle: "生成中…",
                isLoading: false,
                action: {
                    vm.retryV1Module(next)
                    onOpenChapter(next)
                }
            )
        case .unlockAll:
            PrimaryCTAButton(
                title: "解印全本 · 叁至捌章",
                loadingTitle: "处理中…",
                isLoading: false,
                action: onShowPaywall
            )
        case .reread:
            ghostButton("重读 · 壹 \(chapterTitle(.m0))") {
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

    /// 本地 entitlement 查询(与 VM 付费守卫同源同参;只读,不复制守卫逻辑)。
    private var hasEntitlementForPaid: Bool {
        env.entitlementStore.getActive(
            contentHash: response.contentHash,
            module: EntitlementModule.baziDeep,
            userLocalId: UserIdentity.userLocalId
        ) != nil
    }
}
