import SwiftUI

/// success 态主布局(glass-v2 玻璃全信息卡,2026-08-31 拍板,参考 glass-v2.html):
/// 玻璃 hero(日期+chips+宜忌双列全入图)→ AI 解读(2026-09-07 起进入即自动生成)
/// → hairline 小注 →(时辰未知降级盘)末尾补时辰静默行。
///
/// 2026-09-07 历史回看拔除(用户拍板「底部日期选择完全没必要」):
/// - 第二屏 7 日日期带 + 「更早」锁框 + 历史回看 sheet + 付费墙接线全部移除,
///   今日 tab 转为纯免费(MONETIZATION.md §每日运势历史回看 同步删节)
/// - `EntitlementStore.hasAnyActivePurchase` 唯一调用方(本文件的
///   refreshUnlockState)已随历史回看代码移除,该方法无存留调用方,同步删除
///
/// 不直接接 state machine,由 DailyFortuneView 切换后传入。
struct DailyFortuneMainView: View {
    @Bindable var vm: DailyFortuneViewModel
    let response: DailyFortuneResponse
    let interpretState: InterpretState
    let businessDate: Date
    let chartHash: String?
    let ziHourRule: String
    let onRefresh: () -> Void
    let onGenerateInterpret: () -> Void
    /// S10 补时辰触点(D7 触点 2):末尾静默行点击 → 打开补时辰 sheet(宿主
    /// DailyFortuneView 注入)。静默行不是弹窗,是可点的一行文字。
    let onAddHour: () -> Void

    init(
        vm: DailyFortuneViewModel,
        response: DailyFortuneResponse,
        interpretState: InterpretState,
        businessDate: Date,
        chartHash: String?,
        ziHourRule: String,
        onRefresh: @escaping () -> Void,
        onGenerateInterpret: @escaping () -> Void,
        onAddHour: @escaping () -> Void,
    ) {
        self._vm = Bindable(wrappedValue: vm)
        self.response = response
        self.interpretState = interpretState
        self.businessDate = businessDate
        self.chartHash = chartHash
        self.ziHourRule = ziHourRule
        self.onRefresh = onRefresh
        self.onGenerateInterpret = onGenerateInterpret
        self.onAddHour = onAddHour
    }

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

                // AI 解读(50-80 字 Medium voice;2026-09-07 起进入即自动生成)。
                // 边距 17pt 与 hero 卡对齐(同日用户拍板:两框线必须左右对齐)。
                DailyInterpretationSection(
                    state: interpretState,
                    remainingReads: vm.remainingReads,
                    nextReset: vm.nextDailyReset,
                    onGenerate: onGenerateInterpret,
                    onRetry: onGenerateInterpret,
                )
                .padding(.horizontal, 17)

                // hairline 小注:干支 · 十神 · 免责
                heroFootnote
                    .padding(.horizontal, 17)
                    .padding(.top, 18)

                // S10 接线(D7 触点 2,「一行文字,不是弹窗」):仅时辰未知·日柱
                // 确定的降级版展示(判据 = vm.hourGate,单一事实源),点击进补时辰
                // sheet。静默态(「我确实不知道」)行保留可点击、文案降中性——
                // 入口在,提示不在。
                if vm.hourGate == .hourUnknownDayDetermined {
                    Button {
                        HapticEngine.light()
                        onAddHour()
                    } label: {
                        Text(vm.isHourUnknownAccepted
                             ? L10n.DailyFortune.degradedHintSilent
                             : L10n.DailyFortune.degradedHint)
                            .font(BaziFont.caption(size: 10.5))
                            .tracking(1)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(BaziTheme.inkMutedSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.top, 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.DailyFortune.degradedHint)
                }
            }
            .padding(.bottom, 32)
        }
        .refreshable { onRefresh() }
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
}
