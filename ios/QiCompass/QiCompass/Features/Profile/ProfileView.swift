import SwiftUI
import SwiftData

/// "我的" Tab(2026-08-01 grill-me 决策 #17 新增的第 4 个 Tab)。
///
/// 2026-10-01 Me 页合并版(外评「排版回设计稿 + 内容保真机」,spec:
/// `~/.gstack/projects/qingqingyu-QiCompass/designs/review-fix-20261001/me-final-spec.md`):
/// - **字距收敛(F1)**:全页 tracking 只剩 owner kicker 与 footer QICOMPASS
///   两处品牌指纹;区块标题从宽字距小标升级为 `display(17)` 浓墨锚点
///   (EN serif medium / zh 楷体),层级靠字号不靠字距
/// - **头部去徽章(F3)**:落款角标移除(EN 下挤断 metaLine 的 "Day/Master"),
///   登录态唯一落点 = 未登录登录盒(虚线框收组,F2 回归) /
///   已登录轻状态行(朱印「我」·已钤同步中)
/// - **名册(F4)**:主命盘不进名册(与命主块重复);过滤后为空 → 整节隐藏
///   (非命主 link 创建入口已全拔,新用户恒空;老安装存量 link 仍在,隐藏非删码);
///   行恢复纯导航(→ ChartDetailView),改名/删除收进头部 Edit 编辑态
/// - **设置(F5/F6)**:子时说明紧跟子时行(重置后果由重置行 trailing 承载);
///   Language 行显示实际生效语言的 endonym;重置行文字回升浓墨
///
/// 2026-09-04 「落款角标 · 一卷到底」重排(design-shotgun A 案拍板,事实源
/// `~/.gstack/projects/qingqingyu-QiCompass/designs/mine-tab-20260903/`):
/// 原生 List 分组 → ScrollView 开放长卷(hairline 分节,卡片让位),四项交互决策:
/// 0. **命主开放块**:生肖印 60 + alias 20pt + 生年·年柱干支·日主 meta,
///    整块可点 → push 盘面细目页(ChartDetailView,读查分离的「查」)
/// 1. **登录引导盒**(未登录/失败态):dashed 未钤印 + 官方 SIWA 按钮
///    (HIG/品牌规范锁样式,浓墨 .black 与 inkDeep 视觉同源)
/// 2. **名册**:UserSnapshotLink 全量存档(≠合盘名单,零联动)
///    (2026-09-05「＋ 新建命盘」入口移除:多人盘建盘归 v2——家人盘会顶掉
///    「最新 link = 命主」语义,劫持命主卡/深度解析/今日运势的取盘)
/// 3. **已购 / 设置 / 关于**:hairline 分节;已购行两行式——合盘 entitlement 追加
///    「A × B」归属行(compatibilityHash 反查 CompatibilitySnapshot,快照缺失降级单行不猜);
///    子时规则改 Menu 行,退出登录收进设置(弱化);
///    立场三行居中,隐私折叠,版本 + GeoNames 归属收关于节
///
/// 退化态:无 entitlements 时显示 placeholder 文案,不报错(状态显式表达);
/// 零盘态(重置后)本 Tab 只剩登录盒 + 设置/关于,登录入口不依赖命盘存在。
struct ProfileView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Query(sort: \UserSnapshotLink.createdAt, order: .reverse)
    private var snapshotLinks: [UserSnapshotLink]

    @Query(sort: \Entitlement.purchasedAt, order: .reverse)
    private var entitlements: [Entitlement]

    /// 命主卡/名册行需要 ChartSnapshot 取 birthSolarTime / payload(生肖·年柱干支·时辰态)。
    @Query
    private var chartSnapshots: [ChartSnapshot]

    /// 已购归属:合盘 entitlement 的 contentHash = compatibilityHash,
    /// 反查 CompatibilitySnapshot 取 personAHash / personBHash 解析对级两端名。
    @Query
    private var compatSnapshots: [CompatibilitySnapshot]

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

    /// 语言覆盖(D6:四档 system/zh/zh-hant/en;key 与 AppLanguage.overrideDefaultsKey
    /// 同字面量)。@AppStorage 直写 UserDefaults 存「用户选了什么」;生效语言读
    /// AppLanguage 启动快照(L1/F2)——重启前 App 保持旧语言,行下方常驻
    /// pending 小注;UI 文案经 AppleLanguages 镜像 + 重启生效(方案 A)。
    @AppStorage(AppLanguage.overrideDefaultsKey) private var languageOverride = "system"
    /// 语言切换后的「重启生效」alert(D6:方案 A 既定 UX,明示而非静默半生效)。
    @State private var showLanguageRestartAlert = false

    // MARK: 名册行内操作 state

    /// 待删 link(编辑态行内「删除」触发 → confirmationDialog 二次确认)。
    @State private var linkToDelete: UserSnapshotLink?
    /// 待编辑 link(编辑态行内「改名」触发 → 弹 AliasEditView)。
    @State private var linkToEdit: UserSnapshotLink?
    /// 名册编辑态(F4 2026-10-01):破坏性操作收进显式编辑态——
    /// 非编辑态行是纯导航(›),编辑态行内浮现改名/删除。
    @State private var rosterEditing = false

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
                    // F4(2026-10-01):主命盘不进名册(与命主块重复,只有「Me」
                    // 一行时尤其明显);过滤后为空 → 整节隐藏(body 侧条件渲染)。
                    let rosterVisible = profile.roster.filter { $0.link.id != profile.primary?.linkId }
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
                        if !rosterVisible.isEmpty {
                            rosterSection(rosterVisible)
                        }
                        // S2(2026-09-30 BP 评审 R4/R5):账号信息在名册之后——
                        // 信息优先级 = 我的命盘 → 名册 → 账号。F3(2026-10-01):
                        // 登录态唯一落点收口到这里——未登录 = 登录盒(虚线钤印 +
                        // Unsealed 说明),已登录 = 轻状态行(朱印「我」·已钤同步中),
                        // 状态永不挤头部。零盘态约束不变:登录盒不依赖命盘存在,
                        // 名盘全删空/重置后的未登录用户在本 Tab 仍要有登录入口
                        //(PaywallView 入口需先有命盘才可达,救不了零盘态)。
                        switch env.accountManager.state {
                        case .signedIn:
                            sealedStatusRow
                        case .signedOut:
                            loginBox(failedMessage: nil)
                        case .failed(let message):
                            loginBox(failedMessage: message)
                        case .loading:
                            EmptyView()
                        }
                        entitlementsSection
                        settingsSection
                        aboutSection
                        footer
                    }
                    .padding(.horizontal, 34)
                    .padding(.top, 6)
                    // 底 padding ≥96(2026-10-01 spec §三):浮动 tab 栏高度 + 间距,
                    // 保证 footer 在 tab 栏上方完整可见
                    .padding(.bottom, 96)
                    // 编辑态悬挂出口(review 2026-10-01):编辑态删到最后一条非命主
                    // link 时整节隐藏,rosterEditing 须归位——否则会话中途 link 回流
                    //(登录链式 pull;push 是 UPSERT-only 不传播删除)时,名册未经
                    // 操作直接呈现编辑态,行内 Delete 可见,违背 F4「破坏性操作
                    // 必须显式进入」。
                    .onChange(of: rosterVisible.count) { _, newCount in
                        if newCount == 0 { rosterEditing = false }
                    }
                }
            }
            // D2(2026-09-29 拍板):四 tab 统一去系统导航标题,防系统字体与水墨层打架;
            // 栏本身保留。sheet 内二级页自带标题,不受影响。
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
            .sheet(item: $linkToEdit) { link in
                AliasEditView(initialAlias: link.alias) { newAlias in
                    saveAlias(linkId: link.id, newAlias: newAlias)
                }
            }
            .confirmationDialog(
                String(format: String(localized: "确认删除「%@」?"), linkToDelete?.alias ?? ""),
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
                Text("此操作不可恢复。所有命盘、合盘记录、解读缓存都会被清空。购买记录保留在 App Store,重新录入出生信息后可恢复。")
            }
            .alert("重置失败", isPresented: Binding(
                get: { resetError != nil },
                set: { newValue in if !newValue { resetError = nil } }
            )) {
                Button(L10n.Common.ok, role: .cancel) {}
            } message: {
                Text(resetError ?? "")
            }
        }
    }

    // MARK: - 命主开放块(可点 → 盘面细目页)

    /// 整块 NavigationLink(design-shotgun A 案:命主卡点击去向已拍板 = ChartDetailView)。
    /// request 由 `ChartSnapshot.archivedDisplayRequest` 重建(存档直读同源,仅展示用)。
    /// F3(2026-10-01):右上落款角标移除——EN 下角标挤占文字列宽,metaLine 断在
    /// "Day/Master" 中间,且「未封存」状态与登录盒重复;登录态唯一落点 = sealedStatusRow。
    private func identityBlock(_ primary: PrimaryProfileInfo) -> some View {
        HStack(alignment: .center, spacing: BaziTheme.Spacing.sm) {
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
                        // F1(2026-10-01)tracking 豁免之一:owner kicker 品牌指纹保留字距
                        //(全页仅此处与 footer QICOMPASS 两处)
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
                        // M2(2026-10-01 外评「右上偏挤」):入口下沉到身份信息同列,
                        // 13pt 全称不变(S2 口径,命主块是本 Tab 第一入口)。
                        Text("查看完整命盘 ›")
                            .font(BaziFont.caption(size: 13))
                            .foregroundStyle(BaziTheme.inkMuted)
                            .padding(.top, 2)
                    }
                }
                .padding(.vertical, BaziTheme.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看盘面细目")

            // #9(2026-10-02,用户拍板):主命盘不进名册(F4)后全 App 无改名
            // 入口——命主块补轻量改名触点(样式镜像名册编辑态行内「改名」;
            // 放 NavigationLink 外侧防嵌套按钮吞导航点击;删除主命盘不做,
            // 语义 v2 再说)。与 M2「右上偏挤」教训区分:单个 10.5pt 弱字,
            // 垂直居中尾随,不与 kicker/标题抢第一行。
            Button {
                linkToEdit = primary.link
            } label: {
                Text("改名")
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                    .frame(minWidth: 34, minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("修改命盘名称")
        }
    }

    /// 已登录轻状态行(F3 2026-10-01):朱印「我」+ 已钤 · 同步中。
    /// 登录态的唯一展示位(原命主块右上角标的已钤分支迁来)——状态永不挤头部。
    private var sealedStatusRow: some View {
        HStack(spacing: 12) {
            // 装饰印:登录态由相邻文本「已钤 · 同步中」承载,印本身不进 VoiceOver
            //(与未登录分支 UnstampedSeal 的 accessibilityHidden 对齐,两分支读法一致)。
            SealStamp(character: "我", size: 26, rotation: -3, stampDelay: nil)
                .accessibilityHidden(true)
            Text("已钤 · 同步中")
                .font(BaziFont.caption(size: 11))
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .padding(.top, BaziTheme.Spacing.cmd)
    }

    // MARK: - 登录引导节(未登录 / 失败;S2 移到名册之后)

    /// 未登录/失败态登录盒。S2(2026-09-30 BP 评审 R5)曾去虚线框收轻;
    /// 2026-10-01 外评 F2 拍板回归**虚线框收组**(Seal 印 + 说明 + 按钮一组,
    /// 视觉事实源 me-final.html 的 .login-card)——区块标题升为 serif 锚点后,
    /// 登录盒需要一组边界与页面对话;同时按钮降权:Apple 按钮 44pt 标准高度
    /// (全页最重元素是区块标题,不是登录按钮;付费墙侧维持 50,经 buttonHeight
    /// 注入,不动共用组件默认值)。失败态在按钮上方显式示错(不吞);
    /// 按钮对与接线收敛在 LoginGateButtons(2026-09-06,与付费墙同源)。
    private func loginBox(failedMessage: String?) -> some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            HStack(spacing: 12) {
                UnstampedSeal(character: "钤", size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text("钤印为凭 · 登录")
                        .font(BaziFont.display(size: 15.5))
                        .foregroundStyle(BaziTheme.ink)
                    Text("命盘与已购跨设备同步 · 不收集出生信息之外的任何资料")
                        .font(BaziFont.caption(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }
            LoginGateButtons(errorMessage: failedMessage, buttonHeight: 44)
        }
        .padding(BaziTheme.Spacing.md)
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.hairlineDashed, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
        )
        .padding(.top, BaziTheme.Spacing.cmd)
    }

    // MARK: - 数据装配(单次 decode)

    /// 命主块信息(首条可解码 link;decode 失败 → nil,身份块整体不展示,
    /// 具体 error 已由 `ChartSnapshotStore.decodeResponse` 内 Logger.error 记录)。
    private struct PrimaryProfileInfo {
        let linkId: UUID
        /// #9:命主块改名入口需要完整 link(sheet(item:) 用;linkId 保留给
        /// 名册过滤的单点判据)。
        let link: UserSnapshotLink
        let alias: String
        let zodiacMode: ZodiacAvatarMode
        let snapshot: ChartSnapshot
        let response: BaziResponse
        let needsHour: Bool
        let isSilenced: Bool

        /// 「1995 年生 · 乙亥 · 日主丁火 · 时辰待补」(年柱/日柱歧义 → 对应段省略,不猜)。
        var metaLine: String {
            var parts: [String] = []
            let year = Calendar.current.component(.year, from: snapshot.birthSolarTime)
            // 2026-09-28 修复:i18n 改写时漏了 append,名册行从「1995 年生 · 乙亥」
            // 退化成「乙亥」(unused-result 警告不拦 CI)。
            parts.append(String(format: String(localized: "%lld 年生"), year))
            if let ygz = response.pillars.year?.ganZhi {
                parts.append(ygz)
            }
            // S2(2026-09-30 BP 评审 R4):补日主段——命主块只说年份/年柱太浅,
            // 日主是"这是谁"的第一事实。revealDayMasterDisplay 内部判日柱歧义
            //(gan/ganElement 任一 nil → nil),时辰未知不影响日柱,照常显示。
            if let dayMaster = ZodiacHelper.revealDayMasterDisplay(
                gan: response.pillars.day?.gan,
                ganElement: response.pillars.day?.ganElement,
                language: AppLanguage.current
            ) {
                parts.append(String(format: String(localized: "日主%@"), dayMaster))
            }
            if needsHour {
                parts.append(String(localized: "时辰待补"))
            }
            return parts.joined(separator: " · ")
        }
    }

    /// 名册行模型(逐条 decode;失败行降级为纯文本,不阻断整节)。
    /// F4(2026-10-01):补 snapshot/response 承载——行恢复纯导航(→ ChartDetailView),
    /// 与命主块同构;nil = 降级行(snapshot 缺失/decode 失败),无导航目标,渲染纯文本行不误导。
    private struct RosterEntry: Identifiable {
        let link: UserSnapshotLink
        let zodiacMode: ZodiacAvatarMode
        let birthYear: Int?
        let yearGanZhi: String?
        let hourUnknown: Bool
        let snapshot: ChartSnapshot?
        let response: BaziResponse?

        var id: UUID { link.id }

        /// 「1995 · 乙亥 · 时辰待补」;全空(decode 失败)→ hash 前缀兜底。
        var metaLine: String {
            var parts: [String] = []
            if let birthYear { parts.append("\(birthYear)") }
            if let yearGanZhi { parts.append(yearGanZhi) }
            if hourUnknown { parts.append(String(localized: "时辰待补")) }
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
                entries.append(RosterEntry(link: link, zodiacMode: .hidden, birthYear: nil, yearGanZhi: nil, hourUnknown: false, snapshot: nil, response: nil))
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
                    hourUnknown: needsHour,
                    snapshot: snap,
                    response: response
                )
            )
            if primaryInfo == nil {
                primaryInfo = PrimaryProfileInfo(
                    linkId: link.id,
                    link: link,
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

    /// F4(2026-10-01):名册只列**非命主** link(主命盘在上方命主块,重复即噪音;
    /// 过滤在 body 侧完成,空 → 整节隐藏)。头部 Edit 进编辑态,行内浮现改名/删除
    /// ——行内常驻红字 Delete 删的还是自己的盘,误触风险高,破坏性操作必须显式进入。
    /// 已登录尾部注「云端同步 · 共 N 盘」(真机优点保留,N = 过滤后条数与行一致);
    /// 未登录不加「数据仅存本机」尾注——与登录盒文案重复,信息已在登录盒。
    private func rosterSection(_ visible: [RosterEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // F4:header 复用 sectionHeader(F1 样式单点),trailing = 同步尾注 + Edit
            //(组合尾注走 @ViewBuilder 重载,与其他节的字符串尾注共用同一标题样式)
            sectionHeader(String(localized: "名 册")) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if accountManagerSignedIn {
                        Text(String(format: String(localized: "云端同步 · 共 %lld 盘"), visible.count))
                            .font(BaziFont.caption(size: 10.5))
                            .foregroundStyle(BaziTheme.inkMutedSecondary)
                            .lineLimit(1)
                    }
                    Button {
                        withAnimation { rosterEditing.toggle() }
                    } label: {
                        Text(rosterEditing ? String(localized: "完成") : String(localized: "编辑"))
                            .font(BaziFont.caption(size: 12.5))
                            .foregroundStyle(BaziTheme.inkMuted)
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(visible) { entry in
                rosterRow(entry)
            }
        }
        .padding(.top, BaziTheme.Spacing.cmd)
    }

    /// 名册行:非编辑态 = 纯导航行(→ ChartDetailView,与命主块同构);
    /// 编辑态 = 行内浮现改名/删除(Delete 满色 destructive,确认弹窗兜底)。
    /// 降级行(snapshot 缺失/decode 失败)无导航目标,渲染纯文本行不带 ›。
    @ViewBuilder
    private func rosterRow(_ entry: RosterEntry) -> some View {
        if rosterEditing {
            rosterRowContent(entry)
                .overlay(alignment: .bottom) { sectionDivider }
        } else if let snapshot = entry.snapshot, let response = entry.response {
            NavigationLink {
                ChartDetailView(
                    response: response,
                    request: snapshot.archivedDisplayRequest,
                    onAddHour: { openAddHourSheet(hash: snapshot.contentHash) }
                )
            } label: {
                rosterRowContent(entry)
            }
            .buttonStyle(.plain)
            .overlay(alignment: .bottom) { sectionDivider }
        } else {
            rosterRowContent(entry)
                .overlay(alignment: .bottom) { sectionDivider }
        }
    }

    /// 名册行内容:头像 + 别名 + meta,尾随 ›(导航)或改名/删除(编辑态)。
    private func rosterRowContent(_ entry: RosterEntry) -> some View {
        HStack(spacing: BaziTheme.Spacing.cmd) {
            ZodiacAvatarMark(mode: entry.zodiacMode, size: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.link.alias)
                    .font(BaziFont.display(size: 15))
                    .foregroundStyle(BaziTheme.ink)
                Text(entry.metaLine)
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }

            Spacer(minLength: 12)

            if rosterEditing {
                HStack(spacing: BaziTheme.Spacing.cmd) {
                    Button {
                        linkToEdit = entry.link
                    } label: {
                        Text("改名")
                            .font(BaziFont.caption(size: 10.5))
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
                            .foregroundStyle(BaziTheme.destructive)
                            .frame(minWidth: 34, minHeight: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("›")
                    .font(BaziFont.caption(size: 12))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }

    private var accountManagerSignedIn: Bool {
        if case .signedIn = env.accountManager.state { return true }
        return false
    }

    // MARK: - 已购

    private var entitlementsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "已 购"), trailing: String(localized: "凭 App Store 账号"))
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
        VStack(alignment: .leading, spacing: 3) {
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
            // 合盘归属行:「A × B」(与名册行 title+metaLine 同构)
            if let pair = pairLine(for: ent) {
                Text(pair)
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if !isLast { sectionDivider }
        }
    }

    // MARK: - 已购归属(合盘对级解析)

    /// 合盘 entitlement 的归属行「发起方 × 对端」。
    /// - CompatibilitySnapshot.personAHash / personBHash 保留购买时的 UI 顺序
    ///   (A=发起方,B=对端;A 盘可在配置页切换,故两端都显示,不默认「你×对方」)
    /// - 快照不随账号同步(SyncManager 只拉命盘,合盘快照仅本机):新设备 entitlement
    ///   回得来、对级快照回不来 → 返回 nil,行降级为单行,不猜归属
    /// - 深度解析 entitlement 不走此解析(单命盘场景,无需归属)
    private func pairLine(for ent: Entitlement) -> String? {
        guard ent.module == EntitlementModule.compatibility,
              let snap = compatSnapshots.first(where: { $0.compatibilityHash == ent.contentHash })
        else { return nil }
        return "\(sideName(for: snap.personAHash)) × \(sideName(for: snap.personBHash))"
    }

    /// 对级单端显示名:link alias → 「对方 · 出生日期」→ 「对方」。
    /// 临时人不建 link(D6:alias 不持久化),兜底名对齐合盘名单惯例「对方+出生日期」
    /// (CompatibilityRosterPersistence 文档注释同一约定);
    /// 连 ChartSnapshot 都缺(理论不可达)→ 纯「对方」,信息不足以命名时不猜。
    /// A 侧(发起方)link 被用户删除后同样走兜底——罕见路径,不猜名。
    private func sideName(for hash: String) -> String {
        if let link = snapshotLinks.first(where: { $0.snapshotHash == hash }) {
            return link.alias
        }
        if let chart = chartSnapshots.first(where: { $0.contentHash == hash }) {
            return L10n.CompatibilityPartner.fallbackName(Self.fallbackBirthDate(chart.birthSolarTime, timezoneName: chart.cityTimezone))
        }
        return String(localized: "对方")
    }

    /// 兜底名出生日期:按**出生城市时区**格式化 "yyyy-MM-dd"
    /// (与 CompatibilityViewModel.fallbackDateString 同约定:birthSolarTime 以出生地
    /// 钟面语义存储,设备时区渲染会在远时区城市错一天;老快照 cityTimezone nil → 设备时区)。
    private static func fallbackBirthDate(_ date: Date, timezoneName: String?) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timezoneName.flatMap(TimeZone.init(identifier:)) ?? .current
        return f.string(from: date)
    }

    // MARK: - 设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "设 置"))
            // 语言(D6/S4):唯一语言开关——UI 文案 / 命盘术语 / AI 解读共用
            // (D9 不做独立「解读语言」)。Menu + Picker 与子时规则同款交互。
            Menu {
                Picker("语言", selection: $languageOverride) {
                    ForEach(AppLanguage.Override.allCases, id: \.rawValue) { override in
                        Text(override.displayLabel).tag(override.rawValue)
                    }
                }
            } label: {
                HStack {
                    Text("语言")
                        .font(BaziFont.caption(size: 13))
                        .foregroundStyle(BaziTheme.ink)
                    Spacer()
                    // F6(2026-10-01):显示**实际生效语言**的 endonym,与界面语言
                    // 永不脱节——原 override 档名(跟随系统/简体中文/…)是 xcstrings
                    // 翻译名,EN 界面下会与显示值错位;endonym 是语言自己的名字,
                    // 「跟随系统」也经 AppLanguage.current 解析到具体语言。
                    Text("\(AppLanguage.current.endonym) ›")
                        .font(BaziFont.caption(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .onChange(of: languageOverride) { _, newValue in
                applyLanguageOverride(newValue)
            }
            .alert(
                String(localized: "重启后生效"),
                isPresented: $showLanguageRestartAlert
            ) {
                Button(String(localized: "好")) {}
            } message: {
                Text(languageRestartAlertMessage)
            }
            .overlay(alignment: .bottom) { sectionDivider }
            // L1/F2:选择已存、快照未变(未重启)→ 行下常驻小注,直到重启生效
            if languageRestartPending {
                Text(languageRestartPendingNote)
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                    .padding(.bottom, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                        .foregroundStyle(BaziTheme.ink)
                    Spacer()
                    Text(defaultZiHourRule == "zi_next_day" ? String(localized: "子时属次日 ›") : String(localized: "早晚子时 ›"))
                        .font(BaziFont.caption(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            // F5(2026-10-01):说明紧跟子时行,只讲子时本身——原合并说明段挂在
            // 设置区末尾,读起来全段在讲重置;重置的后果由重置行 trailing
            // 「清空全部数据 ›」承载,不再有独立段落。
            // 2026-09-25 暗色走查 #11 口径保留:去开发术语(snapshot/onboarding),说人话。
            Text("只影响之后新填表单的初始值;已保存命盘的换算规则随盘保存")
                .font(BaziFont.caption(size: 10))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) { sectionDivider }

            // Q20 B:重置命盘 fallback。用户输错生日时清空所有数据重新 onboarding。
            Button {
                showResetConfirm = true
            } label: {
                HStack {
                    // F6(2026-10-01):label 回升浓墨——原 inkMuted 灰字让重置行
                    // 看起来像禁用;与 Language / 子时行同权重,trailing 值保持弱色
                    Text("重置命盘")
                        .font(BaziFont.caption(size: 13))
                        .foregroundStyle(BaziTheme.ink)
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
        }
        .padding(.top, BaziTheme.Spacing.cmd)
    }

    // MARK: - 语言切换(D6/S4 + L1/F2 启动冻结)

    /// 语言**存储值**(用户选了什么;坏存储值防御回落 system,与 AppLanguage
    /// 口径一致)。非生效值——生效值重启才变(L1/F2)。
    /// 消费面:languageRestartPending 判定 + pending 小注/重启 alert 文案
    /// (设置行右侧显示的是**生效语言** endonym,由 launchOverride 驱动,
    /// 不在本属性——R9,2026-10-02 review 修正陈旧注释)。
    private var currentLanguageOverride: AppLanguage.Override {
        AppLanguage.overrideValue ?? .system
    }

    /// 是否存在未重启的语言变更(存储值 ≠ 启动快照)。
    /// L1/F2:重启前 App 冻结旧语言,这里为 true 时行下常驻 pending 小注;
    /// 重启后 freezeLaunchSnapshot 重写快照 → 两者相等 → 小注消失。
    private var languageRestartPending: Bool {
        currentLanguageOverride != AppLanguage.launchOverride
    }

    /// pending 小注文案(目标语言名跟随存储档;system 档单独措辞)。
    private var languageRestartPendingNote: String {
        if currentLanguageOverride == .system {
            return String(localized: "重启 App 后恢复跟随系统")
        }
        return String(
            format: String(localized: "重启 App 后切换为%@"),
            currentLanguageOverride.displayLabel
        )
    }

    /// 重启 alert 文案(L1/F2:明确「上滑关闭再打开」操作指引——iOS 的「重启」
    /// 需从多任务上滑杀进程,仅切后台不算;旧文案未讲清,用户以为已重启)。
    private var languageRestartAlertMessage: String {
        if currentLanguageOverride == .system {
            return String(localized: "请从后台上滑关闭 QiCompass 后重新打开，界面与命书、合盘、每日运势将恢复跟随系统语言。")
        }
        return String(
            format: String(localized: "请从后台上滑关闭 QiCompass 后重新打开，界面与命书、合盘、每日运势将全部切换为%@。"),
            currentLanguageOverride.displayLabel
        )
    }

    /// 应用语言覆盖:双轨写入(D6 方案 A)。
    /// ① appLanguageOverride(已由 @AppStorage 写入)→ 存储值,启动快照不动
    ///    (L1/F2:生效语言 / 缓存键 / X-QiCompass-Lang 冻结到重启,不再半生效);
    /// ② AppleLanguages 镜像 → String Catalog 走 Bundle 解析,重启后 UI 文案生效。
    /// system 档删除 AppleLanguages 恢复跟随系统。切换即弹重启提示(方案 A 既定 UX)。
    private func applyLanguageOverride(_ raw: String) {
        guard let override = AppLanguage.Override(rawValue: raw) else {
            // 坏值防御:不写 AppleLanguages,@AppStorage 已存原值,AppLanguage
            // 读取侧同样回落 system——显式留日志,不静默
            AppLogger.app.warning("op=profile.languageOverride.invalid raw=\(raw, privacy: .public)")
            return
        }
        let defaults = UserDefaults.standard
        switch override {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .zh:
            defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        case .zhHant:
            defaults.set(["zh-Hant"], forKey: "AppleLanguages")
        case .en:
            defaults.set(["en"], forKey: "AppleLanguages")
        }
        // 延迟呈现 alert:Menu 内 Picker 选择的 onChange 与菜单收起动画同 runloop,
        // 同步置位会被静默吞掉(2026-10-01 走查实测:选简体中文后零反馈,用户不知道
        // 要重启)。与 resetAllData 的 resetError workaround 同因(见彼处注释);
        // 但菜单收起是上下文菜单 presentation,比 confirmationDialog 收起慢,
        // runloop 一跳不够,再让出收起动画时长(500ms)。经验性 workaround,
        // 非 SwiftUI 契约保证。
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            showLanguageRestartAlert = true
        }
    }

    // MARK: - 关于(2026-08-13 onboarding 三屏重构:完整版立场/隐私下沉到此)

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(String(localized: "关 于"))

            // 立场(为什么可信 — Memorable Thing "专业不忽悠"的完整落点)
            VStack(spacing: 4) {
                Text(L10n.Profile.aboutStanceTitle)
                    .font(BaziFont.caption(size: 10))
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
            // 箭头字符对 VoiceOver 是噪音,统一读按钮语义
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
            // F1(2026-10-01)tracking 豁免之二:QICOMPASS 品牌字 LatinCaps
            // 大字距是 DESIGN.md 指纹(全页仅此处与 owner kicker 保留)
            Text("QICOMPASS")
                .font(BaziFont.latinCaps(size: 8))
                .tracking(4.5)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Text("玄机问道 · 专业不忽悠")
                .font(BaziFont.caption(size: 9.5))
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

    /// 分节标题(F1 2026-10-01):`display(17)` 浓墨锚点(EN serif medium /
    /// zh 楷体)——区块标题是整页层级锚点,不再靠字距撑;trailing 尾注
    /// caption(10.5) 无 tracking。
    /// 样式单点:roster 等需要组合尾注(文本 + 按钮)的节走 @ViewBuilder 重载,
    /// 改标题样式只改这一处(对齐 profileModel zodiacMode 的单点求值原则)。
    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        sectionHeader(title) {
            if let trailing {
                Text(trailing)
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                    .lineLimit(1)
            }
        }
    }

    /// sectionHeader 的组合尾注重载(F4 roster:同步尾注 + Edit 按钮同基线)。
    private func sectionHeader<Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(BaziFont.display(size: 17))
                .foregroundStyle(BaziTheme.ink)
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.bottom, 2)
    }

    // MARK: - 名册行内操作 / 补时辰

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
        case "bazi_deep":     return String(localized: "深度解析")
        case "compatibility": return String(localized: "合盘")
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
            // L2/F4:M4/M5 用户输入按盘存 UserDefaults(不在 SwiftData),随全量
            // 数据一并前缀清扫(隐私口径与命盘数据同级)
            DeepUserInputPersistence.clearAll()
            // F5(2026-10-06):M0 STALE 降级标记同存 UserDefaults,同批清扫
            // (命盘数据已全删,标记无主即噪音)
            DeepStaleM0MarkerPersistence.clearAll()
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
            let msg = String(localized: "重置未完成,数据未变更,请重试")
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

// MARK: - ZodiacAvatarMark(生肖头像位三态表达,S08)
// 2026-09-25 暗色走查 #11:本组件迁至 Shared/ZodiacHelper.swift(internal),
// 合盘配置页命主行与「我的」tab 名册共用同一头像语言(原合盘为 inkDeep 圆底首字,
// 暗色下反转成亮白圆,与生肖线稿体系割裂)。
