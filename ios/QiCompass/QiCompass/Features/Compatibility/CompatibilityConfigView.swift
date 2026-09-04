import SwiftUI

/// 合盘配置态(2026-09-02 定稿「名单合一 · 勾选即选」,读查平铺单屏):
/// 标题区 → 命主行(A 盘单行+更换 menu)→ 「选择对方」单一名单(存档勾选+快速行混排)
/// → 底部「排 N 对合盘」动态计数 CTA。
///
/// 事实源:`~/.gstack/projects/qingqingyu-QiCompass/designs/hepan-picker-20260902/finalized.html`
/// - 添加面板 = 半屏 sheet(`AddPersonSheet`),加入即关(修复旧内联表单 `showTempForm`
///   无收回路径的缺口)
/// - 2026-09-03 修订:添加与勾选解耦——加入名单的新行**未勾选**,是否排盘由用户
///   在名单上显式勾选(VM `selectedEntryIds`);取消勾选不再移出名单,移出走「移出」
///   小按钮 + 确认。修订 09-02 定稿「加入即自动勾选」一条。
/// - 命主无时辰(S07 全锁):命主行「补时辰」直达 + banner + CTA 文案化置灰
/// - 他人无时辰行保留 S10(点击补时辰)/ S11(置灰短注)
/// - 决策 D1-D13 红线不动(见 docs/合盘多选设计决策.md;roster 勾选语义按上方修订)
///
/// 2026-08-16:「合盘维度」picker 移除,context 固定 "general"(VM 注释)。
struct CompatibilityConfigView: View {
    @Bindable var vm: CompatibilityViewModel
    let onStart: () -> Void
    /// S10:点击「不可合盘」标记行 → 打开该盘补时辰 sheet(D7 触点 1 的他人盘分支)。
    var onAddHour: ((String) -> Void)? = nil

    /// 添加对方半屏 sheet(定稿③④⑤)。
    @State private var showAddSheet = false
    /// 临时人行取消勾选确认(定稿:防误删——移出后重加需再填表单)。
    @State private var tempRemovalCandidate: RosterEntry?
    /// 定稿⑤:最近经 sheet 加入的临时人 id(该行标「新」朱印;视图重建自然清除)。
    @State private var newlyAddedTempId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                // 命主行(A 盘,定稿⑧:单行 + 更换 menu / 无时辰 → 补时辰)
                PersonARowView(
                    charts: vm.archivedCharts,
                    selectedIndex: vm.selectedChartAIndex,
                    rosterHashes: vm.selectedArchivedHashes,
                    isHourUnknown: vm.isSelfHourUnknown,
                    onSelect: { vm.selectedChartAIndex = $0 },
                    onAddHour: {
                        guard let aHash = vm.currentPersonAHash else { return }
                        onAddHour?(aHash)
                    }
                )

