import SwiftUI

/// success 态主布局(glass-v2 玻璃全信息卡,2026-08-31 拍板,参考 glass-v2.html):
/// 玻璃 hero(日期+chips+宜忌双列全入图)→ AI 解读 → hairline 小注 →
/// 大留白 → 第二屏(7 日历史带)。明日预告已删(用户拍板:底部日历行去掉)。
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

                // glass-v2 玻璃全信息卡(2026-08-31 拍板):日期区+chips+宜忌双列全部入图,
                // 外部三行头部取消;左右 17pt 边距宽于文本区
                DailyImageHeroSection(
                    businessDate: businessDate,
                    lunarDate: response.lunarDate,
                    dayPillar: response.dayPillar,
                    dayRelation: response.dayRelationToDayMaster,
                    dayChong: response.dayChong,
                    dayChongTargets: response.dayChongTargets,
                )
                .padding(.horizontal, 17)

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

