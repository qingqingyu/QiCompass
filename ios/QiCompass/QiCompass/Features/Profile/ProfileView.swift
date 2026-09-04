import SwiftUI
import SwiftData

/// "我的" Tab(2026-08-01 grill-me 决策 #17 新增的第 4 个 Tab)。
///
/// 2026-09-04 「落款角标 · 一卷到底」重排(design-shotgun A 案拍板,事实源
/// `~/.gstack/projects/qingqingyu-QiCompass/designs/mine-tab-20260903/`):
/// 原生 List 分组 → ScrollView 开放长卷(hairline 分节,卡片让位),四项交互决策:
/// 0. **命主开放块**:生肖印 60 + alias 20pt + 生年·年柱干支·时辰态 meta,
///    右上**落款角标**表达登录态(已登录 = 朱印「我」·已钤同步中 / 未登录 = 虚线空印「钤」·未钤本机);
///    整块可点 → push 盘面细目页(ChartDetailView,读查分离的「查」)
/// 1. **登录引导盒**(未登录/失败态):dashed 未钤印 + 官方 SIWA/Google 按钮
///    (HIG/品牌规范锁样式,浓墨 .black 与 inkDeep 视觉同源)
/// 2. **名册**:UserSnapshotLink 行内**可见**改名/删除(不再藏滑动手势),
///    命主带「主」朱字小标;虚线「＋ 新建命盘」行收尾
/// 3. **已购 / 设置 / 关于**:hairline 分节;子时规则改 Menu 行,退出登录收进设置(弱化);
///    立场三行居中,隐私折叠,版本 + GeoNames 归属收关于节
///
/// 退化态:无命盘/无 entitlements 时显示 placeholder 文案,不报错(状态显式表达)。
struct ProfileView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Query(sort: \UserSnapshotLink.createdAt, order: .reverse)
    private var snapshotLinks: [UserSnapshotLink]

    @Query(sort: \Entitlement.purchasedAt, order: .reverse)
    private var entitlements: [Entitlement]

    /// 命主卡/名册行需要 ChartSnapshot 取 birthSolarTime / payload(生肖·年柱干支·时辰态)。
    @Query
    private var chartSnapshots: [ChartSnapshot]

    /// 重置命盘清空所有 SwiftData model(Q20 B)。
    @Environment(\.modelContext) private var context

    /// 重置命盘二次确认 alert 触发。
    @State private var showResetConfirm = false

    /// 重置命盘失败时显示的错误 alert 文案(CLAUDE.md 错误显式传播:不静默吞)。
    @State private var resetError: String?

    /// 关于节「隐私与数据」折叠态(默认收起,立场三行常驻)。
    @State private var showPrivacy = false

    /// 子时规则默认值。BirthFormView 后续 slice 起手读此 @AppStorage 作为初始值。
    /// 默认 zi_next_day(对齐 CLAUDE.md 项目约束 + 既有 DeepAnalysisViewModel 默认值)。
    @AppStorage("defaultZiHourRule") private var defaultZiHourRule = "zi_next_day"

    // MARK: v2 PR1 多人命盘管理 UI state

    /// 新建命盘 sheet(弹 BirthFormView)。
    @State private var showNewChartSheet = false
    /// 新建命盘用临时 VM(独立于 DeepAnalysisView 的 VM,避免相互污染)。
    @State private var newChartVM: DeepAnalysisViewModel?
    /// 待删 link(行内「删除」触发 → confirmationDialog 二次确认)。
    @State private var linkToDelete: UserSnapshotLink?
    /// 待编辑 link(行内「改名」触发 → 弹 AliasEditView)。
    @State private var linkToEdit: UserSnapshotLink?

    /// onboarding flag(RootTabView 用同 key 监听 onboarding sheet 触发)。
    /// 用 @AppStorage 而非 UserDefaults.standard 让 RootTabView 立即响应(避免 1 runloop 同步延迟)。
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    // S10 补时辰升级闭环(D7 常驻入口:静默态下唯一保留的主动入口)
    /// 补时辰 sheet VM(nil = 未打开)。
    @State private var addHourVM: AddHourViewModel?
    /// 装配失败的人话文案(alert 显式报错,不静默不开)。
    @State private var addHourError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                BaziTheme.paper.ignoresSafeArea()
                ScrollView {
                    // 单次求值:命主信息 + 名册行模型(每次访问都 decode payload JSON,
                    // 提取为局部 let 避免 body 内多处 computed 反复 decode——沿袭旧 zodiacMode 注释的教训)。
                    let profile = profileModel
                    VStack(alignment: .leading, spacing: 0) {
                        if let primary = profile.primary {
                            identityBlock(primary)
                            sectionDivider
                            if primary.needsHour {
                                addHourRow(
                                    silenced: primary.isSilenced,
                                    hash: primary.snapshot.contentHash
                                )
                            }
                        }
                        // 登录引导盒不依赖命盘存在:旧 accountSection 无条件展示,
                        // 名盘全删空/重置后的未登录用户在本 Tab 仍要有登录入口
                        //(PaywallView 入口需先有命盘才可达,救不了零盘态)。
                        if case .signedOut = env.accountManager.state {
                            loginBox(failedMessage: nil)
                        } else if case .failed(let message) = env.accountManager.state {
                            loginBox(failedMessage: message)
                        }
                        rosterSection(profile)
                        entitlementsSection
                        settingsSection
                        aboutSection
                        footer
                    }
                    .padding(.horizontal, 34)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.light, for: .navigationBar)
            // S10:补时辰 sheet(本 Tab 是仓库不是钩子,但静默态用户唯一主动入口在这)。
            // 关闭无额外刷新:@Query 自动响应存档/link 变化(补时辰 = 新 snapshot + 新 link)。
            .sheet(item: $addHourVM) { vm in
                AddHourSheet(
                    vm: vm,
                    onCancel: { addHourVM = nil },
                    onRecalculated: { _ in }
                )
            }
            .alert(
                "暂时无法补时辰",
                isPresented: Binding(
                    get: { addHourError != nil },
                    set: { if !$0 { addHourError = nil } }
                )
            ) {
                Button("好的", role: .cancel) {}
            } message: {
                Text(addHourError ?? "")
            }
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

    // MARK: - 命主开放块(可点 → 盘面细目页)

    /// 落款角标 + 整块 NavigationLink(design-shotgun A 案:命主卡点击去向已拍板 = ChartDetailView)。
    /// request 由 `ChartSnapshot.archivedDisplayRequest` 重建(存档直读同源,仅展示用)。
    private func identityBlock(_ primary: PrimaryProfileInfo) -> some View {
        NavigationLink {
            ChartDetailView(
                response: primary.response,
                request: primary.snapshot.archivedDisplayRequest,
                onAddHour: { openAddHourSheet(hash: primary.snapshot.contentHash) }
            )
        } label: {
            HStack(spacing: BaziTheme.Spacing.md) {
                ZodiacAvatarMark(mode: primary.zodiacMode, size: 60)

                VStack(alignment: .leading, spacing: 4) {
                    Text("我的命盘 · 命主")
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(3)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                    Text(primary.alias)
                        .font(BaziFont.display(size: 20))
                        .foregroundStyle(BaziTheme.ink)
                    Text(primary.metaLine)
                        .font(BaziFont.caption(size: 11))
                        .foregroundStyle(BaziTheme.inkMuted)
                }

                Spacer(minLength: 12)

                // 落款角标:登录态的固定位置(已钤朱印 / 未钤虚线印 / 加载中)
                VStack(alignment: .trailing, spacing: 7) {
                    cornerSeal
                    Text("观盘 ›")
                        .font(BaziFont.caption(size: 11.5))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }
            .padding(.vertical, BaziTheme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("查看盘面细目")
    }

    /// 命主块右上落款角标(AccountManager 三态 + 已登录细分)。
    @ViewBuilder
    private var cornerSeal: some View {
        switch env.accountManager.state {
        case .signedIn:
            VStack(spacing: 5) {
                // 装饰印:登录态由相邻文本「已钤 · 同步中」承载,印本身不进 VoiceOver
                //(与未登录分支 UnstampedSeal 的 accessibilityHidden 对齐,两分支读法一致)。
                SealStamp(character: "我", size: 26, rotation: -3, stampDelay: nil)
                    .accessibilityHidden(true)
                Text("已钤 · 同步中")
                    .font(BaziFont.caption(size: 9.5))
                    .tracking(1.5)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        case .signedOut, .failed:
            VStack(spacing: 5) {
                UnstampedSeal(character: "钤", size: 26)
                Text("未钤 · 本机")
                    .font(BaziFont.caption(size: 9.5))
                    .tracking(1.5)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        case .loading:
            Text("…")
                .font(BaziFont.caption(size: 12))
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    // MARK: - 登录引导盒(未登录 / 失败)

    /// 未钤虚线盒 + 官方登录按钮。失败态在按钮上方显式示错(不吞)。
    private func loginBox(failedMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.cmd) {
            HStack(spacing: 13) {
                UnstampedSeal(character: "钤", size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text("钤印为凭 · 登录")
                        .font(BaziFont.display(size: 13.5))
                        .foregroundStyle(BaziTheme.ink)
                    Text("命盘与已购跨设备同步\n不收集出生信息之外的任何资料")
                        .font(BaziFont.caption(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMuted)
                        .lineSpacing(3)
                }
            }
            if let failedMessage {
                Text(failedMessage)
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.destructive)
            }
            VStack(spacing: BaziTheme.Spacing.sm) {
                AppleSignInButton { result in
                    env.accountManager.handleAuthorization(result)
                }
                GoogleSignInButton {
                    env.accountManager.handleGoogleSignIn()
                }
            }
        }
        .padding(BaziTheme.Spacing.md)
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                .stroke(BaziTheme.hairlineDashed, style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
        )
        .padding(.top, BaziTheme.Spacing.md)
    }

    // MARK: - 数据装配(单次 decode)

    /// 命主块信息(首条可解码 link;decode 失败 → nil,身份块整体不展示,
    /// 具体 error 已由 `ChartSnapshotStore.decodeResponse` 内 Logger.error 记录)。
    private struct PrimaryProfileInfo {
        let linkId: UUID
        let alias: String
        let zodiacMode: ZodiacAvatarMode
        let snapshot: ChartSnapshot
        let response: BaziResponse
        let needsHour: Bool
        let isSilenced: Bool

        /// 「1995 年生 · 乙亥 · 时辰待补」(年柱歧义/无年 → 对应段省略,不猜)。
        var metaLine: String {
            var parts: [String] = []
            let year = Calendar.current.component(.year, from: snapshot.birthSolarTime)
            parts.append("\(year) 年生")
            if let ygz = response.pillars.year?.ganZhi {
                parts.append(ygz)
            }
            if needsHour {
                parts.append("时辰待补")
            }
            return parts.joined(separator: " · ")
        }
    }

    /// 名册行模型(逐条 decode;失败行降级为纯文本,不阻断整节)。
    private struct RosterEntry: Identifiable {
        let link: UserSnapshotLink
        let zodiacMode: ZodiacAvatarMode
        let birthYear: Int?
        let yearGanZhi: String?
        let hourUnknown: Bool

        var id: UUID { link.id }

        /// 「1995 · 乙亥 · 时辰待补」;全空(decode 失败)→ hash 前缀兜底。
        var metaLine: String {
            var parts: [String] = []
            if let birthYear { parts.append("\(birthYear)") }
            if let yearGanZhi { parts.append(yearGanZhi) }
            if hourUnknown { parts.append("时辰待补") }
            return parts.isEmpty
                ? String(link.snapshotHash.prefix(8))
                : parts.joined(separator: " · ")
        }
    }

    /// body 内单次求值的页面数据(命主 + 名册)。
    /// 缺 snapshot / decode 失败的行:zodiacMode = .hidden + 空 meta(hash 兜底),
    /// decode 失败的具体 error 已由 store 记录。
    private var profileModel: (primary: PrimaryProfileInfo?, roster: [RosterEntry]) {
        var primaryInfo: PrimaryProfileInfo?
        var entries: [RosterEntry] = []
        for link in snapshotLinks {
            // 缺 snapshot 与 decode 失败走同一条降级路(合并 guard,降级构造只写一份防漂移);
            // decode 失败的具体 error 已由 store 内 Logger.error 记录,这里不吞(见上方 doc 注释)。
            guard
                let snap = chartSnapshots.first(where: { $0.contentHash == link.snapshotHash }),
                let response = try? env.chartSnapshotStore.decodeResponse(from: snap)
            else {
                entries.append(RosterEntry(link: link, zodiacMode: .hidden, birthYear: nil, yearGanZhi: nil, hourUnknown: false))
                continue
            }
            // 生肖印/时辰态单点求值:名册行与命主块共享同一判定结果——
            // 若两处各自求值,将来单边改动会让首行名册与命主块的生肖印/「主」标静默分裂。
            let zodiacMode = ZodiacAvatarMode.resolve(hasChart: true, zodiac: response.yearBranchZodiac)
            let needsHour = response.hourUnknownGate != .hourKnown
            entries.append(
                RosterEntry(
                    link: link,
                    zodiacMode: zodiacMode,
                    birthYear: Calendar.current.component(.year, from: snap.birthSolarTime),
                    yearGanZhi: response.pillars.year?.ganZhi,
                    hourUnknown: needsHour
                )
            )
            if primaryInfo == nil {
                primaryInfo = PrimaryProfileInfo(
                    linkId: link.id,
                    alias: link.alias,
                    zodiacMode: zodiacMode,
                    snapshot: snap,
                    response: response,
                    needsHour: needsHour,
                    isSilenced: response.isHourSilenced
                )
            }
        }
        return (primaryInfo, entries)
    }

    // MARK: - S10 补时辰常驻入口(D7)

    /// 命主块下「补充出生时刻」入口行(命盘时辰未知时显示)。
    /// 静默态如实标注(入口保留;D7:静默是尊重不是惩罚)。
    private func addHourRow(silenced: Bool, hash: String) -> some View {
        Button {
            openAddHourSheet(hash: hash)
        } label: {
            HStack(spacing: 9) {
                Circle()
                    .stroke(BaziTheme.hairlineDashed, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
                    .frame(width: 5, height: 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.Profile.addHourEntry)
                        .font(BaziFont.caption(size: 11.5))
                        .tracking(1.5)
                        .foregroundStyle(BaziTheme.inkMuted)
                    if silenced {
                        Text(L10n.Profile.addHourSilentNote)
                            .font(BaziFont.caption(size: 10))
                            .foregroundStyle(BaziTheme.inkMutedSecondary)
                    }
                }
                Spacer()
                Text("›")
                    .font(BaziFont.caption(size: 12))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 名册(我的命盘)

    private func rosterSection(_ profile: (primary: PrimaryProfileInfo?, roster: [RosterEntry])) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(
                "名 册",
                trailing: accountManagerSignedIn
                    ? "云端同步 · 共 \(profile.roster.count) 盘"
                    : "数据仅存本机"
            )
            if profile.roster.isEmpty {
                Text("还没有命盘")
                    .font(BaziFont.caption(size: 13))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .padding(.vertical, BaziTheme.Spacing.md)
            } else {
                // 「主」标按 linkId 对齐命主块(首条**可解码** link),不用 index==0:
                // 首条 link decode 失败/缺 snapshot 时,index==0 会把「主」标落到
                // hash 兜底行,与上方命主块(下一条可解码 link)互相矛盾。
                let primaryId = profile.primary?.linkId
                ForEach(profile.roster) { entry in
                    rosterRow(entry, isPrimary: entry.link.id == primaryId)
                }
            }
            newChartRow
        }
        .padding(.top, BaziTheme.Spacing.cmd)
    }

    /// 名册行:生肖印 + alias(+命主「主」朱字小标)+ meta + 行内可见改名/删除。
    private func rosterRow(_ entry: RosterEntry, isPrimary: Bool) -> some View {
        HStack(spacing: BaziTheme.Spacing.cmd) {
            ZodiacAvatarMark(mode: entry.zodiacMode, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.link.alias)
                        .font(BaziFont.display(size: 15))
                        .foregroundStyle(BaziTheme.ink)
                    if isPrimary {
                        LordTag()
                    }
                }
                Text(entry.metaLine)
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }

            Spacer(minLength: 12)

            HStack(spacing: BaziTheme.Spacing.cmd) {
                Button {
                    linkToEdit = entry.link
                } label: {
                    Text("改名")
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                        .frame(minWidth: 34, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    linkToDelete = entry.link
                } label: {
                    Text("删除")
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.destructive.opacity(0.72))
                        .frame(minWidth: 34, minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            sectionDivider
        }
    }

    /// 虚线「＋ 新建命盘」行(dashed 临时态语义)。
    private var newChartRow: some View {
        Button {
            openNewChartSheet()
        } label: {
            HStack(spacing: BaziTheme.Spacing.cmd) {
                Circle()
                    .stroke(BaziTheme.hairlineDashed, style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Text("＋")
                            .font(BaziFont.caption(size: 15))
                            .foregroundStyle(BaziTheme.inkMuted)
                    )
                Text("新建命盘 · 给家人朋友也排一份")
                    .font(BaziFont.caption(size: 12.5))
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("新建命盘")
    }

    private var accountManagerSignedIn: Bool {
        if case .signedIn = env.accountManager.state { return true }
        return false
    }

    // MARK: - 已购

    private var entitlementsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("已 购", trailing: "凭 App Store 账号")
            let activeEntitlements = entitlements.filter { $0.isActive }
            if activeEntitlements.isEmpty {
                Text("还没有购买")
                    .font(BaziFont.caption(size: 13))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .padding(.vertical, BaziTheme.Spacing.md)
            } else {
                ForEach(Array(activeEntitlements.enumerated()), id: \.element.id) { index, ent in
                    purchaseRow(ent, isLast: index == activeEntitlements.count - 1)
                }
            }
        }
        .padding(.top, BaziTheme.Spacing.cmd)
    }

    private func purchaseRow(_ ent: Entitlement, isLast: Bool) -> some View {
        HStack(spacing: 10) {
            Text(displayName(for: ent.module))
                .font(BaziFont.display(size: 13.5))
                .foregroundStyle(BaziTheme.ink)
            Text("已解锁")
                .font(BaziFont.caption(size: 9.5))
                .foregroundStyle(BaziTheme.jade)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
                .overlay(Capsule().stroke(BaziTheme.jade.opacity(0.45)))
            Spacer()
            Text("购买于 \(ent.originalPurchaseDate, format: .dateTime.year().month().day())")
                .font(BaziFont.caption(size: 10))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if !isLast { sectionDivider }
        }
    }

    // MARK: - 设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("设 置")
            // 子时规则默认:Menu + Picker(原 List Picker 的开放布局等价物)
            Menu {
                Picker("子时换日", selection: $defaultZiHourRule) {
                    Text("子时属次日(23:00 换日)").tag("zi_next_day")
                    Text("早晚子时(00:00 换日)").tag("zero_oclock")
                }
            } label: {
                HStack {
                    Text("子时换日")
                        .font(BaziFont.caption(size: 13))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.ink)
                    Spacer()
                    Text(defaultZiHourRule == "zi_next_day" ? "子时属次日 ›" : "早晚子时 ›")
                        .font(BaziFont.caption(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .overlay(alignment: .bottom) { sectionDivider }

            // Q20 B:重置命盘 fallback。用户输错生日时清空所有数据重新 onboarding。
            Button {
                showResetConfirm = true
            } label: {
                HStack {
                    Text("重置命盘")
                        .font(BaziFont.caption(size: 13))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMuted)
                    Spacer()
                    Text("清空全部数据 ›")
                        .font(BaziFont.caption(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) {
                if accountManagerSignedIn { sectionDivider }
            }

            // 退出登录(已登录态显示;收进设置,弱化处理)
            if accountManagerSignedIn {
                Button {
                    env.accountManager.signOut()
                } label: {
                    HStack {
                        Text("退出登录")
                            .font(BaziFont.caption(size: 13))
                            .tracking(1)
                            .foregroundStyle(BaziTheme.inkMuted)
                        Spacer()
                        if case .signedIn(let user) = env.accountManager.state {
                            Text("\(user.provider.displayName) ›")
                                .font(BaziFont.caption(size: 10.5))
                                .foregroundStyle(BaziTheme.inkMutedSecondary)
                        }
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Text("影响新表单的初始值。已存档命盘不受影响(其规则随 snapshot 持久化)。重置命盘会清空所有数据并重新走 onboarding。")
                .font(BaziFont.caption(size: 10))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .padding(.top, 8)
        }
        .padding(.top, BaziTheme.Spacing.cmd)
    }

    // MARK: - 关于(2026-08-13 onboarding 三屏重构:完整版立场/隐私下沉到此)

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("关 于")

            // 立场(为什么可信 — Memorable Thing "专业不忽悠"的完整落点)
            VStack(spacing: 4) {
                Text(L10n.Profile.aboutStanceTitle)
                    .font(BaziFont.caption(size: 10))
                    .tracking(3)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                    .padding(.bottom, 2)
                Text(L10n.Profile.aboutStance1)
                Text(L10n.Profile.aboutStance2)
                Text(L10n.Profile.aboutStance3)
            }
            .font(BaziFont.caption(size: 11.5))
            .foregroundStyle(BaziTheme.ink)
            .lineSpacing(4)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, BaziTheme.Spacing.md)

            // 隐私与数据(折叠;点开展开三行)
            Button {
                withAnimation { showPrivacy.toggle() }
            } label: {
                HStack {
                    Text("隐私与数据")
                        .font(BaziFont.caption(size: 11))
                        .foregroundStyle(BaziTheme.inkMuted)
                    Spacer()
                    Text(showPrivacy ? "⌃" : "⌄")
                        .font(BaziFont.caption(size: 11))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // 箭头字符对 VoiceOver 是噪音,统一读按钮语义(对齐 newChartRow 惯例)
            .accessibilityLabel("隐私与数据")

            if showPrivacy {
                VStack(spacing: 3) {
                    Text(L10n.Profile.aboutPrivacy1)
                    Text(L10n.Profile.aboutPrivacy2)
                    Text(L10n.Profile.aboutPrivacy3)
                }
                .font(BaziFont.caption(size: 11))
                .foregroundStyle(BaziTheme.ink)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            }

            HStack {
                Text("版本")
                Spacer()
                Text("\(appVersion) (\(buildNumber))")
            }
            .font(BaziFont.caption(size: 11))
            .foregroundStyle(BaziTheme.inkMutedSecondary)
            .padding(.vertical, 9)

            // S03:GeoNames CC-BY 4.0 attribution(决策 Q2,关于页一行)
            Text(String(localized: "city.about.geonames"))
                .font(BaziFont.caption(size: 9.5))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .padding(.top, BaziTheme.Spacing.cmd)
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(spacing: 3) {
            Text("QICOMPASS")
                .font(BaziFont.latinCaps(size: 8))
                .tracking(4.5)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Text("玄机问道 · 专业不忽悠")
                .font(BaziFont.caption(size: 9.5))
                .tracking(2.5)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BaziTheme.Spacing.xl)
    }

    // MARK: - 小组件

    /// 分节内行间 hairline(0.5pt,随内容宽度)。
    private var sectionDivider: some View {
        Rectangle()
            .fill(BaziTheme.hairline)
            .frame(height: 0.5)
    }

    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(BaziFont.caption(size: 10))
                .tracking(4)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Spacer(minLength: 12)
            if let trailing {
                Text(trailing)
                    .font(BaziFont.caption(size: 9.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: - v2 PR1 操作

    /// 打开补时辰 sheet(装配失败显式 alert,不静默不开)。
    private func openAddHourSheet(hash: String) {
        do {
            addHourVM = try AddHourViewModel.make(
                snapshotHash: hash,
                orchestrator: env.deepAnalysisOrchestrator,
                chartStore: env.chartSnapshotStore,
                linkStore: env.userSnapshotLinkStore
            )
        } catch {
            AppLogger.app.error(
                "op=profile.openAddHour failed hash=\(hash, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            addHourError = (error as? LocalizedError)?.errorDescription ?? L10n.AddHour.errorRebuild
        }
    }

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

    // MARK: - Helpers

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
            AppLogger.app.error("重置命盘失败 error=\(String(describing: error), privacy: .public)")
            // 向用户显式报错,不静默吞。人话文案(2026-08-16 ErrorCode 清理:
            // SwiftData 原始 localizedDescription 是英文技术细节,不进 UI;
            // 原始 error 已记上方日志)。
            // 延迟一帧赋值:iOS 17 在同一 runloop 内连续呈现两个 alert(确认 alert dismiss → 错误 alert present)
            // 可能被吞掉。Task { @MainActor in } 让出当前 runloop,经实证可规避此问题。
            // 注意:这不是 SwiftUI 契约保证,而是 iOS 17 实测有效的经验性 workaround。
            let msg = "重置未完成,数据未变更,请重试"
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

// MARK: - UnstampedSeal(未钤虚线印,落款角标/登录引导盒)

/// 虚线空心印:登录前的「未钤」态(与 SealStamp 朱印互为阴阳,「我的」tab 图标同款语义)。
/// dashed hairline 专用于临时态(DESIGN.md),登录后由 SealStamp「我」替换。
private struct UnstampedSeal: View {
    let character: String
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.12)
            .stroke(BaziTheme.hairlineDashed, style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
            .frame(width: size, height: size)
            .overlay(
                Text(character)
                    .font(BaziFont.display(size: size * 0.48))
                    .foregroundStyle(BaziTheme.inkMuted)
            )
            .rotationEffect(.degrees(-3))
            .accessibilityHidden(true)
    }
}

// MARK: - LordTag(命主朱字小标)

/// 名册首行「主」字小标:朱描边 + 朱字 + 轻微旋转(印章级朱红,小元素)。
private struct LordTag: View {
    var body: some View {
        Text("主")
            .font(BaziFont.caption(size: 9))
            .foregroundStyle(BaziTheme.cinnabar)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(BaziTheme.cinnabar.opacity(0.5))
            )
            .rotationEffect(.degrees(-4))
            .accessibilityLabel("命主")
    }
}

// MARK: - ZodiacAvatarMark(生肖头像位三态表达,S08)

/// 生肖图/墨点头像位:命主块(60pt)与名册行(36pt)共用。
/// - `.zodiac` 正常生肖印章图(与 ZodiacRevealView 同一 asset 族)
/// - `.inkDot` 年柱歧义(立春+时辰未知,D10)→ EnsoView 墨圆(品牌指纹,静态渲染):
///   有盘但属相待时辰而定,**不猜动物**;留白给正式表达(S05 兜底是整体隐藏命主卡)
/// - `.hidden` 无命盘 / decode 失败 → 空视图(头像位留空)
private struct ZodiacAvatarMark: View {
    let mode: ZodiacAvatarMode
    let size: CGFloat

    var body: some View {
        switch mode {
        case .zodiac(let assetName):
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .inkDot:
            // EnsoView 内部已 accessibilityHidden(纯装饰墨圆,属相信息由上下文文本承载)
            EnsoView(size: size, animated: false)
        case .hidden:
            EmptyView()
        }
    }
}
