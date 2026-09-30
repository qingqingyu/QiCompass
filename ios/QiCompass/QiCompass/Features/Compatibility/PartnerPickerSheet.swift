import SwiftUI

// MARK: - 换人 sheet(P2/P3;S2 完整化,2026-09-29 结果页主页化)

/// NavigationStack push 路由(添加 / 修改表单页)。
enum PartnerPickerRoute: Hashable {
    case add
    case edit(RosterEntry)
}

/// 换人 sheet(P2/P3,2026-09-29 结果页主页化;S2 完整化):
/// - 行 = `PartnerRow`(日主五行色字 / 称呼 / 生日副行 / 行内朱圈勾选态),
///   点行 = `onPick` 原地换人(宿主关 sheet + `selectPartner`)
/// - 标题栏「选择对方」+ 右侧「管理 / 完成」(ink 色文字按钮,不用朱红)
/// - 管理模式:行尾换「修改」(仅临时人)+「移出」,**行主体不可点**(P1-2 修复
///   2026-09-30:误触换人会关 sheet 把用户弹出管理态);移出当前对方 → 勾选清空 +
///   宿主关 sheet(主页进 P6 态,不自动选下一位、不发请求)
/// - 尾部「＋ 添加对方」→ push `PartnerBirthForm` 添加页;提交 = 加入 + 选中 +
///   合盘(P4,修订 2026-09-03「添加与勾选解耦」——新模型没有「开始合盘」这一步)
/// - 修改当前对方且输入变化 → 保存后 force 重算;修改非当前对方不重算
/// - 他人无时辰行(S10 点击补时辰 / S11 置灰短注)、命主无时辰整列锁(S07)、
///   满员置灰(rosterMax)
struct PartnerPickerSheet: View {
    @Bindable var vm: CompatibilityViewModel
    /// 行点击(原地换人;宿主负责关 sheet + `vm.selectPartner`)。
    let onPick: (RosterEntry) -> Void
    /// sheet 内流程需要整体关闭时调(添加即合盘 / 移出当前对方后回 P6;
    /// 宿主只负责关 sheet,选中/重算逻辑在本 sheet 内完成)。
    var onClose: (() -> Void)? = nil
    /// S10:无时辰行 → 补时辰 sheet(宿主路由;换人 sheet 需先关再开,由宿主编排)。
    var onAddHour: ((String) -> Void)? = nil

    @State private var isManageMode = false
    @State private var tempRemovalCandidate: RosterEntry?
    @State private var path: [PartnerPickerRoute] = []

