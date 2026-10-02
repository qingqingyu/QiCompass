import SwiftUI

/// success 态主布局(**2026-10-01 Today 定稿**,事实源 designs/review-fix-20261001/
/// today-final.html @393px,px≈pt 1:1):
/// 头部区(大字日 + 三行 meta + 左对齐 chips,出图上纸面)→ hero 画卡
/// (17pt 边距,落款 + 宜忌字层)→ AI 解读(24pt,无卡片直接排纸面,
/// 2026-09-07 起进入即自动生成)→ 居中页脚 →(时辰未知降级盘)末尾补时辰静默行。
/// 各块 ink-in 错峰入场(mockup .content>* 0/.08/.16/.24s 同款节奏)。
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
            // alignment .leading(2026-10-01 真机截图修复):头部区是本列唯一的
            // 收缩包裹子视图(其余区块都有 maxWidth .infinity 贪宽),VStack 默认
            // .center 会把日期行+chips 整块水平居中(mockup 与 hero 都是左缘对齐)。
            VStack(alignment: .leading, spacing: 0) {
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
                    .padding(.bottom, 10)
                    .background(BaziTheme.ink.opacity(0.05), in: Capsule())
                }

                // ===== 头部区(D3 定稿:信息一行看全,页边距 24)=====
                DailyHeaderSection(
                    businessDate: businessDate,
                    lunarDate: response.lunarDate,
                    dayPillar: response.dayPillar,
                    dayRelation: response.dayRelationToDayMaster,
                    dayChong: response.dayChong,
                    dayChongTargets: response.dayChongTargets,
                )
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .inkIn()

                // ===== hero 画卡(D1/D2 定稿:17pt 边距宽于文本区,chips 下 6pt)=====
                DailyImageHeroSection(
                    dayPillar: response.dayPillar,
                    dayRelation: response.dayRelationToDayMaster,
                )
                .padding(.horizontal, 17)
                .padding(.top, 6)
                .inkIn(delay: 0.08)

                // AI 解读(D5 定稿:无卡片底直接排纸面,页边距 24、hero 下 24;
                // S6 结构化今日洞察:v4 JSON 五段 + 确定性今日信号;2026-09-07 起
                // 进入即自动生成;2026-09-24 失败降级:AI 失败 → 引擎模板文案 +
                // 后台静默重试——降级行与 Retry 不在定稿范围,维持现状)。
                DailyInterpretationSection(
                    state: interpretState,
                    dayRelation: response.dayRelationToDayMaster,
                    dayElements: response.dayElements,
                    daySignal: response.daySignal,
                    signalNote: signalNote,
                    isSilentRetrying: vm.isSilentRetrying,
                    remainingReads: vm.remainingReads,
                    nextReset: vm.nextDailyReset,
                    onGenerate: onGenerateInterpret,
                    onRetry: onGenerateInterpret,
                )
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .inkIn(delay: 0.16)

                // 页脚小注(D4:EN 日柱拼音化;居中、ink-faint、去 hairline)
                heroFootnote
                    .padding(.horizontal, 24)
                    .padding(.top, 26)
                    .inkIn(delay: 0.24)

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
            // D7:页脚滚动到底完整可见——tab 栏由系统 safe area 承担
            // (iOS 26 浮动 tab 实测参与 safe area,2026-09-19 验证),
            // 此处 32pt 为 tab 栏上方的呼吸留白。
            .padding(.bottom, 32)
        }
        .modifier(TodayScrollEdge())
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

    /// 今日信号降级注释(S6):信号空表 = 喜忌不可用时才注释。时辰未知盘
    /// (日柱确定)说「喜忌待补时辰」;hourKnown 且喜忌双空(从格)说
    /// 「特殊格局不下结论」;hourKnown 且喜忌非空但流日五行未命中 = 正常
    /// 无交集(后端 `_day_signal` 对无交集同样返回空表),不编注释只显五行。
    /// dayElements 为 nil(老后端/老快照)时信号行整体隐藏,注释无意义 → nil。
    private var signalNote: String? {
        guard response.dayElements != nil else { return nil }
        guard (response.daySignal ?? []).isEmpty else { return nil }
        if vm.hourGate == .hourUnknownDayDetermined {
            return L10n.DailyFortune.insightNoteHourUnknown
        }
        // 喜忌可用却无交集 → 不是降级,不显示;payload 缺失不臆断从格,同样不显示
        if vm.hasAvailableXiji == false {
            return L10n.DailyFortune.insightNoteSpecialPattern
        }
        return nil
    }

    /// 页脚小注(2026-10-01 定稿):「戊申日 · 偏财 · 解读仅供参照」,
    /// 居中、ink-faint 10.5——**去 hairline 与字距**(mockup .footnote 纯文字,
    /// 全屏字距标签仅解读区 kicker 一处)。
    private var heroFootnote: some View {
        Text(verbatim: Self.footnoteText(
            dayPillar: response.dayPillar,
            relation: response.dayRelationToDayMaster
        ))
        .font(BaziFont.caption(size: 10.5))
        .foregroundStyle(BaziTheme.inkMutedSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 页脚文本(D4):EN = 「Wu-Shen day · Indirect Wealth · For reference
    /// only」——日柱无调拼音连字(EN 基座零汉字);拼音查表 miss 显式回落
    /// 旧「Day of 戊申」形态 + 日志(宁可露中文不猜)。zh/zh-Hant 维持
    /// 「戊申日 · 偏财 · …」。static internal 供 DailyImageHeroCopyTests 的
    /// EN 零 CJK 扫描(免责段走 xcstrings 跟设备语言,测试只钉拼音段)。
    static func footnoteText(
        dayPillar: String,
        relation: String,
        language: AppLanguage = AppLanguage.current
    ) -> String {
        let relationText = BaziTerms.display(relation, language: language)
        if language == .en {
            if let pillar = BaziTerms.romanizedHyphen(dayPillar) {
                return "\(pillar) day · \(relationText) · \(L10n.DailyFortune.disclaimer)"
            }
            AppLogger.app.warning(
                "op=heroFootnote.pinyinMiss dayPillar=\(dayPillar, privacy: .public) -> rawFallback"
            )
            return "Day of \(dayPillar) · \(relationText) · \(L10n.DailyFortune.disclaimer)"
        }
        return "\(dayPillar)\(L10n.DailyFortune.dayPillarSuffix) · \(relationText) · \(L10n.DailyFortune.disclaimer)"
    }
}

// MARK: - iOS 26 底缘滚动边缘效果(2026-10-02 留白修复 §4)

/// Tab 栏下透出正文(2026-10-02 外评「透字显得脏」):iOS 26 浮动 Liquid
/// Glass tab 栏下正文透视属系统默认行为,改用系统滚动边缘效果收底——
/// **不手写 LinearGradient 盖 tab 栏**(DESIGN.md 禁渐变背景,且暗色易穿帮)。
/// 先取 `.hard`(硬边纸色承接);与水墨风格冲突则回退系统默认 `.soft`
/// (方案 §4,截图对比由用户拍板)。部署目标 17.2:#available 之下 17/18
/// 行为不变。其余三个 tab 同病,**本轮只改今日页**,另开任务(方案 §4)。
private struct TodayScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            content
        }
    }
}
