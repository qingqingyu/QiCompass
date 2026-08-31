import SwiftUI

/// success 态主布局(V4 一幅图为主角,2026-08-30 拍板,参考 v4-reference.html):
/// 三行日期区 → hero 插画(3:2,静态样图)→ 宜忌单行 → AI 解读 → hairline 小注 →
/// 大留白 → 第二屏(7 日历史带 + 明日预告)。
///
/// 不直接接 state machine,由 DailyFortuneView 切换后传入。
///
/// 2026-08-30 V4:
/// - 吸顶方向感知折叠带**整体移除**(首屏无带可折,机制空转);历史带随内容进第二屏,
///   `onHistorySelect` / 历史回看解锁 / sheet 竞态规避全部原样保留
/// - 历史回看解锁(MONETIZATION.md §每日运势历史回看):免费 7 天,任意购买解锁全部
struct DailyFortuneMainView: View {
    @Bindable var vm: DailyFortuneViewModel
    let response: DailyFortuneResponse
    let interpretState: InterpretState
    let businessDate: Date
    let chartHash: String?
    let ziHourRule: String
    let onRefresh: () -> Void
    let onHistorySelect: (Date) -> Void
    let onGenerateInterpret: () -> Void

    @EnvironmentObject private var env: AppEnvironment

    @State private var historySnapshots: [DailyFortuneSnapshot] = []
    @State private var historyError: String?

    // 历史回看解锁 + sheet
    @State private var showingHistorySheet = false
    @State private var showingPaywall = false
    @State private var canViewFullHistory = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 离线查看角标(方案 step 6):网络失败 fallback 到本地缓存时显示。
                if vm.isOffline {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                        Text(L10n.DailyFortune.mainOffline)
                    }
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 6)
                    .background(BaziTheme.ink.opacity(0.05), in: Capsule())
                }

                if let historyError {
                    Text(historyError)
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.inkMuted.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                // ===== 第一屏(V4:图为主角) =====

                // 三行日期区(公历大字/农历·干支/短标签+关系+冲 chips)
                DailyFortuneHeaderView(
                    businessDate: businessDate,
                    lunarDate: response.lunarDate,
                    dayPillar: response.dayPillar,
                    dayRelation: response.dayRelationToDayMaster,
                    dayChong: response.dayChong,
                    dayChongTargets: response.dayChongTargets,
                )
                .padding(.horizontal, 24)

                // hero 插画(五行小景,S0 静态样图;左右 17pt 边距宽于文本区)
                DailyImageHeroSection(dayPillar: response.dayPillar)
                    .padding(.horizontal, 17)

                // 宜/忌 main anchor(V4 单行居中;视觉锚点,非 AI 输出)
                YiJiAnchorSection(dayRelation: response.dayRelationToDayMaster)
                    .padding(.horizontal, 24)
                    .padding(.top, 26)

                // AI 解读(50-80 字 Medium voice)
                DailyInterpretationSection(
                    state: interpretState,
                    remainingReads: vm.remainingReads,
                    nextReset: vm.nextDailyReset,
                    onGenerate: onGenerateInterpret,
                    onRetry: onGenerateInterpret,
                )
                .padding(.horizontal, 24)

                // hairline 小注:干支 · 十神 · 免责
                heroFootnote
                    .padding(.horizontal, 17)
                    .padding(.top, 18)

                // ===== 第二屏(历史回看 + 明日预告) =====

                // 大留白后进入第二屏(V4 参考图 CTA 沉底的呼吸节奏)
                Divider()
                    .overlay(BaziTheme.hairline)
                    .padding(.top, 48)

                DailyFortuneHistoryView(
                    selectedDate: businessDate,
                    snapshots: historySnapshots,
                    canViewFullHistory: canViewFullHistory,
                    onEarlier: { showingHistorySheet = true },
                    onSelect: onHistorySelect,
                )
                .padding(.horizontal, 16)
                .padding(.top, 4)

                // 明日预告
                TomorrowPreviewSection(preview: response.tomorrowPreview)
                    .padding(.horizontal, 24)
            }
            .padding(.bottom, 32)
        }
        .refreshable { onRefresh() }
        // 历史回看 sheet(免费锁定态 / 已购清单态)
        .sheet(isPresented: $showingHistorySheet) {
            DailyFortuneHistorySheet(
                canViewFullHistory: canViewFullHistory,
                snapshots: historySnapshots,
                onSelect: onHistorySelect,
                onUnlock: {
                    // 付费墙按 contentHash 卖深度解析;hash 缺失说明调用方状态错乱,显式记录不弹
                    guard chartHash != nil else {
                        AppLogger.app.warning("op=dailyFortune.historyUnlock.skip reason=no_chart_hash")
                        return
                    }
                    // SwiftUI 竞态规避:历史 sheet 的 dismiss 动画进行中立即 present 付费墙
                    // 会被静默丢弃(iOS 17 实测行为,三查 🟡),等动画结束(~0.4s)再呈现
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        showingPaywall = true
                    }
                }
            )
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(
                viewModel: PaywallViewModel(
                    module: .deepAnalysis,
                    contentHash: chartHash ?? "",
                    purchaseManager: env.purchaseManager,
                    onPurchaseSuccess: {
                        showingPaywall = false
                        // 任意购买落地 → 立即重查解锁态(下次打开「更早」即清单态)
                        refreshUnlockState()
                    }
                )
            )
        }
        .background(
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Color.clear.onAppear {
                    vm.checkBusinessDateChanged(
                        currentChartHash: chartHash,
                        ziHourRule: ziHourRule,
                    )
                }
            }
        )
        .task {
            loadHistory()
            refreshUnlockState()
        }
    }

    // MARK: - hero 小注

    /// V4 文本区脚注:hairline + 「丙子日 · 偏印 · 解读仅供参照」。
    private var heroFootnote: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)
            Text(
                verbatim: "\(response.dayPillar)\(L10n.DailyFortune.dayPillarSuffix) · \(response.dayRelationToDayMaster) · \(L10n.DailyFortune.disclaimer)"
            )
            .font(BaziFont.caption(size: 10.5))
            .tracking(1.5)
            .foregroundStyle(BaziTheme.inkMutedSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 9)
        }
    }

    // MARK: - 历史回看解锁

    /// 「任意一笔 active 购买 → 解锁全部历史」判据(MONETIZATION.md §每日运势历史回看)。
    /// 双轨与 EntitlementStore.getActive 一致:userId 优先,userLocalId 兜底。
    private func refreshUnlockState() {
        canViewFullHistory = env.entitlementStore.hasAnyActivePurchase(
            userLocalId: UserIdentity.userLocalId,
            userId: UserIdentity.isAuthenticated ? UserIdentity.currentUserId : nil
        )
    }

    private func loadHistory() {
        guard let hash = chartHash else { return }
        do {
            historySnapshots = try vm.loadHistory(chartHash: hash)
            historyError = nil
        } catch {
            // 不静默吞:错误显示在 chip 旁(不影响主流程)
            historyError = L10n.DailyFortune.mainHistoryError
            AppLogger.persistence.error(
                "op=dailyFortune.loadHistory failed error=\(String(describing: error), privacy: .public)"
            )
        }
    }
}

