import SwiftUI
import SwiftData

/// Tab 2:合盘。状态机驱动(结果页主页化,2026-09-29 P1)。
///
/// 状态渲染(§2 映射;VM 枚举 case 不变,只改渲染):
/// - .loading → 命盘列表加载中
/// - .empty → 0 存档,引导去深度解析(P8 不动)
/// - .configuring → 结果壳:名单空 = P5 内联添加表单(提交即合盘,无「开始合盘」
///   按钮);名单非空无已选 = P6 一行说明(点头部选对方);整页配置页已退役(P7)
/// - .computing(completed, total) → 结果壳 + 内容区原地推演态(单选无 i/N)
/// - .list → 结果壳 + 内容区单卡(失败/拦截兜底,单对重试 + 补时辰 CTA)
/// - .detail(summary, response, interpretState) → 结果壳 + CompatibilityMainView
/// - .failed(msg) → 错误态
struct CompatibilityView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var vm: CompatibilityViewModel?
    @State private var showPaywall = false
    /// 与 DailyFortuneView 同因:onboarding 覆盖层下 .task 在建盘前就跑过
    /// (0 存档 → .empty 错误引导);onboarding 完成时 flag 翻 true 重查存档(2026-08-16 修)。
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    // S10 补时辰升级闭环(D7 触点 1 他人盘分支 + 拦截卡 CTA):
    /// 补时辰 sheet VM(nil = 未打开)。
    @State private var addHourVM: AddHourViewModel?
    /// 装配失败的人话文案(alert 显式报错,不静默不开)。
    @State private var addHourError: String?

    // P1-P3 结果壳(2026-09-29 结果页主页化):
    /// 换人 sheet(PartnerPickerSheet;头部对方牌点击开)。
    @State private var showPartnerPicker = false
    /// 换人 sheet 内点无时辰行 → 先关 picker 再开补时辰 sheet(SwiftUI 同源多 sheet
    /// 串行呈现需宿主编排;nil = 无待开)。
    @State private var pendingAddHourHash: String?
    /// 补时辰重算成功后的 old → new hash(供 dismiss 后 `refreshAfterAddHour`
    /// 续接选人/重算;nil = 本轮未发生重算)。
    @State private var addHourRemap: (old: String, new: String)?
    /// 补时辰 sheet 的目标盘(开 sheet 时记录;dismiss 后续接——重算**补时辰
    /// 的那个人**,P1-1 修复 2026-09-30;nil = 未打开过)。
    @State private var addHourTarget: AddHourTarget?
    /// P5:内联表单「称呼」聚焦(点头部占位 = 聚焦称呼,键盘弹起自动滚入视野)。
    @FocusState private var inlineFormAliasFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                content
            }
            // D2(2026-09-29 拍板):四 tab 统一去系统导航标题,防系统字体与水墨层打架。
            // 「编辑名单」toolbar 已随配置页退役(P7,换人/管理全走头部人物牌 + sheet)。
            .sheet(isPresented: $showPaywall) {
                if let compatHash = vm?.lastCompatibilityHashForPaywall {
                    PaywallView(
                        viewModel: PaywallViewModel(
                            module: .compatibility,
                            contentHash: compatHash,
                            purchaseManager: env.purchaseManager,
                            // S07:任一方无时辰 → 付费墙拦截态(判据 = 双方存档 payload;
                            // 拦截对正常进不了 detail,此处与 VM 阶段 2 守卫同源防御)
                            hourUnknownGate: vm?.currentDetailHourUnknownGate ?? .hourKnown,
                            onPurchaseSuccess: {
                                // 购买成功 → dismiss + 重新调该对的解读(决策 D4 按对绑定)
                                showPaywall = false
                                vm?.generateInterpretation()
                            }
                        )
                    )
                }
            }
            // S10:补时辰 sheet(自己盘/他人盘同入口)。关闭统一刷新——
            // 重算换新盘 → 重载存档列表(标记按新 payload 翻转)+ 配置态恢复名单
            /// (roster hash 已 remap,该人带着新盘留在名单,重算即完整对)。
            .sheet(item: $addHourVM, onDismiss: { refreshAfterAddHour() }) { vm in
                AddHourSheet(
                    vm: vm,
                    onCancel: { addHourVM = nil },
                    onRecalculated: { response in
                        // 记 old→new 供 dismiss 后统一处理(refreshAfterAddHour);
                        // 此时 sheet 尚未关,vm(AddHourViewModel)仍持有老盘 hash
                        addHourRemap = (old: vm.snapshot.contentHash, new: response.contentHash)
                    }
                )
            }
            // P2/P3:换人 sheet(结果壳头部对方牌)。行点击 = 关 sheet + 原地换人;
            // 无时辰行 = 先关本 sheet,dismiss 时再开补时辰 sheet(串行呈现)。
            .sheet(isPresented: $showPartnerPicker, onDismiss: {
                if let hash = pendingAddHourHash {
                    pendingAddHourHash = nil
                    openAddHourSheet(hash: hash)
                }
            }) {
                if let vm {
                    PartnerPickerSheet(
                        vm: vm,
                        onPick: { entry in
                            showPartnerPicker = false
                            vm.selectPartner(entry)
                        },
                        onClose: { showPartnerPicker = false },
                        onAddHour: { hash in
                            pendingAddHourHash = hash
                            showPartnerPicker = false
                        }
                    )
                }
            }
            .alert(
                L10n.AddHour.errorAlertTitle,
                isPresented: Binding(
                    get: { addHourError != nil },
                    set: { if !$0 { addHourError = nil } }
                )
            ) {
                Button(L10n.Common.ok, role: .cancel) {}
            } message: {
                Text(addHourError ?? "")
            }
        }
        .task {
            if vm == nil {
                vm = CompatibilityViewModel(
                    orchestrator: env.compatibilityOrchestrator,
                    chartStore: env.chartSnapshotStore,
                    compatibilityStore: env.compatibilitySnapshotStore,
                    entitlementStore: env.entitlementStore,
                    modelContext: env.modelContainer.mainContext
                )
            }
            vm?.loadArchivedCharts()
            // S06:loadArchivedCharts 完成后恢复名单 + 尝试恢复 list 态
            vm?.restoreRosterStateIfAvailable()
        }
        .onChange(of: hasSeenOnboarding) { _, seen in
            // 时序安全:flag 由 RootTabView 在 chart 存档后翻 true,重查时存档必已存在。
            guard seen else { return }
            AppLogger.app.info("compat.onboarding_completed → 重新加载命盘存档")
            vm?.loadArchivedCharts()
        }
    }

    // MARK: - S10 补时辰(装配 + 关闭刷新)

    /// 打开补时辰 sheet(目标 = 参数盘 hash:自己盘或他人盘;装配失败显式 alert)。
    /// 开 sheet 时记录目标盘(`addHourTarget`),dismiss 后据此续接选人(P1-1)。
    @MainActor
    private func openAddHourSheet(hash: String) {
        addHourTarget = (hash == vm?.currentPersonAHash)
            ? .selfChart
            : .partnerChart(hash: hash)
        do {
            addHourVM = try AddHourViewModel.make(
                snapshotHash: hash,
                orchestrator: env.deepAnalysisOrchestrator,
                chartStore: env.chartSnapshotStore,
                linkStore: env.userSnapshotLinkStore
            )
        } catch {
            AppLogger.app.error(
                "op=compatibility.openAddHour failed hash=\(hash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            addHourError = (error as? LocalizedError)?.errorDescription ?? L10n.AddHour.errorRebuild
        }
    }

    /// sheet 关闭统一刷新:重载存档列表(S11 标记按新 payload 翻转)+ 按态分流——
    /// - 配置态:恢复名单(既有行为;list 态不重恢复,避免覆盖当前展示的 summaries)
    /// - 结果壳(P1,detail/list/computing):重算发生过 → 内存 roster remap +
    ///   续接选人(`continueAfterAddHourRemap`):他人盘 = 重算**补时辰的那个人**
    ///   (P1-1 修复 2026-09-30,此前无条件重算当前对方),自己盘 = 当前对强制
    ///   重算;无当前对方(恢复失败/刚移出)不自动选人,回头部点选
    @MainActor
    private func refreshAfterAddHour() {
        vm?.loadArchivedCharts()
        if case .configuring = vm?.state {
            // 配置态从(已 remap 的)持久化重建名单,内存 remap 无必要;
            // 残留 remap/target 必须清掉,防下轮结果壳态误用陈旧映射/目标
            let remap = addHourRemap
            let target = addHourTarget
            addHourRemap = nil
            addHourTarget = nil
            vm?.restoreRosterStateIfAvailable()
            if let remap {
                vm?.continueAfterAddHourRemap(target: target, remap: remap)
            }
            return
        }
        guard let remap = addHourRemap else {
            addHourTarget = nil
            return
        }
        addHourRemap = nil
        let target = addHourTarget
        addHourTarget = nil
        vm?.applyHashRemap(from: remap.old, to: remap.new)
        vm?.continueAfterAddHourRemap(target: target, remap: remap)
    }

    @ViewBuilder
    private var content: some View {
        if let vm {
            switch vm.state {
            case .loading:
                LoadingStateView(title: String(localized: "准备中…"))
            case .empty:
                CompatibilityEmptyView {
                    // 设返回标志,深度解析完成后 DeepAnalysisView 据此切回合盘
                    env.pendingReturnTab = .compatibility
                    NotificationCenter.default.post(
                        name: .switchTab, object: nil,
                        userInfo: ["tab": RootTabView.Tab.deepAnalysis.switchKey]
                    )
                }
            case .configuring:
                // S3(P5/P6):结果壳接管配置态——名单空 = 内联表单(提交即合盘,
                // 不再有「开始合盘」按钮与空名单页);非空无已选 = 一行说明。
                // 整页 CompatibilityConfigView 不再渲染(P7)。
                resultShell(
                    vm: vm,
                    onTapPartner: configuringHeaderTap(vm: vm)
                ) {
                    configuringContent(vm: vm)
                }
            case .computing:
                // P1 §2:结果壳 + 内容区原地推演态(三墨点 breathe;单选恒 1 对,
                // i/N 无信息量不渲染;不再全屏跳页)
                resultShell(vm: vm) {
                    InlineCastingIndicator()
                }
            case .list:
                // P1 §2:结果壳 + 内容区单卡(失败/拦截兜底;重试与补时辰 CTA 复用
                // PairSummaryCard 既有布局与回调)
                resultShell(vm: vm) {
                    listContent(vm: vm)
                }
            case .detail(let summary, let response, let interpretState):
                // 复用 CompatibilityMainView,入参从当前对快照构造
                // (2026-09-27 起注入 nameA/nameB 称呼,见下方)。
                resultShell(vm: vm) {
                    if let chartA = vm.currentDetailASnapshot,
                       let chartB = vm.currentDetailBSnapshot {
                        CompatibilityMainView(
                            vm: vm,
                            response: response,
                            interpretState: interpretState,
                            chartASnapshot: chartA,
                            chartBSnapshot: chartB,
                            // 2026-09-27 A/B 代号 → 名字:A 恒命主本人「你」,B 用对方称呼
                            nameA: L10n.Compatibility.selfReferenceYou,
                            nameB: summary.displayName,
                            onBackToConfig: { vm.clearDetailKeepRoster() },
                            onGenerateInterpret: { vm.generateInterpretation() },
                            onShowPaywall: { showPaywall = true }
                        )
                        // S4 换人动效:内容因对方变化(compatibilityHash 变)重建时
                        // ink-in(opacity 0→1 + blur 7→0);同对 interpretState 变化
                        // hash 不变不重建。冷启动恢复/首次出结果经 onAppear 同播;
                        // 推演态 → 结果态之间无额外转场。reduce-motion 直出。
                        .id(summary.compatibilityHash)
                        .inkIn()
                    } else {
                        // 不静默吞:detail 态但快照缺失 → 显式错误态
                        ErrorStateView(
                            userFacingError: .generic(message: L10n.Compatibility.errorChartReadFailed),
                            retry: { vm.clearDetailKeepRoster() }
                        )
                    }
                }
            case .failed(let userError):
                ErrorStateView(
                    userFacingError: userError,
                    retry: { vm.loadArchivedCharts() }
                )
            }
        } else {
            ProgressView().tint(BaziTheme.cinnabar)
        }
    }
}