    private var isFull: Bool { vm.roster.count >= CompatibilityViewModel.rosterMax }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.CompatibilityPartner.choosePartner)
                        .font(BaziFont.display(size: 17))
                        .tracking(3)
                        .foregroundStyle(BaziTheme.ink)
                        .padding(.top, BaziTheme.Spacing.lg)

                    // 命主无时辰(S07 全锁):整列置灰不可点 + 解释 banner
                    if vm.isSelfHourUnknown {
                        RosterSelfLockBanner()
                    }

                    ForEach(rowModels) { row in
                        partnerRow(row)
                        Divider().background(BaziTheme.hairline)
                    }

                    addRow
                }
                .padding(.horizontal)
                .padding(.bottom, BaziTheme.Spacing.xl)
            }
            .background(BaziTheme.cardSurface)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // 管理 ↔ 完成(ink 色;不用朱红——朱红只留印章级)
                    Button {
                        HapticEngine.light()
                        isManageMode.toggle()
                    } label: {
                        Text(isManageMode
                             ? L10n.CompatibilityPartner.done
                             : L10n.CompatibilityPartner.manage)
                            .font(BaziFont.body(size: 15))
                            .foregroundStyle(BaziTheme.ink)
                    }
                }
            }
            .navigationDestination(for: PartnerPickerRoute.self) { route in
                PartnerBirthFormPage(vm: vm, route: route, onAdded: handleAdded, onUpdated: handleUpdated)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // 「移出」= 移出名单确认(需再填表单才能回来;沿用配置页时代文案)
        .confirmationDialog(
            L10n.CompatibilityPartner.removeConfirmTitle,
            isPresented: Binding(
                get: { tempRemovalCandidate != nil },
                set: { if !$0 { tempRemovalCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.CompatibilityPartner.removeConfirmAction, role: .destructive) {
                if let entry = tempRemovalCandidate {
                    removeEntry(entry)
                }
                tempRemovalCandidate = nil
            }
            Button(L10n.Common.cancel, role: .cancel) {
                tempRemovalCandidate = nil
            }
        } message: {
            if let entry = tempRemovalCandidate {
                Text(L10n.CompatibilityPartner.removeConfirmMessage(
                    vm.partnerDisplay(for: entry).name
                ))
            }
        }
    }

    // MARK: - 行模型(临时人置顶 → 跨启动恢复行 → 存档候选;与旧名单顺序一致)

    private struct PartnerRowModel: Identifiable {
        let entry: RosterEntry
        let display: PartnerDisplay
        /// roster 成员资格(管理模式的「修改/移出」只对成员有意义;名单外池候选
        /// 移出是 no-op,不渲染破坏性按钮)。
        let isMember: Bool
        /// 他人存档无时辰判据(S11;行渲染与满员拦截共用同一份,单次计算——
        /// `hourBlocked` 每次调用对存档行做 payload decode,不重复)。
        let isBlockedHour: Bool
        /// 满员拒收预禁用(roster 满 + 名单外 + 时辰已知的存档池候选行——点选走
        /// toggleArchived「加入」分支会被上限守卫静默拒收;VM 注释要求 UI 提前
        /// disable,与添加行置灰同一口径。无时辰行点击走 S10 补时辰,与容量无关,
        /// **不得**置灰)。
        let isFullBlocked: Bool
        var id: String { entry.id }
    }

    private var rowModels: [PartnerRowModel] {
        // 满员时名单外的时辰已知存档行不可加(toggleArchived 上限守卫会拒收)
        let fullBlocked = isFull
        func model(_ entry: RosterEntry) -> PartnerRowModel {
            let notInRoster = !vm.roster.contains { $0.id == entry.id }
            let blockedHour = hourBlocked(entry)
            return PartnerRowModel(
                entry: entry,
                display: vm.partnerDisplay(for: entry),
                isMember: !notInRoster,
                isBlockedHour: blockedHour,
                isFullBlocked: fullBlocked && notInRoster && !blockedHour
            )
        }
        var rows: [PartnerRowModel] = vm.roster
            .filter(\.isTemp)
            .map(model)
        rows += vm.roster
            .filter { entry in
                guard case .archived(let hash) = entry else { return false }
                return !vm.isPoolBacked(hash: hash)
            }
            .map(model)
        let currentA = vm.currentPersonAHash
        rows += vm.archivedCharts
            .filter { $0.snapshotHash != currentA }
            .map { chart in
                // 池行候选(含已选中的池行——展示复用 VM 派生,勾选态由行自表达)
                model(.archived(snapshotHash: chart.snapshotHash))
            }
        return rows
    }

    // MARK: - 行渲染

    @ViewBuilder
    private func partnerRow(_ row: PartnerRowModel) -> some View {
        PartnerRow(
            display: row.display,
            isSelected: vm.selectedEntryIds.contains(row.entry.id),
            isLocked: vm.isSelfHourUnknown,
            isBlockedHour: row.isBlockedHour,
            isManageMode: isManageMode,
            canEdit: row.entry.isTemp,
            isMember: row.isMember,
            isFullBlocked: row.isFullBlocked,
            onTap: {
                guard !vm.isSelfHourUnknown else { return }
                if row.isBlockedHour {
                    // S10 优先直达补时辰;无宿主退回 S11 轻提示(不弹 sheet 不可选)
                    HapticEngine.light()
                    if let onAddHour, case .archived(let hash) = row.entry {
                        onAddHour(hash)
                    }
                    return
                }
                onPick(row.entry)
            },
            onEdit: {
                // 回填失败(非 temp / 钟面串解析失败,VM 已记日志)不进表单页
                guard vm.beginEditTempEntry(row.entry) else { return }
                path.append(.edit(row.entry))
            },
            onRemove: { tempRemovalCandidate = row.entry }
        )
    }

    /// 他人存档无时辰判据(S11,与 S07 computePair 拦截同源;临时人恒带完整钟面)。
    private func hourBlocked(_ entry: RosterEntry) -> Bool {
        guard case .archived(let hash) = entry else { return false }
        return vm.isArchivedHourUnknown(hash: hash)
    }

    // MARK: - 尾部添加行(满员置灰)

    private var addRow: some View {
        Button {
            guard !isFull else { return }
            path.append(.add)
        } label: {
            HStack(spacing: 13) {
                Circle()
                    .stroke(BaziTheme.hairlineDashed, lineWidth: 1.4)
                    .frame(width: 22, height: 22)
                    .overlay(Text("＋").font(.caption).foregroundStyle(BaziTheme.inkMuted))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.CompatibilityPartner.addPartner)
                        .font(BaziFont.body())
                        .foregroundStyle(isFull ? BaziTheme.inkMutedSecondary : BaziTheme.ink)
                    Text(isFull
                         ? L10n.CompatibilityPartner.rosterFullHint(CompatibilityViewModel.rosterMax)
                         : String(localized: "不建档案 · 填出生信息即可"))
                        .font(BaziFont.caption(size: 10))
                        .tracking(0.5)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                Spacer()
            }
            .padding(.vertical, 14)
            .opacity(isFull ? 0.45 : 1)
        }
        .disabled(isFull)
    }

    // MARK: - 表单成功路径(P4 加入即合盘 / 修改当前对方 force 重算)

    /// 添加成功(P4):加入名单即选中并立即合盘,关 sheet 看原地推演。
    private func handleAdded(_ entry: RosterEntry) {
        vm.selectPartner(entry)
        onClose?()
    }

    /// 修改成功:改的是**当前对方**且输入变了 → force 重算(绕过同人 no-op);
    /// 非当前对方 / 输入未变 → 只回列表(不重算)。
    private func handleUpdated(old: RosterEntry, new: RosterEntry) {
        let wasCurrent = vm.selectedEntryIds.contains(new.id)
        if wasCurrent && new.id != old.id {
            vm.selectPartner(new, force: true)
            onClose?()
        } else {
            path.removeAll()
        }
    }

    /// 移出名单:当前对方被移出 → 勾选随清(removeRosterEntry)+ 切出 detail 态
    /// (clearDetailKeepRoster 兼任 cancel;S3 起 .configuring 渲染为结果壳 P6 态),
    /// 不自动选下一位(避免隐式发起合盘请求);非当前对方 → 留在列表。
    private func removeEntry(_ entry: RosterEntry) {
        let wasCurrent = vm.selectedEntryIds.contains(entry.id)
        vm.removeRosterEntry(entry)
        if wasCurrent {
            vm.clearDetailKeepRoster()
            onClose?()
        }
    }
}

