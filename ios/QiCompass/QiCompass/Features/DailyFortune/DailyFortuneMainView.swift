import SwiftUI

/// success 态主布局:吸顶历史 pill(方向感知折叠)+ 5 个 section + 下拉刷新。
///
/// 不直接接 state machine,由 DailyFortuneView 切换后传入。
///
/// 2026-08-30:
/// - 历史 pill 带挪进 `.safeAreaInset(edge: .top)`(钉在导航下),滚动方向感知折叠
///   (往下翻收起 / 往回翻展开 / 页顶强制展开;iOS 17 无 onScrollGeometryChange,用 preference 探针)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var historySnapshots: [DailyFortuneSnapshot] = []
    @State private var historyError: String?

    // 历史带折叠(方向感知)
    @State private var historyCollapsed = false
    @State private var lastScrollY: CGFloat = 0
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

                // 头部:公历 + 农历 + 流日柱 + 关系 chip + 冲 chip
                DailyFortuneHeaderView(
                    businessDate: businessDate,
                    lunarDate: response.lunarDate,
                    dayPillar: response.dayPillar,
                    dayRelation: response.dayRelationToDayMaster,
                    dayChong: response.dayChong,
                    dayChongTargets: response.dayChongTargets,
                )

                // 宜/忌 main anchor(视觉锚点,非 AI 输出)
                // V1:入框对仗双列居中,宜=墨青 / 忌=淡朱
                YiJiAnchorSection(dayRelation: response.dayRelationToDayMaster)

                // AI 解读(50-80 字 Medium voice)
                DailyInterpretationSection(
                    state: interpretState,
                    remainingReads: vm.remainingReads,
                    nextReset: vm.nextDailyReset,
                    onGenerate: onGenerateInterpret,
                    onRetry: onGenerateInterpret,
                )

                // 明日预告
                TomorrowPreviewSection(preview: response.tomorrowPreview)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
            // 滚动偏移探针(overlay 挂 VStack 顶,不参与 spacing,零布局影响;向下滚动为正值)
            .overlay(alignment: .top) {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: DailyScrollOffsetKey.self,
                        value: -geo.frame(in: .named("dailyScroll")).minY
                    )
                }
                .frame(height: 0)
                .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "dailyScroll")
        .onPreferenceChange(DailyScrollOffsetKey.self) { handleScrollOffset($0) }
        // 历史 pill 带:钉在导航下方(吸顶),方向感知折叠(高度 0 ↔ 自适应)
        .safeAreaInset(edge: .top, spacing: 0) {
            DailyFortuneHistoryView(
                selectedDate: businessDate,
                snapshots: historySnapshots,
                canViewFullHistory: canViewFullHistory,
                onEarlier: { showingHistorySheet = true },
                onSelect: onHistorySelect,
            )
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .background(BaziTheme.paper)
            .frame(maxHeight: historyCollapsed ? 0 : nil, alignment: .top)
            .clipped()
            .opacity(historyCollapsed ? 0 : 1)
            .allowsHitTesting(!historyCollapsed)
            .animation(
                MotionPreferences.animation(.easeInOut(duration: 0.28), reduceMotion: reduceMotion),
                value: historyCollapsed
            )
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

    // MARK: - 方向感知折叠

    /// 滚动方向判定(与 HTML 设计稿同阈值):
    /// - 页顶(y < 8)强制展开
    /// - 向下位移 > 6pt → 收起
    /// - 向上位移 > 6pt → 展开
    private func handleScrollOffset(_ y: CGFloat) {
        if y < 8 {
            if historyCollapsed { historyCollapsed = false }
            lastScrollY = y
            return
        }
        let delta = y - lastScrollY
        if delta > 6 {
            if !historyCollapsed { historyCollapsed = true }
        } else if delta < -6 {
            if historyCollapsed { historyCollapsed = false }
        }
        lastScrollY = y
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
/// V1「三框全载」:入框 + 对仗双列居中——宜(墨青)/ 忌(淡朱)各占一列。
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
        // 今日运势 V1「三框全载」:宜/忌入框,对仗双列居中(参考 daily-fortune-v1.html)
        HStack(spacing: 32) {
            anchorCol(label: L10n.DailyFortune.yiLabel, keyword: resolved.yi, color: BaziTheme.jade)
            anchorCol(label: L10n.DailyFortune.jiLabel, keyword: resolved.ji, color: BaziTheme.cinnabar.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.hairline, lineWidth: 0.5)
        )
    }

    private func anchorCol(label: String, keyword: String, color: Color) -> some View {
        VStack(spacing: 12) {
            Text(label)
                .font(BaziFont.display(size: 30))
                .foregroundStyle(color)
            Text(keyword)
                .bodySerifText(size: 17)
                .tracking(1.4)
                .foregroundStyle(BaziTheme.ink)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 滚动偏移探针

/// ScrollView 滚动偏移(向下为正)。
/// iOS 17.2 无 `onScrollGeometryChange`(iOS 18 API),经典 preference 方案:
/// 0 高度探针放内容顶部,frame 取 named coordinate space 的 minY 取负。
private struct DailyScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
