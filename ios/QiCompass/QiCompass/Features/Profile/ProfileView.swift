import SwiftUI
import SwiftData

/// "我的" Tab(2026-08-01 grill-me 决策 #17 新增的第 4 个 Tab)。
///
/// v1 无账号系统,内容含 4 个 section + 命主卡(2026-08-10 阶段 6 新增):
/// 0. **命主卡**(Q16 δ + Q17):生肖图 + alias + 出生年 + 今日 anchor
/// 1. **我的命盘**:UserSnapshotLink list("我自己" / "妈妈" / "男友" 等 alias)
/// 2. **已购**:active Entitlement list(按 purchasedAt DESC)
/// 3. **设置**:zi_hour_rule default + 重置命盘按钮(Q20 B fallback)
/// 4. **关于**:app 版本 + build 号
///
/// 退化态:无命盘/无 entitlements 时显示 placeholder 文案,不报错(状态显式表达)。
struct ProfileView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Query(sort: \UserSnapshotLink.createdAt, order: .reverse)
    private var snapshotLinks: [UserSnapshotLink]

    @Query(sort: \Entitlement.purchasedAt, order: .reverse)
    private var entitlements: [Entitlement]

    /// 命主卡需要 ChartSnapshot 取 birthSolarTime / gender 推生肖(Q16 δ + Q17)。
    @Query
    private var chartSnapshots: [ChartSnapshot]

    /// 重置命盘清空所有 SwiftData model(Q20 B)。
    @Environment(\.modelContext) private var context

    /// 重置命盘二次确认 alert 触发。
    @State private var showResetConfirm = false

    /// 重置命盘失败时显示的错误 alert 文案(CLAUDE.md 错误显式传播:不静默吞)。
    @State private var resetError: String?

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

    /// onboarding flag(RootTabView 用同 key 监听 onboarding sheet 触发)。
    /// 用 @AppStorage 而非 UserDefaults.standard 让 RootTabView 立即响应(避免 1 runloop 同步延迟)。
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                List {
                    if let primary = primarySnapshot,
                       let zodiacAssetName = primaryZodiacAssetName {
                        let birthYear = Calendar.current.component(.year, from: primary.snapshot.birthSolarTime)
                        Section {
                            IdentityCard(
                                zodiacAssetName: zodiacAssetName,
                                alias: primary.link.alias,
                                birthYear: birthYear
                            )
                            .listRowInsets(EdgeInsets(top: BaziTheme.Spacing.sm, leading: BaziTheme.Spacing.md, bottom: BaziTheme.Spacing.sm, trailing: BaziTheme.Spacing.md))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
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
            // 双 .alert 修饰符:iOS 17.2+ 原生支持(部署目标满足)。
            // showResetConfirm 与 resetError 不会同时为 true(确认 alert dismiss 后才同步执行 resetAllData)。
            // resetError 赋值用 Task { @MainActor } 延迟一帧(见 resetAllData catch 分支),
            // 规避 iOS 17 连续两个 alert 在同一 runloop 内呈现被吞掉(经验性 workaround,非契约保证)。
            .alert("确定要清空所有命盘和解读记录吗?", isPresented: $showResetConfirm) {
                Button("取消", role: .cancel) {}
                Button("确定重置", role: .destructive) { resetAllData() }
            } message: {
                Text("此操作不可恢复。所有命盘、合盘记录、解读缓存都会被清空。购买记录保留在 App Store,重新 onboarding 后可恢复。")
            }
            .alert("重置失败", isPresented: Binding(
                get: { resetError != nil },
                set: { newValue in if !newValue { resetError = nil } }
            )) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(resetError ?? "")
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

    // MARK: - Section 0: 命主卡数据

    /// 命主卡主 snapshot(最新 UserSnapshotLink + 对应 ChartSnapshot)。
    /// v1 单用户,snapshotLinks.first 即"我自己"。userId 字段为 v2 多用户 UI 预留,此处不参与过滤
    /// (v2 实现 multi-user 时,需先取 `UserIdentity.current` 再 filter `link.userId == current`)。
    private var primarySnapshot: (link: UserSnapshotLink, snapshot: ChartSnapshot)? {
        guard let link = snapshotLinks.first,
              let snap = chartSnapshots.first(where: { $0.contentHash == link.snapshotHash }) else {
            return nil
        }
        return (link, snap)
    }

    /// 命主卡生肖图 asset name(从 ChartSnapshot.payload decode BaziResponse 取 yearBranchZodiac)。
    ///
    /// 数据源(2026-08-11 wire up):后端 lunar_python 已按立春算 year_branch_zodiac,
    /// 修客户端公历年推算的立春边界 bug(1-2 月初立春前用户生肖差 1 年)。
    ///
    /// **错误处理**:decode 失败返回 nil(对齐"错误显式传播" — decode 失败的具体 error 已由
    /// `ChartSnapshotStore.decodeResponse` 内部 Logger.error 记录,这里返回 nil 让 UI 隐藏命主卡
    /// section,而非显示错图或 crash)。生产环境 decode 失败极少(仅 schema 不兼容时,
    /// 当前 schema_version=1 未演化过)。
    private var primaryZodiacAssetName: String? {
        guard let primary = primarySnapshot else { return nil }
        do {
            let response = try env.chartSnapshotStore.decodeResponse(from: primary.snapshot)
            return "Zodiac_\(response.yearBranchZodiac)"
        } catch {
            // error 已在 ChartSnapshotStore.decodeResponse 内 Logger.error,这里不重复记
            return nil
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
                    // PR3.2:新建命盘后 push(同步到云端)
                    Task { await env.syncManager.push() }
                }
            }
        }
    }

    private func deleteLink(linkId: UUID) {
        do {
            try env.userSnapshotLinkStore.delete(linkId: linkId)
            // @Query 自动刷新 list,无需手动处理
            // PR3.2:删除后 push(同步到云端)
            Task { await env.syncManager.push() }
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
            // PR3.2:改名后 push(同步到云端)
            Task { await env.syncManager.push() }
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

            // Q20 B:重置命盘 fallback。用户输错生日时清空所有数据重新 onboarding。
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Text("重置命盘")
            }
        } header: {
            sectionHeader("设置")
        } footer: {
            Text("影响新表单的初始值。已存档命盘不受影响(其规则随 snapshot 持久化)。重置命盘会清空所有数据并重新走 onboarding。")
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    // MARK: - Section 4: 关于

    /// 2026-08-13 onboarding 三屏重构(Q1 拆分下沉):
    /// 立场/隐私完整版(原 onboarding 第 2/3 页)移到这里。
    /// onboarding 里只留关键时刻微文案(表单页隐私一行 / 反馈屏立场一行)。
    private var aboutSection: some View {
        Section {
            // 立场(为什么可信 — Memorable Thing "专业不忽悠"的完整落点)
            Text(L10n.Profile.aboutStanceTitle)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            ForEach(
                [L10n.Profile.aboutStance1, L10n.Profile.aboutStance2, L10n.Profile.aboutStance3],
                id: \.self
            ) { line in
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(BaziTheme.ink)
            }
            // 隐私与数据(完整版)
            Text(L10n.Profile.aboutPrivacyTitle)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            ForEach(
                [L10n.Profile.aboutPrivacy1, L10n.Profile.aboutPrivacy2, L10n.Profile.aboutPrivacy3],
                id: \.self
            ) { line in
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(BaziTheme.ink)
            }
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

    /// Q20 B:重置命盘 — 清空所有 SwiftData @Model + 重置 onboarding flag。
    /// 用户重新打开 app 走 onboarding 流程。
    /// 购买记录保留在 StoreKit App Store,不在 SwiftData 范围,重新 onboarding 后恢复。
    /// InterpretState 是 ViewModel UI enum(非 PersistentModel),不在删除范围。
    /// 用 fetch + loop delete 范式(与 UserSnapshotLinkStore / DailyFortuneSnapshotStore 一致,
    /// SwiftData batch `delete(T.self)` 在当前 Swift 编译器推断失败)。
    ///
    /// **失败处理**(CLAUDE.md 错误显式传播):catch 回滚 pending changes,
    /// 不设 hasSeenOnboarding,弹错误 alert 让用户知道操作没成功。
    ///
    /// **已知 sync 缺口**:已登录用户重置后重新走完 onboarding,下次 App 启动时
    /// RootTabView.onAppear 的 syncManager.pull() 会从云端拉回老命盘。
    /// 后端 sync_push 是 UPSERT-only(无 delete endpoint),客户端无法单方面清空云端。
    /// TODO(后端):加 DELETE /api/sync 或 sync_push 改 diff 语义。
    /// 暂不阻断本功能:v1 sync 后端尚未上线生产,且重置是低频操作。
    private func resetAllData() {
        do {
            // 显式逐类型 fetch + delete(对齐项目其他 Store 范式)
            try fetchAndDeleteAll(UserSnapshotLink.self)
            try fetchAndDeleteAll(ChartSnapshot.self)
            try fetchAndDeleteAll(CompatibilitySnapshot.self)
            try fetchAndDeleteAll(DailyFortuneSnapshot.self)
            try fetchAndDeleteAll(Entitlement.self)
            try fetchAndDeleteAll(InterpretationCache.self)
            try context.save()
            // 用 @AppStorage 写,RootTabView 的 @AppStorage("hasSeenOnboarding") 立即响应触发 onboarding sheet
            hasSeenOnboarding = false
            AppLogger.app.info("重置命盘完成,hasSeenOnboarding=false,RootTabView 应立即弹 onboarding sheet")
            // 不调 syncManager.push():本地命盘已全删,push 收集到空列表。
            // 后端 sync_push 是 UPSERT-only(无 delete endpoint),空 push 是 no-op,不会清云端。
            // 已知缺口见上方注释,TODO(后端):加 DELETE /api/sync 或 sync_push 改 diff 语义后,
            // 在此处(以及 pull 逻辑)补 push 调用。
        } catch {
            // 失败回滚 pending changes,避免部分 delete 标记残留导致脏状态
            context.rollback()
            AppLogger.app.error("重置命盘失败: \(error)")
            // 向用户显式报错,不静默吞。
            // 延迟一帧赋值:iOS 17 在同一 runloop 内连续呈现两个 alert(确认 alert dismiss → 错误 alert present)
            // 可能被吞掉。Task { @MainActor in } 让出当前 runloop,经实证可规避此问题。
            // 注意:这不是 SwiftUI 契约保证,而是 iOS 17 实测有效的经验性 workaround。
            let msg = "重置未完成,数据未变更。原因:\(error.localizedDescription)"
            Task { @MainActor in
                resetError = msg
            }
        }
    }

    /// 通用 helper:fetch 所有 instance + 逐个 delete。
    /// 对齐项目其他 Store(UserSnapshotLinkStore / DailyFortuneSnapshotStore)的 instance-based 删除范式。
    private func fetchAndDeleteAll<T: PersistentModel>(_ type: T.Type) throws {
        let instances = try context.fetch(FetchDescriptor<T>())
        for instance in instances {
            context.delete(instance)
        }
    }
}

// MARK: - IdentityCard(命主卡)

/// Q16 δ + Q17:ProfileView 顶部命主卡。
///
/// **阶段 6 简化版**(2026-08-10):
/// 当前实现 = 印章图 + alias + 出生年 + 跳转今日 anchor。
///
/// TODO(spec Q11 β mockup + Q17 完整版,后续 slice 补):
/// - **真太阳时行**:数据可得(ChartSnapshot.birthSolarTime 格式化),接口需扩展
/// - **出生地行**:数据不可得 — ChartSnapshot 当前只有 `cityLongitude: Double`(没城市名字符串),
///   需 SwiftData schema 变更加 `city: String?` 字段 + migration
/// - **今日宜/忌一句话 anchor**:需 query DailyFortuneSnapshot 跨模块解码宜/忌内容,
///   替代当前的纯"查看今日运势"跳转按钮
///
/// 生肖图(视觉锚点,呼应 ZodiacRevealView)+ alias + 出生年 + 今日 anchor 跳转(点击切 .dailyFortune tab)。
private struct IdentityCard: View {
    let zodiacAssetName: String
    let alias: String
    let birthYear: Int?

    var body: some View {
        VStack(spacing: BaziTheme.Spacing.md) {
            // 印章图 + 文字组合。.accessibilityElement(.combine) 把 Image + 文字 VStack 合并成
            // 单一 VoiceOver element(读"我的命盘 alias 2000 年生"一气呵成)。
            // 下方 Button(查看今日运势)是 VStack 的另一个 child,在 combine 外部,VoiceOver 可单独聚焦。
            HStack(spacing: BaziTheme.Spacing.md) {
                Image(zodiacAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: BaziTheme.Spacing.xs) {
                    Text("我的命盘")
                        .font(BaziFont.caption(size: 12))
                        .foregroundStyle(BaziTheme.inkMuted)
                    Text(alias)
                        .font(BaziFont.display(size: 18, weight: .medium))
                        .foregroundStyle(BaziTheme.ink)
                    if let year = birthYear {
                        Text("\(year) 年生")
                            .font(BaziFont.caption(size: 12))
                            .foregroundStyle(BaziTheme.inkMuted)
                    }
                }

                Spacer()
            }
            .accessibilityElement(children: .combine)

            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)

            Button {
                // 项目按钮触感范式(PrimaryCTAButton / BirthFormView / ZodiacRevealView / ErrorStateView 都用)
                HapticEngine.medium()
                // 类型安全:用 RootTabView.Tab.dailyFortune.switchKey 而非硬编码字符串,
                // 避免 Tab.switchKey 值改动时跳转静默失效
                NotificationCenter.default.post(
                    name: .switchTab,
                    object: nil,
                    userInfo: ["tab": RootTabView.Tab.dailyFortune.switchKey]
                )
            } label: {
                HStack {
                    Text("查看今日运势")
                        .font(BaziFont.body(size: 14))
                        .foregroundStyle(BaziTheme.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }
            .accessibilityHint("跳转到今日运势 Tab")
        }
        .padding(BaziTheme.Spacing.md)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.hairline, lineWidth: 0.5))
    }
}