// MARK: - 表单页(NavigationStack push 形态)

/// 添加/修改对方表单页(换人 sheet 内 push;系统返回手势/按钮 = 不保存返回)。
/// 离开页面(返回或整体关 sheet)时还原添加草稿(beginEditTempEntry 覆盖过 vm.temp*)。
private struct PartnerBirthFormPage: View {
    @Bindable var vm: CompatibilityViewModel
    let route: PartnerPickerRoute
    let onAdded: (RosterEntry) -> Void
    let onUpdated: (RosterEntry, RosterEntry) -> Void

    private var editing: RosterEntry? {
        if case .edit(let entry) = route { return entry }
        return nil
    }

    private var isEditing: Bool { editing != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(isEditing
                     ? L10n.CompatibilityPartner.formTitleEdit
                     : L10n.CompatibilityPartner.formTitleAdd)
                    .font(BaziFont.display(size: 17))
                    .tracking(3)
                    .foregroundStyle(BaziTheme.ink)

                PartnerBirthForm(
                    vm: vm,
                    editing: editing,
                    onAdded: onAdded,
                    onUpdated: onUpdated,
                    footnote: isEditing
                        ? L10n.CompatibilityPartner.formFootnoteEdit
                        : L10n.CompatibilityPartner.formFootnoteAdd
                )
            }
            .padding(24)
        }
        .background(BaziTheme.cardSurface)
        // 修改态离开(保存成功关 sheet / 返回取消 / 下滑关 sheet)统一还原添加草稿
        .onDisappear {
            if isEditing {
                vm.resetTempDraftForm()
            }
        }
    }
}

// MARK: - 名单行(S2 新组件:替换 sheet 内对 RosterUnifiedListView 的复用)

/// 换人 sheet 名单行:日主字(五行色)/ 称呼 / 生日副行 / 尾部状态。
/// - 选中态:行内朱圈(印章级小元素既有用法,不扩大)+ 行底 cinnabarSoft
/// - 他人无时辰:副行换 S11 mark 短注,点击走 S10 补时辰(与容量无关,永不因满员置灰)
/// - 命主无时辰:置灰不可点
/// - 满员 + 名单外时辰已知存档候选:置灰不可点(toggleArchived 上限守卫会静默拒收,
///   VM 注释要求 UI 提前 disable;口径同添加行满员置灰)
/// - 管理模式:**行主体不可点**(P1-2 修复 2026-09-30——点行 = 换人 + 关 sheet,
///   会把用户弹出管理态),修改/移出只走行尾控件;尾部换「修改」(仅临时人)+
///   「移出」(仅 roster 成员;名单外池候选无管理动作,也不画选中圈——行不可选,
///   圈是误导)
private struct PartnerRow: View {
    let display: PartnerDisplay
    let isSelected: Bool
    let isLocked: Bool
    let isBlockedHour: Bool
    let isManageMode: Bool
    /// 「修改」按钮可用性(仅临时人——本地有完整表单数据可回填)。
    let canEdit: Bool
    /// roster 成员资格(管理模式「修改/移出」只对成员渲染;名单外池候选回落
    /// 选中圈——移出对非成员是 no-op,不渲染破坏性按钮)。
    let isMember: Bool
    /// 满员拒收预禁用(名单外时辰已知存档候选;置灰 + 不可点)。
    let isFullBlocked: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    private var isGreyed: Bool { isLocked || isFullBlocked }

