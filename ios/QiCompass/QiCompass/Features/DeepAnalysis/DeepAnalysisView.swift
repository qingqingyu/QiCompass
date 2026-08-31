import SwiftUI
import SwiftData

/// Tab 1:深度解析(状态机根,方案 §一 + DESIGN.md §Color)。
///
/// 主状态机:
/// - .empty / .formInvalid → BirthFormView(2026-08-16 起仅**无存档盘**时兜底:
///   有存档则 resolveArchivedChart 直读 → .ready,对齐 2026-08-01 决策 #4
///   「chart 立即可见 + β 点击触发」;表单新建他人的盘走「我的」Tab)
/// - .calculating(stage) → 分阶段加载文案
/// - .ready(response, _) → DeepAnalysisResultView(AI 子状态独立)
/// - .chartFailed(message) → 原始错误 + 重试
///
/// VM 首次 appear 时用 env.deepAnalysisOrchestrator 创建(@State + .task)。
struct DeepAnalysisView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var vm: DeepAnalysisViewModel?
    /// 存档直读只跑一次(.task 在 TabView 下每次切 Tab 重触发)。兼作表单渲染闸门:
    /// resolve 完成前 .empty 显示「准备中…」,避免表单闪一帧再切 .ready。
    @State private var hasResolvedArchive = false
    /// 当前 .chartFailed 是否源于存档读取失败(区别于 calculate 网络失败)。
    /// 决定 errorView 的「重试」语义:存档失败 → 重跑 resolveArchivedChart;
    /// 排盘失败 → vm.retryCalculation。任何离开错误态的动作都清零(返回表单 /
    /// 重新 resolve),避免残留 flag 误劫持后续 calculate 失败的重试。
    @State private var archiveLoadFailed = false

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                content
            }
            .navigationTitle("深度解析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            #if DEBUG
            .toolbar {
                NavigationLink {
                    SwiftDataCRUDView()
                } label: {
                    Image(systemName: "ladybug")
                        .foregroundStyle(BaziTheme.cinnabar)
                }
            }
            #endif
        }
        .task {
            if vm == nil {
                let newVM = DeepAnalysisViewModel(
                    orchestrator: env.deepAnalysisOrchestrator,
                    entitlementStore: env.entitlementStore
                )
                // 命盘存档后消费 pendingReturnTab:若有则切回原 Tab + 清零。
                // 用 [weak env] 避免持有 EnvironmentObject 生命周期错乱。
                newVM.onChartArchived = { [weak env] in
                    guard let env else {
                        AppLogger.app.error("deepVM.onChartArchived env 已释放,无法消费 pendingReturnTab")
                        return
                    }
                    guard let returnTab = env.pendingReturnTab else {
                        // nil = 用户从深度解析 Tab 直接触发,无切回需求。打 debug 便于排查。
                        AppLogger.app.debug("deepVM.onChartArchived pendingReturnTab=nil,保持当前 Tab")
                        return
                    }
                    env.pendingReturnTab = nil
                    AppLogger.app.info(
                        "deepVM.onChartArchived switch_back tab=\(returnTab.switchKey, privacy: .public)"
                    )
                    NotificationCenter.default.post(
                        name: .switchTab, object: nil,
                        userInfo: ["tab": returnTab.switchKey]
                    )
                }
                vm = newVM
            }
            await resolveArchivedChart()
        }
    }

    /// 从存档直读当前命盘(2026-08-16 改造,落地 2026-08-01 决策 #4 前半句
    /// 「chart 立即可见」):最新 UserSnapshotLink → ChartSnapshot → decode payload
    /// → .ready,免去 onboarding 后重复填表。取盘语义与 DailyFortuneView
    /// .resolveCurrentChart 一致(createdAt 倒序第一条 = 最近一张)。
    ///
    /// 分支:
    /// - 无任何 link → 保持 .empty(BirthFormView 兜底;合盘空态 / 今日运势
    ///   chartMissing CTA 引流都只在无盘时发生,走表单路径不受影响)
    /// - link 有但 ChartSnapshot 缺失 / payload decode 失败 → .chartFailed 显式
    ///   报错(错误显式传播,不静默回落表单;现有 UI 带「返回表单」逃生口)
    @MainActor
    private func resolveArchivedChart() async {
        guard !hasResolvedArchive else { return }
        guard let vm else {
            // 不先置 hasResolvedArchive:vm 缺失时保持闸门开启,下次 .task 重试,
            // 避免 UI 永久卡「准备中…」(防御性顺序,理论不可达)
            AppLogger.app.error("deepView.resolveArchive vm_missing(理论不可达,.task 先建 VM)")
            return
        }
        hasResolvedArchive = true
        archiveLoadFailed = false
        let ctx = env.modelContainer.mainContext
        do {
            // links 取盘刻意与 DailyFortuneView.resolveCurrentChart 同款裸 fetch
            // (createdAt 倒序第一条),不走 UserSnapshotLinkStore.list(userId:):
            // 单方面按 userId 过滤会在登录迁移中间态(link.userId 从 userLocalId
            // 迁到 user_id)与今日运势的取盘语义分叉,两 Tab 判定不一致。
            let links = try ctx.fetch(FetchDescriptor<UserSnapshotLink>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            ))
            guard let link = links.first else {
                AppLogger.app.info("deepView.resolveArchive no_links → 表单兜底")
                return
            }
            // snapshot 查询走 store 抽象(规则 2 hit/miss 日志 + 与 decodeResponse
            // 同源;不裸写 FetchDescriptor 造成一半 store 一半裸查的割裂)
            let snapshotHash = link.snapshotHash
            guard let snapshot = try env.chartSnapshotStore.get(contentHash: snapshotHash) else {
                AppLogger.persistence.error(
                    "op=deepView.resolveArchive snapshot_missing hash=\(snapshotHash, privacy: .public) alias=\(link.alias, privacy: .private)"
                )
                archiveLoadFailed = true
                vm.state = .chartFailed(.generic(message: "命盘存档读取失败,请重新排盘"))
                return
            }
            let response = try env.chartSnapshotStore.decodeResponse(from: snapshot)
            vm.loadArchivedChart(response: response, request: snapshot.archivedDisplayRequest)
        } catch {
            AppLogger.persistence.error(
                "op=deepView.resolveArchive failed error=\(String(describing: error), privacy: .public)"
            )
            archiveLoadFailed = true
            vm.state = .chartFailed(.generic(message: "命盘存档读取失败,请重新排盘"))
        }
    }

    /// 存档读取失败的「重试」:重跑 resolveArchivedChart(而非 vm.retryCalculation —
    /// 存档直读路径下表单字段从未填充,calculate 只会撞 validateForm 落 formInvalid,
    /// 对用户是驴唇不对马嘴的报错)。先 reset 回 .empty + 关闸门,resolve 期间显示
    /// 「准备中…」,重跑结果覆盖状态(成功 → .ready;再失败 → .chartFailed)。
    @MainActor
    private func retryArchiveResolve() {
        archiveLoadFailed = false
        hasResolvedArchive = false
        vm?.reset()
        Task { await resolveArchivedChart() }
    }

    @ViewBuilder
    @MainActor
    private var content: some View {
        if let vm {
            switch vm.state {
            case .empty, .formInvalid:
                // 存档 resolve 完成前显示加载态;resolve 后无盘才落到表单(兜底)
                if hasResolvedArchive {
                    BirthFormView(vm: vm, onSubmit: vm.calculate)
                } else {
                    LoadingStateView(title: "准备中…")
                }
            case .calculating(let stage):
                calculatingView(stage: stage)
            case .ready(let response, _):
                // S07:日柱歧义(late_night 是/不确定或节气边界比对命中)→ 不进内容页,
                // 免费 2 章亦拦(没有日主,S06 降级叙事轴不存在),直接拦截态
                // (与付费墙拦截同款表达)。判据单一事实源 = payload(D5 终态语义)。
                if response.hourUnknownGate == .dayAmbiguous {
                    VStack(spacing: 24) {
                        HourUnknownGateNotice(
                            title: L10n.PaywallGate.dayAmbiguousTitle,
                            reason: L10n.PaywallGate.dayAmbiguousReason
                        )
                        Button(L10n.PaywallGate.backToForm) {
                            vm.reset()
                        }
                        .font(.caption)
                        .foregroundStyle(BaziTheme.cinnabar)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let request = vm.lastRequest {
                    DeepAnalysisResultView(vm: vm, response: response, request: request)
                } else {
                    VStack {
                        Text("数据异常:无请求记录")
                            .foregroundStyle(.red)
                        Button("返回表单") { vm.reset() }
                            .foregroundStyle(BaziTheme.cinnabar)
                    }
                }
            case .chartFailed(let userError):
                // 重试语义按失败来源分派:存档读取失败 → 重跑 resolve;
                // 排盘(calculate)失败 → 重跑网络计算。返回表单时清残留 flag。
                errorView(
                    error: userError,
                    retry: archiveLoadFailed ? retryArchiveResolve : vm.retryCalculation,
                    onBack: {
                        archiveLoadFailed = false
                        vm.reset()
                    }
                )
            }
        } else {
            ProgressView()
                .tint(BaziTheme.cinnabar)
        }
    }

    private func calculatingView(stage: LoadingStage) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(BaziTheme.cinnabar)
            Text(stage.text)
                .font(.body)
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(
        error: UserFacingError,
        retry: @escaping () -> Void,
        onBack: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            ErrorStateView(error: error, retry: retry)
            Button("返回表单", action: onBack)
                .font(.caption)
                .foregroundStyle(BaziTheme.cinnabar)
                .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Shared State Views(四态共用,被 Compatibility/DailyFortune/CRUDView 复用)

/// 四态共用:加载中
struct LoadingStateView: View {
    let title: String
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(BaziTheme.cinnabar)
            Text(title)
                .font(.body)
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 四态共用:空态
struct EmptyStateView: View {
    let title: String
    let subtitle: String
    let ctaTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wind")
                .font(.system(size: 48))
                .foregroundStyle(BaziTheme.ink.opacity(0.4))
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(ctaTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(BaziTheme.onInkDeep)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(BaziTheme.inkDeep, in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 四态共用:成功态卡片
struct SuccessCardView: View {
    let title: String
    let bodyText: String
    let ctaTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 40))
                .foregroundStyle(BaziTheme.jade)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
            Text(bodyText)
                .font(.subheadline)
                .foregroundStyle(BaziTheme.ink)
                .multilineTextAlignment(.center)
            if let ctaTitle, let action {
                Button(action: action) {
                    Text(ctaTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(BaziTheme.onInkDeep)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 12)
                        .background(BaziTheme.inkDeep, in: RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