// MARK: - switchTab Notification

extension Notification.Name {
    /// 切 Tab 通知(rawValue 唯一命名,决策 D1 / 风险 #4)。
    /// userInfo: ["tab": "deepAnalysis" / "compatibility" / "dailyFortune"]
    static let switchTab = Notification.Name("com.qicompass.switchTab")
}

// MARK: - P1 结果壳(2026-09-29 结果页主页化)

extension CompatibilityView {

    /// 结果壳:顶部人物牌头(PartnerHeader)+ 下方内容区。
    /// computing / list / detail / configuring 四态共用——全部原地呈现,不跳页(P1)。
    /// 头部对方牌点击默认开换人 sheet(configuring 空名单时改为聚焦内联表单,
    /// 经 onTapPartner 覆盖)。
    @ViewBuilder
    func resultShell<Content: View>(
        vm: CompatibilityViewModel,
        onTapPartner: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            PartnerHeader(
                me: vm.currentSelfDisplay,
                partner: vm.currentPartner,
                rosterIsEmpty: vm.roster.isEmpty,
                isSelfHourUnknown: vm.isSelfHourUnknown,
                onTapPartner: onTapPartner ?? { showPartnerPicker = true },
                onAddSelfHour: {
                    guard let aHash = vm.currentPersonAHash else { return }
                    openAddHourSheet(hash: aHash)
                },
                stampID: vm.currentPartner?.entryID ?? ""
            )
            content()
        }
    }

    /// P5 头部占位点击:聚焦内联表单「称呼」(键盘弹起自动滚入视野,不开 sheet;
    /// 名单非空回落开 sheet——P6 语义)。
    private func configuringHeaderTap(vm: CompatibilityViewModel) -> () -> Void {
        if vm.roster.isEmpty {
            return { inlineFormAliasFocused = true }
        }
        return { showPartnerPicker = true }
    }

    /// configuring 态内容区(P5 / P6):
    /// - 名单空(P5):留白说明 + 命主无时辰 banner + 内联 PartnerBirthForm
    ///   (提交 = 加入 + 选中 + 合盘;点头部占位聚焦称呼)
    /// - 有选中但无缓存(R3,2026-09-30):头部显示该人,内容区一行说明 +
    ///   「重新合盘」入口(selectPartner(force:)——缓存命中态不会走到这里,
    ///   恢复已直达 detail;不自动发请求)
    /// - 名单非空无已选(P6):一行 inkMuted 说明,点头部开 sheet,不自动弹
    /// - 命主无时辰:表单按 S07 全锁语义置灰(先补时辰再解锁)
    @ViewBuilder
    private func configuringContent(vm: CompatibilityViewModel) -> some View {
        if vm.roster.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
                    Text(L10n.CompatibilityPartner.p5Intro)
                        .font(BaziFont.caption(size: 11.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMuted)
                        .padding(.top, BaziTheme.Spacing.xl)
                    if vm.isSelfHourUnknown {
                        RosterSelfLockBanner()
                    }
                    PartnerBirthForm(
                        vm: vm,
                        onAdded: { entry in
                            // P5:提交 = 加入 + 选中 + 合盘(与 sheet 内 P4 同语义)
                            vm.selectPartner(entry)
                        },
                        footnote: L10n.CompatibilityPartner.formFootnoteAdd,
                        aliasFocus: $inlineFormAliasFocused
                    )
                    .disabled(vm.isSelfHourUnknown)
                }
                .padding(.horizontal, BaziTheme.Spacing.lg)
                .padding(.bottom, 32)
            }
        } else if let selected = vm.selectedRosterEntries.first {
            // R3 有选中无缓存(恢复未命中 / 上次合盘失败):不自动发请求,
            // 给显式入口——selectPartner force 绕过「已是当前对方」no-op
            VStack(spacing: BaziTheme.Spacing.lg) {
                Spacer()
                Text(L10n.CompatibilityPartner.selectedNoCacheHint)
                    .font(BaziFont.caption(size: 12))
                    .tracking(1.5)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Button {
                    vm.selectPartner(selected, force: true)
                } label: {
                    Text(L10n.CompatibilityPartner.recomputeCta)
                        .font(BaziFont.body(size: 15))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.ink)
                        .padding(.horizontal, BaziTheme.Spacing.xl)
                        .padding(.vertical, 10)
                        .overlay(
                            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                                .stroke(BaziTheme.hairline, lineWidth: 1)
                        )
                }
                .disabled(vm.isSelfHourUnknown)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                Spacer()
                Text(L10n.CompatibilityPartner.p6Hint)
                    .font(BaziFont.caption(size: 12))
                    .tracking(1.5)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// list 态内容区:单对卡(成功卡可点开 detail;失败卡单对重试;拦截卡补时辰
    /// CTA——三分支与 PairSummaryCard 既有形态一致,结果壳内联)。
    @ViewBuilder
    private func listContent(vm: CompatibilityViewModel) -> some View {
        ScrollView {
            VStack(spacing: BaziTheme.Spacing.md) {
                ForEach(vm.summaries) { summary in
                    if summary.isComputed {
                        Button {
                            vm.openDetail(summary)
                        } label: {
                            PairSummaryCard(
                                summary: summary,
                                isRetrying: false,
                                onRetry: {}
                            )
                        }
                        .buttonStyle(.plain)
                    } else if summary.isHourUnknownBlocked {
                        PairSummaryCard(
                            summary: summary,
                            isRetrying: false,
                            onRetry: {},
                            onAddHour: vm.addHourTargetHash(forBlockedPair: summary)
                                .map { hash in { openAddHourSheet(hash: hash) } }
                        )
                    } else {
                        PairSummaryCard(
                            summary: summary,
                            isRetrying: vm.retryingIds.contains(summary.id),
                            onRetry: { vm.retryPair(summary: summary) }
                        )
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, BaziTheme.Spacing.md)
            .padding(.bottom, 32)
        }
    }
}

// MARK: - P1 内联推演态(computing;单选无 i/N)

/// 结果壳内容区推演态:竖排短语 + 三墨点 breathe(沿用旧全屏推演态的动效语言,
/// 去 i/N 与全屏布局)。reduce-motion 静态呈现(DESIGN.md 动效全降级)。
private struct InlineCastingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private static let dotsBreathing: [Double] = [0.35, 0.65, 1.0]
    private static let dotsStatic: [Double] = [1.0, 0.5, 0.22]

    var body: some View {
        VStack(spacing: 22) {
            VText(phrase: L10n.CompatibilityPartner.castingTitle, size: 19, tracking: 8)
            HStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { idx in
                    Circle()
                        .fill(BaziTheme.inkDeep)
                        .frame(width: 8, height: 8)
                        .opacity(breathing ? Self.dotsBreathing[idx] : Self.dotsStatic[idx])
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.CompatibilityPartner.castingTitle)
    }
}