    var body: some View {
        Button {
            // P1-2(2026-09-30):管理模式下行主体不换人——误触 = 换人 + 关 sheet,
            // 把用户弹出管理态;修改/移出只走行尾控件。故意不用
            // `.disabled(isManageMode)`:disabled 经 environment 向下传播,会连带
            // 禁用嵌套在行内的「修改/移出」按钮,管理模式就失效了。
            guard !isManageMode else { return }
            onTap()
        } label: {
            HStack(spacing: 13) {
                dayMasterAvatar
                VStack(alignment: .leading, spacing: 4) {
                    Text(display.name)
                        .font(BaziFont.body())
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundStyle(isGreyed ? BaziTheme.inkMuted : BaziTheme.ink)
                    // 他人无时辰 → 副行换成 S11 mark(短注替代表现)
                    Text(isBlockedHour
                         ? L10n.CompatibilityRosterGate.mark
                         : sublineText)
                        .font(BaziFont.caption(size: 10))
                        .tracking(0.5)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                Spacer()
                if isManageMode && isMember {
                    manageTrailing
                } else if !isManageMode {
                    // 管理模式非成员行不画圈:行主体不可选,选中圈是误导
                    selectionCircle
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // 选中态行底 cinnabarSoft(极少量);未选/全锁 clear
                !isLocked && isSelected && !isManageMode
                    ? BaziTheme.cinnabarSoft
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
            )
            .opacity(isFullBlocked ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isLocked || isFullBlocked)
        .accessibilityHint(isManageMode
                           ? L10n.CompatibilityPartner.rowManageHint
                           : (isSelected
                              ? L10n.CompatibilityPartner.rowSelectedHint
                              : L10n.CompatibilityPartner.rowSwitchHint))
    }

    /// 副行:生日(日主已由头像字承载,不重复)。
    private var sublineText: String {
        display.birthDateString ?? "—"
    }

    /// 日主字头像(五行色;未知 → 「—」墨色,不猜)。
    private var dayMasterAvatar: some View {
        let gan = display.dayMaster.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
        let color = (gan == "—" || display.dayMasterElementKey == nil)
            ? BaziTheme.inkMuted
            : BaziTheme.elementColor(display.dayMasterElementKey ?? "")
        return Text(gan)
            .font(BaziFont.ganzhi(size: 15))
            .foregroundStyle(isGreyed ? BaziTheme.inkMuted : color)
            .frame(width: 30, height: 30)
            .overlay(
                RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                    .stroke(BaziTheme.hairline, lineWidth: 0.8)
            )
    }

    /// 选中态:朱圈 + 勾(沿用名单行「行内朱圈」表达;全锁/无时辰/满员拒收行不画圈)。
    @ViewBuilder
    private var selectionCircle: some View {
        if isBlockedHour || isLocked || isFullBlocked {
            // S11/S07/满员 留白:不可选行不画圈(无勾选位,水墨留白表达)
            EmptyView()
        } else if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(BaziTheme.cinnabar)
        } else {
            Image(systemName: "circle")
                .font(.body)
                .foregroundStyle(BaziTheme.inkMuted.opacity(0.5))
        }
    }

    /// 管理模式行尾:「修改」(仅临时人)+「移出」(全锁置灰)。
    @ViewBuilder
    private var manageTrailing: some View {
        HStack(spacing: 4) {
            if canEdit {
                Button(action: onEdit) {
                    Text(L10n.CompatibilityPartner.rowEdit)
                        .font(BaziFont.caption(size: 10))
                        .tracking(1)
                        .foregroundStyle(isLocked ? BaziTheme.inkMutedSecondary : BaziTheme.inkMuted)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .disabled(isLocked)
                .accessibilityLabel(L10n.CompatibilityPartner.rowEditA11y(display.name))
            }
            Button(action: onRemove) {
                Text(L10n.CompatibilityPartner.rowRemove)
                    .font(BaziFont.caption(size: 10))
                    .tracking(1)
                    .foregroundStyle(isLocked ? BaziTheme.inkMutedSecondary : BaziTheme.inkMuted)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            .disabled(isLocked)
            .accessibilityLabel(L10n.CompatibilityPartner.rowRemoveA11y(display.name))
        }
    }
}