                // 命主无时辰 → 整列锁定解释行(定稿⑦;dashed = 锁框/临时态)
                if vm.isSelfHourUnknown {
                    Text(L10n.CompatibilityRosterGate.selfBanner)
                        .font(BaziFont.caption(size: 11.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMuted)
                        .padding(BaziTheme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(
                            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                                .stroke(BaziTheme.hairlineDashed, lineWidth: 1)
                        )
                }

                // 单一名单(定稿②:存档勾选 + 快速行混排 + 尾部添加行)
                RosterUnifiedListView(
                    charts: vm.archivedCharts,
                    excludedHash: vm.currentPersonAHash,
                    roster: vm.roster,
                    rosterMax: CompatibilityViewModel.rosterMax,
                    selectedHashes: vm.selectedArchivedHashes,
                    selectedCount: vm.selectedRosterEntries.count,
                    tempRows: vm.roster.compactMap(tempRowModel(for:)),
                    orphanRows: vm.roster.compactMap(orphanRowModel(for:)),
                    isHourUnknown: { vm.isArchivedHourUnknown(hash: $0) },
                    isSelfHourUnknown: vm.isSelfHourUnknown,
                    onToggleArchived: { vm.toggleArchived(hash: $0) },
                    onToggleTemp: { vm.toggleEntrySelection($0) },
                    onRemoveTemp: { tempRemovalCandidate = $0 },
                    onAddHour: onAddHour,
                    onAdd: { showAddSheet = true },
                    newEntryId: newlyAddedTempId
                )

                if case .failed(let userError) = vm.state {
                    Text(userError.errorDescription ?? "未知错误")
                        .font(BaziFont.caption(size: 12))
                        .foregroundStyle(BaziTheme.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(BaziTheme.Spacing.md)
                        .background(BaziTheme.destructive.opacity(0.1), in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 100)  // 给底部 CTA 留位
        }
        .onChange(of: vm.selectedChartAIndex) { _, _ in
            // A 盘切换兜底剔除(menu 已置灰名单中的人,此处与 VM is_person_a 守卫同向三保险)
            if let aHash = vm.currentPersonAHash,
               vm.selectedArchivedHashes.contains(aHash) {
                vm.toggleArchived(hash: aHash)
            }
        }
        .onChange(of: vm.roster) { old, new in
            // 定稿⑤:sheet 加入的临时人行标「新」朱印(id diff;存档勾选不标)
            let oldIds = Set(old.map(\.id))
            if let added = new.first(where: { $0.isTemp && !oldIds.contains($0.id) }) {
                newlyAddedTempId = added.id
            }
        }
        .safeAreaInset(edge: .bottom) {
            // 2026-09-03:CTA 计数/摘要按勾选子集(名单成员未勾选不进)
            let cta = CompatibilityConfigCTAModel.derive(
                selectedCount: vm.selectedRosterEntries.count,
                selectedNames: vm.selectedRosterEntries.map(displayLabel(for:)),
                isSelfHourUnknown: vm.isSelfHourUnknown
            )
            Button(action: onStart) {
                VStack(spacing: 7) {
                    HStack {
                        Text(cta.title)
                            .font(BaziFont.button(size: 15.5))
                            .tracking(3)
                        if cta.isEnabled {
                            // 朱印级小点(印章语义:落印即排盘)
                            Rectangle()
                                .fill(BaziTheme.cinnabar)
                                .frame(width: 6, height: 6)
                                .rotationEffect(.degrees(45))
                        }
                    }
                    Text(cta.note)
                        .font(BaziFont.caption(size: 10))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                .foregroundStyle(cta.isEnabled ? BaziTheme.onInkDeep : BaziTheme.inkMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    cta.isEnabled ? BaziTheme.inkDeep : BaziTheme.inkDeep.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(BaziTheme.paper.opacity(0.95))
            }
            .disabled(!cta.isEnabled)
        }
        // 添加对方:半屏 sheet,加入即关(新行落位未勾选,2026-09-03 修订)
        .sheet(isPresented: $showAddSheet) {
            AddPersonSheet(vm: vm)
        }
        // 「移出」按钮 = 移出名单(需再填表单才能回来,确认防误删)
        .confirmationDialog(
            "移出名单?",
            isPresented: Binding(
                get: { tempRemovalCandidate != nil },
                set: { if !$0 { tempRemovalCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移出名单", role: .destructive) {
                if let entry = tempRemovalCandidate {
                    vm.removeRosterEntry(entry)
                }
                tempRemovalCandidate = nil
            }
            Button("取消", role: .cancel) {
                tempRemovalCandidate = nil
            }
        } message: {
            if let entry = tempRemovalCandidate {
                Text("「\(displayLabel(for: entry))」移出后,重新加入需再填一次出生信息。")
            }
        }
    }

    // MARK: - 标题区(定稿②)

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("合盘 · 两人磁场合拍")
                .font(BaziFont.caption(size: 10))
                .tracking(4)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Text("选择对方")
                .font(BaziFont.display(size: 24))
                .foregroundStyle(BaziTheme.ink)
            Text("勾选即入本次合盘 · 每对独立成盘,各自单独解锁")
                .font(BaziFont.caption(size: 11.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    // MARK: - 名单行展示派生

    /// 临时人行展示模型(名称 / 副行 / badge「快速」/ 勾选态;从 RosterEntry 派生)。
    private func tempRowModel(for entry: RosterEntry) -> TempRowModel? {
        guard case .temp = entry else { return nil }
        return TempRowModel(
            entry: entry,
            name: displayLabel(for: entry),
            subtitle: subtitleLabel(for: entry),
            badge: "快速",
            isSelected: vm.selectedEntryIds.contains(entry.id)
        )
    }

    /// 跨启动恢复行(S06:临时人持久化为 `.archived` hash、无 UserSnapshotLink,
    /// 不在 `archivedCharts` 内)——候选区无对应行,单独补一行保可见、可移出。
    /// 承接旧「已加入名单」区的 roster 全覆盖语义,防止 CTA 计入隐形成员。
    private func orphanRowModel(for entry: RosterEntry) -> TempRowModel? {
        guard case .archived(let hash) = entry,
              !vm.isPoolBacked(hash: hash) else { return nil }
        return TempRowModel(
            entry: entry,
            name: displayLabel(for: entry),
            subtitle: "上次合盘保留的对方",
            badge: "存档",
            isSelected: vm.selectedEntryIds.contains(entry.id)
        )
    }

    /// 名单行主名(与 VM 兜底名策略一致:alias 或「对方 · 钟面 · 地点」)。
    private func displayLabel(for entry: RosterEntry) -> String {
        switch entry {
        case .archived(let hash):
            return vm.archivedCharts.first { $0.snapshotHash == hash }?.alias ?? "未知存档"
        case .temp(let input, let alias, _):
            if let alias, !alias.isEmpty { return alias }
            // birthDatetime 已是裸钟面字符串,直接读(= 出生地钟面,无时区换算问题)
            let loc = input.placeName ?? "经度 \(String(format: "%.1f", input.longitude))"
            return "对方 · \(input.wallClockDisplay) · \(loc)"
        }
    }

    /// 临时人行副行(出生钟面 + 地点;主名有 alias 时副行补全信息,无 alias 时降级为地点)。
    /// 仅 .temp entry 会走到此处(tempRowModel 已 guard)。
    private func subtitleLabel(for entry: RosterEntry) -> String {
        guard case .temp(let input, let alias, _) = entry else { return "" }
        let loc = input.placeName ?? "经度 \(String(format: "%.1f", input.longitude))"
        return (alias?.isEmpty == false) ? "\(input.wallClockDisplay) · \(loc)" : loc
    }
}

// MARK: - CTA 派生模型(定稿:三态文案)

/// 配置页底部 CTA 三态(纯值,单测覆盖):
/// - `.ready`:「排 N 对合盘」+ 勾选摘要注(前 2 名 + 等 N 位)
/// - `.emptyRoster`:置灰「先勾选对方」(决策 D13 零勾选拦截的前移表达;
///   2026-09-03 起名单非空但零勾选同态)
/// - `.selfHourUnknown`:置灰「补全时辰后可合盘」(S07 全锁的文案化)
struct CompatibilityConfigCTAModel: Equatable {
    enum Kind: Equatable {
        case ready(count: Int, namesSummary: String)
        case emptyRoster
        case selfHourUnknown
    }

    let kind: Kind

    var title: String {
        switch kind {
        case .ready(let count, _): return "排 \(count) 对合盘"
        case .emptyRoster: return "先勾选对方"
        case .selfHourUnknown: return "补全时辰后可合盘"
        }
    }

    var note: String {
        switch kind {
        case .ready(_, let namesSummary): return "\(namesSummary) · 每对独立解锁"
        case .emptyRoster: return "勾选后即可排盘 · 上限 \(CompatibilityViewModel.rosterMax) 位"
        case .selfHourUnknown: return "时辰影响日柱,补全即恢复全部配对"
        }
    }

    var isEnabled: Bool {
        if case .ready = kind { return true }
        return false
    }

    /// - Parameters:
    ///   - selectedCount: 已勾选人数(2026-09-03 起按勾选子集计,非名单成员数)
    ///   - selectedNames: 已勾选人名(顺序即 roster 顺序)
    ///   - isSelfHourUnknown: 命主无时辰(S07 全锁优先于零勾选展示)
    static func derive(selectedCount: Int, selectedNames: [String], isSelfHourUnknown: Bool) -> Self {
        if isSelfHourUnknown {
            return Self(kind: .selfHourUnknown)
        }
        guard selectedCount > 0 else {
            return Self(kind: .emptyRoster)
        }
        // 防御:names 与 count 长度不一致(或含空名)时不产出前导分隔符
        let names = selectedNames.prefix(2).filter { !$0.isEmpty }
        let suffix = selectedCount > 2 ? " 等 \(selectedCount) 位" : ""
        let namesSummary = names.isEmpty
            ? "\(selectedCount) 对"
            : names.joined(separator: " · ") + suffix + " · \(selectedCount) 对"
        return Self(kind: .ready(count: selectedCount, namesSummary: namesSummary))
    }
}

// MARK: - 添加对方半屏 sheet(定稿③④)

/// 快速添加表单(称呼/出生时间/性别/出生城市,复用 VM `temp*` 草稿字段)。
/// 加入成功 → sheet 自动关闭(新行入名单、**未勾选**,2026-09-03 修订:
/// 添加=入册,勾选=入本次合盘,两逻辑解耦);失败 → 留在 sheet 显人话错误。
/// 下滑手势即收(系统 sheet 能力,定稿对「面板收不回」的修复主体)。
private struct AddPersonSheet: View {
    @Bindable var vm: CompatibilityViewModel
    @Environment(\.dismiss) private var dismiss

    /// sheet 内表单错误(定稿④:重复添加等校验错误留在 sheet 内,不关不吞)。
    @State private var formError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("添加对方")
                        .font(BaziFont.display(size: 17))
                        .tracking(3)
                        .foregroundStyle(BaziTheme.ink)
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("取消")
                            .font(BaziFont.caption(size: 12.5))
                            .foregroundStyle(BaziTheme.inkMuted)
                    }
                }

                // 可选「称呼」字段(留空走兜底名「对方+出生日期」)
                HStack {
                    Text("称呼").foregroundStyle(BaziTheme.inkMuted)
                        .font(BaziFont.caption(size: 12))
                    TextField("可选,如「相亲对象甲」", text: $vm.tempAlias)
                        .font(BaziFont.body(size: 14))
                        .foregroundStyle(BaziTheme.ink)
                        .padding(BaziTheme.Spacing.sm)
                        .background(BaziTheme.paper, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.sm).stroke(BaziTheme.hairline, lineWidth: 0.5))
                }

                DatePicker(
                    "出生时间",
                    selection: $vm.tempBirthDate,
                    in: ...Date(),
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.compact)
                .font(BaziFont.body(size: 14))
                .foregroundStyle(BaziTheme.ink)
                // WYSIWYG:表盘按对方出生地时区(S05;解释责任在后端 zoneinfo)
                .environment(\.calendar, vm.tempPlaceCalendar)

                Picker("性别", selection: $vm.tempGender) {
                    Text("男").tag("male")
                    Text("女").tag("female")
                }
                .pickerStyle(.segmented)

                // S05:全球城市搜索 + sheet 内自定义地点(与深度解析同一组件)
                CityPickerField(selection: $vm.tempPlace)

                if let formError {
                    Text(formError)
                        .font(BaziFont.caption(size: 11))
                        .foregroundStyle(BaziTheme.destructive)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    addTemp()
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("加入名单")
                    }
                    .font(BaziFont.button(size: 15))
                    .foregroundStyle(formError == nil ? BaziTheme.onInkDeep : BaziTheme.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        // 定稿④:错误态 CTA 置灰(改任一字段即重新可用,错误同时清除)
                        formError == nil ? BaziTheme.inkDeep : BaziTheme.inkDeep.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: 5)
                    )
                }
                .disabled(vm.roster.count >= CompatibilityViewModel.rosterMax || formError != nil)

                Text("加入名单后自行勾选 · 下滑可随时收起")
                    .font(BaziFont.caption(size: 10))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
        }
        .background(BaziTheme.cardSurface)
        .presentationDetents([.medium, .large])
        // 定稿③:grab handle 显式可见(系统对自定义 detents 不保证默认显示)
        .presentationDragIndicator(.visible)
        // 定稿④配套:任一字段变更即清错误(重复/校验错误不再黏住,CTA 随之恢复)
        .onChange(of: vm.tempAlias) { _, _ in formError = nil }
        .onChange(of: vm.tempBirthDate) { _, _ in formError = nil }
        .onChange(of: vm.tempGender) { _, _ in formError = nil }
        .onChange(of: vm.tempPlace) { _, _ in formError = nil }
    }

    private func addTemp() {
        do {
            try vm.addTempToRoster()
            // 成功:关 sheet(新行已入名单、未勾选)+ 清草稿,可重开连加
            vm.resetTempDraftForm()
            dismiss()
        } catch {
            // 不静默吞(CLAUDE.md):UserFacingError(表单校验/重复)文案原样留在 sheet;
            // 意外错误(存储层)记日志 + 人话兜底
            if let userError = error as? UserFacingError {
                formError = userError.errorDescription
            } else {
                AppLogger.app.error(
                    "compat.addTemp.unexpected_error error=\(String(describing: error), privacy: .public)"
                )
                formError = "添加失败,请重试"
            }
        }
    }
}