// MARK: - YiJiAnchorSection

/// 今日运势页宜/忌 main anchor(视觉锚点,非 AI 输出)。
///
/// 墨青(jade)=宜 / 淡朱(cinnabar)=忌,V4 单行左右并列 layout。
///
/// **数据源**(v1 简化):前端十神→关键词映射表。基于 `dayRelationToDayMaster`
/// 查表得到 actionable 2-3 字 bullet。
/// TODO 后续:可能挪到后端基于 favorable_elements + 流日关系确定性映射,
/// 但 v1 不增加后端复杂度,前端 lookup 足够。
///
/// 全页唯一的宜/忌(2026-08-30 用户拍板删通用黄历块——同屏两套宜/忌语义打架,
/// 保留本节):**个性化**宜/忌,基于流日对日主的关系,十神查表得单条关键词。
/// 黄历数据(huangliYi/Ji)后端照常返回并进 AI 上下文,只是不再 UI 展示。
private struct YiJiAnchorSection: View {
    let dayRelation: String

    /// 十神→宜/忌 actionable 关键词映射(10 神,对齐后端 lunar_python 命名)。
    /// 十神 key 始终用中文(后端 `dayRelationToDayMaster` 不翻译,见 i18n 决策 7);
    /// values 按 `AppLanguage.current` 切换中英文。
    private static let mappingZh: [String: (yi: String, ji: String)] = [
        "比肩": ("独立", "争执"),
        "劫财": ("行动", "冲动"),
        "食神": ("创造", "拖延"),
        "伤官": ("表达", "冲撞"),
        "偏财": ("拓展", "孤注"),
        "正财": ("守成", "短视"),
        "七杀": ("果断", "犹豫"),
        "正官": ("担当", "退缩"),
        "偏印": ("思考", "执拗"),
        "正印": ("学习", "依赖"),
    ]

    private static let mappingEn: [String: (yi: String, ji: String)] = [
        "比肩": ("Independence", "Conflict"),
        "劫财": ("Action", "Impulse"),
        "食神": ("Creation", "Procrastination"),
        "伤官": ("Expression", "Confrontation"),
        "偏财": ("Expansion", "Overreach"),
        "正财": ("Consolidation", "Short-sightedness"),
        "七杀": ("Decisiveness", "Hesitation"),
        "正官": ("Responsibility", "Retreat"),
        "偏印": ("Reflection", "Stubbornness"),
        "正印": ("Learning", "Dependency"),
    ]

    private static var mapping: [String: (yi: String, ji: String)] {
        AppLanguage.current == "en" ? mappingEn : mappingZh
    }

    /// 防御:未知关系(理论上后端必返回十神之一,但保护)。
    private static var fallback: (yi: String, ji: String) {
        AppLanguage.current == "en"
            ? ("Go with the flow", "Forcing")
            : ("顺势", "强求")
    }

    /// 查表命中失败时记日志,不静默 fallback(对齐 CLAUDE.md 错误显式传播约束)。
    private var pair: (yi: String, ji: String) {
        if let matched = Self.mapping[dayRelation] {
            return matched
        }
        AppLogger.app.warning(
            "op=yiJiAnchor.lookupMiss day_relation=\(dayRelation, privacy: .public) -> fallback"
        )
        return Self.fallback
    }

    var body: some View {
        let resolved = pair
        // V4 单行居中:宜(jade)思考 · 忌(淡朱)执拗(参考 v4-reference.html,无 hairline)
        HStack(spacing: 22) {
            anchorItem(label: L10n.DailyFortune.yiLabel, keyword: resolved.yi, color: BaziTheme.jade)
            Text(verbatim: "·")
                .font(BaziFont.caption(size: 12))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            anchorItem(label: L10n.DailyFortune.jiLabel, keyword: resolved.ji, color: BaziTheme.cinnabar.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
    }

    private func anchorItem(label: String, keyword: String, color: Color) -> some View {
        HStack(spacing: 9) {
            Text(label)
                .font(BaziFont.display(size: 13, weight: .medium))
                .tracking(4)
                .foregroundStyle(color)
            Text(keyword)
                .bodySerifText(size: 15)
                .foregroundStyle(BaziTheme.ink)
        }
    }
}
