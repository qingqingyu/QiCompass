import SwiftUI
import SwiftData

/// "我的" Tab(2026-08-01 grill-me 决策 #17 新增的第 4 个 Tab)。
///
/// v1 无账号系统,内容含 4 个 section(详见 issue #3 + STRATEGIC_DIFF.md §iOS App 入口):
/// 1. **我的命盘**:UserSnapshotLink list("我自己" / "妈妈" / "男友" 等 alias)
/// 2. **已购**:active Entitlement list(按 purchasedAt DESC)
/// 3. **设置**:zi_hour_rule default(子时规则,后续 BirthFormView 读取作为默认值)
/// 4. **关于**:app 版本 + build 号
///
/// 退化态:无命盘/无 entitlements 时显示 placeholder 文案,不报错(状态显式表达)。
struct ProfileView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Query(sort: \UserSnapshotLink.createdAt, order: .reverse)
    private var snapshotLinks: [UserSnapshotLink]

    @Query(sort: \Entitlement.purchasedAt, order: .reverse)
    private var entitlements: [Entitlement]

    /// 子时规则默认值。BirthFormView 后续 slice 起手读此 @AppStorage 作为初始值。
    /// 默认 zi_next_day(对齐 CLAUDE.md 项目约束 + 既有 DeepAnalysisViewModel 默认值)。
    @AppStorage("defaultZiHourRule") private var defaultZiHourRule = "zi_next_day"

    // MARK: v2 PR1 多人命盘管理 UI state

    /// 新建命盘 sheet(弹 BirthFormView)。
    @State private var showNewChartSheet = false
    /// 新建命盘用临时 VM(独立于 DeepAnalysisView 的 VM,避免相互污染)。
    @State private var newChartVM: DeepAnalysisViewModel?
    /// 待删 link(swipe 触发 → confirmationDialog 二次确认)。
    @State private var linkToDelete: UserSnapshotLink?
    /// 待编辑 link(swipe 触发 → 弹 AliasEditView)。
    @State private var linkToEdit: UserSnapshotLink?

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                List {
                    accountSection
                    snapshotLinksSection
                    entitlementsSection
                    settingsSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
                .background(BaziTheme.paper)
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            .sheet(isPresented: $showNewChartSheet) {
                newChartSheet
            }
            .sheet(item: $linkToEdit) { link in
                AliasEditView(initialAlias: link.alias) { newAlias in
                    saveAlias(linkId: link.id, newAlias: newAlias)
                }
            }
            .confirmationDialog(
                "确认删除「\(linkToDelete?.alias ?? "")」?",
                isPresented: Binding(
                    get: { linkToDelete != nil },
                    set: { if !$0 { linkToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let link = linkToDelete {
                        deleteLink(linkId: link.id)
                    }
                    linkToDelete = nil
                }
                Button("取消", role: .cancel) {
                    linkToDelete = nil
                }
            } message: {
                Text("命盘数据会保留(历史解读可回溯),仅从此列表移除。")
            }
        }
    }

    // MARK: - Section 0: 账号(v2 PR2)

    private var accountSection: some View {
        Section {
            switch env.accountManager.state {
            case .loading:
                Text("加载中…")
                    .foregroundStyle(BaziTheme.inkMuted)
            case .signedOut:
                AppleSignInButton { result in
                    env.accountManager.handleAuthorization(result)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(BaziTheme.paper)
            case .signedIn(let user):
                VStack(alignment: .leading, spacing: 4) {
                    Text(user.fullName ?? user.email ?? "Apple 用户")
                        .foregroundStyle(BaziTheme.ink)
                    if let email = user.email, user.fullName != nil {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(BaziTheme.inkMuted)
                    }
                    Text("Apple ID:\(user.appleUserId.prefix(12))")
                        .font(.caption2.monospaced())
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                Button("退出登录", role: .destructive) {
                    env.accountManager.signOut()
                }
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.destructive)
                    AppleSignInButton { result in
                        env.accountManager.handleAuthorization(result)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(BaziTheme.paper)
                }
            }
        } header: {
            sectionHeader("账号")
        }
    }

    // MARK: - Section 1: 我的命盘

    private var snapshotLinksSection: some View {
        Section {
            if snapshotLinks.isEmpty {
                Text("还没有命盘")
                    .foregroundStyle(BaziTheme.inkMuted)
            } else {
                ForEach(snapshotLinks) { link in
                    HStack {
                        Text(link.alias)
                            .foregroundStyle(BaziTheme.ink)
                        Spacer()
                        Text(String(link.snapshotHash.prefix(8)))
                            .font(.caption.monospaced())
                            .foregroundStyle(BaziTheme.inkMuted)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            linkToDelete = link
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            linkToEdit = link
                        } label: {
                            Label("改名", systemImage: "pencil")
                        }
                        .tint(BaziTheme.daiBlue)
                    }
                }
            }
        } header: {
            HStack {
                sectionHeader("我的命盘")
                Spacer()
                Button {
                    openNewChartSheet()
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(BaziTheme.cinnabar)
                }
                .accessibilityLabel("新建命盘")
            }
        }
    }

    // MARK: - v2 PR1 操作

    /// 弹新建命盘 sheet,初始化临时 VM(用户取消/完成会自动释放)。
    private func openNewChartSheet() {
        let vm = DeepAnalysisViewModel(
            orchestrator: env.deepAnalysisOrchestrator,
            entitlementStore: env.entitlementStore
        )
        // 默认 alias "我自己" 由 VM 自带,用户可在表单 TextField 改
        newChartVM = vm
        showNewChartSheet = true
    }

    /// 新建命盘 sheet 内容:BirthFormView + 监听 VM.state 变化(ready 时 dismiss)。
    @ViewBuilder
    private var newChartSheet: some View {
        if let vm = newChartVM {
            NavigationStack {
                BirthFormView(vm: vm, onSubmit: vm.calculate)
                    .navigationTitle("新建命盘")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("取消") {
                                newChartVM = nil
                                showNewChartSheet = false
                            }
                            .foregroundStyle(BaziTheme.cinnabar)
                        }
                    }
            }
            .onChange(of: vm.state) { _, newState in
                if case .ready = newState {
                    // 排盘成功 → link 已写入 → 关 sheet(@Query 自动刷新 list)
                    AppLogger.app.info("profile.newChart.ready alias=\(vm.alias, privacy: .public) — dismiss sheet")
                    newChartVM = nil
                    showNewChartSheet = false
                }
            }
        }
    }

    private func deleteLink(linkId: UUID) {
        do {
            try env.userSnapshotLinkStore.delete(linkId: linkId)
            // @Query 自动刷新 list,无需手动处理
        } catch {
            AppLogger.persistence.error(
                "op=profile.deleteLink failed linkId=\(linkId, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func saveAlias(linkId: UUID, newAlias: String) {
        do {
            try env.userSnapshotLinkStore.updateAlias(linkId: linkId, newAlias: newAlias)
            // @Query 自动刷新 list
        } catch {
            AppLogger.persistence.error(
                "op=profile.saveAlias failed linkId=\(linkId, privacy: .public) newAlias=\(newAlias, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Section 2: 已购

    private var entitlementsSection: some View {
        Section {
            let activeEntitlements = entitlements.filter { $0.isActive }
            if activeEntitlements.isEmpty {
                Text("还没有购买")
                    .foregroundStyle(BaziTheme.inkMuted)
            } else {
                ForEach(activeEntitlements) { ent in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(for: ent.module))
                            .foregroundStyle(BaziTheme.ink)
                        HStack {
                            Text("购买于")
                            Text(ent.originalPurchaseDate, format: .dateTime.year().month().day())
                        }
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                    }
                }
            }
        } header: {
            sectionHeader("已购")
        }
    }

    // MARK: - Section 3: 设置

    private var settingsSection: some View {
        Section {
            Picker("子时规则默认", selection: $defaultZiHourRule) {
                Text("子时属次日(23:00 换日)").tag("zi_next_day")
                Text("早晚子时(00:00 换日)").tag("zero_oclock")
            }
            .foregroundStyle(BaziTheme.ink)
        } header: {
            sectionHeader("设置")
        } footer: {
            Text("影响新表单的初始值。已存档命盘不受影响(其规则随 snapshot 持久化)。")
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    // MARK: - Section 4: 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: appVersion)
            LabeledContent("Build", value: buildNumber)
        } header: {
            sectionHeader("关于")
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(BaziTheme.inkMuted)
            .textCase(nil)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    private func displayName(for module: String) -> String {
        switch module {
        case "bazi_deep":     return "深度解析"
        case "compatibility": return "合盘"
        default:              return module
        }
    }
}
