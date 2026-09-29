import SwiftUI

/// 换人 sheet(P2/P3;S1 最小版,2026-09-29 结果页主页化):
/// 内嵌 NavigationStack(S2 表单 push 预留)+ 复用 `RosterUnifiedListView`,
/// 行点击语义从「切换勾选」改为 **onPick 原地换人**(宿主关 sheet + `selectPartner`)。
///
/// S1 期行为:
/// - 添加/修改/移出沿用配置页同一组件(`AddPersonSheet` + confirmationDialog),
///   加入名单暂不自动勾选——P4「加入即选中并合盘」在 S2 抽 `PartnerBirthForm` 时落地
/// - 无时辰行(S10 补时辰直达 / S11 置灰)、命主无时辰整列锁(S07)随复用组件原样保留
///
/// S2 完整化:PartnerRow 行组件(朱圈勾选态)、管理模式、sheet 内添加即合盘、满员提示收敛。
struct PartnerPickerSheet: View {
    @Bindable var vm: CompatibilityViewModel
    /// 行点击(原地换人;宿主负责关 sheet + `vm.selectPartner`)。
    let onPick: (RosterEntry) -> Void
    /// S10:无时辰行 → 补时辰 sheet(宿主路由;换人 sheet 需先关再开,由宿主编排)。
    var onAddHour: ((String) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    /// 添加/修改对方半屏 sheet(与配置页同一组件双模式)。
    @State private var personSheetMode: PersonSheetMode?
    /// 修改态标记:onDismiss 时还原添加草稿(beginEditTempEntry 覆盖了 vm.temp* 字段)。
    @State private var sheetWasEdit = false
    /// 临时人行移出确认(防误删,与配置页同款)。
    @State private var tempRemovalCandidate: RosterEntry?
    /// 最近经 sheet 加入的临时人 id(该行标「新」朱印)。
    @State private var newlyAddedTempId: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.CompatibilityPartner.choosePartner)
                        .font(BaziFont.display(size: 17))
                        .tracking(3)
                        .foregroundStyle(BaziTheme.ink)
                        .padding(.top, BaziTheme.Spacing.lg)

                    RosterUnifiedListView(
                        charts: vm.archivedCharts,
                        excludedHash: vm.currentPersonAHash,
                        roster: vm.roster,
                        rosterMax: CompatibilityViewModel.rosterMax,
                        selectedHashes: vm.selectedArchivedHashes,
                        tempRows: vm.roster.compactMap(tempRowModel(for:)),
                        orphanRows: vm.roster.compactMap(orphanRowModel(for:)),
                        isHourUnknown: { vm.isArchivedHourUnknown(hash: $0) },
                        isSelfHourUnknown: vm.isSelfHourUnknown,
                        onToggleArchived: { hash in pick(.archived(snapshotHash: hash)) },
                        onToggleTemp: { entry in pick(entry) },
                        onEditTemp: { entry in
                            // 回填失败(非 temp / 钟面串解析失败,VM 已记日志)不开 sheet
                            guard vm.beginEditTempEntry(entry) else { return }
                            sheetWasEdit = true
                            personSheetMode = .edit(entry)
                        },
                        onRemoveTemp: { tempRemovalCandidate = $0 },
                        onAddHour: onAddHour,
                        onAdd: { personSheetMode = .add },
                        newEntryId: newlyAddedTempId
                    )
                }
                .padding(.horizontal)
                .padding(.bottom, BaziTheme.Spacing.xl)
            }
            .background(BaziTheme.cardSurface)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.CompatibilityPartner.done) {
                        dismiss()
                    }
                    .foregroundStyle(BaziTheme.ink)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // 添加/修改对方:同一半屏 sheet 双模式(与配置页同款;修改态关闭还原添加草稿)
        .sheet(item: $personSheetMode, onDismiss: {
            if sheetWasEdit {
                vm.resetTempDraftForm()
                sheetWasEdit = false
            }
        }) { mode in
            switch mode {
            case .add:
                AddPersonSheet(vm: vm) { added in
                    newlyAddedTempId = added.id
                }
            case .edit(let entry):
                AddPersonSheet(vm: vm, editing: entry)
            }
        }
        // 「移出」= 移出名单确认(需再填表单才能回来)
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

    /// 行点击:点当前已选者的 no-op 判定在 VM(`selectPartner` 守卫),
    /// sheet 侧恒回调宿主(宿主统一关 sheet)。
    private func pick(_ entry: RosterEntry) {
        onPick(entry)
    }

    // MARK: - 名单行展示派生(S1 期与 CompatibilityConfigView 同款;S2 抽 PartnerRow 时收敛)

    private func tempRowModel(for entry: RosterEntry) -> TempRowModel? {
        guard case .temp = entry else { return nil }
        return TempRowModel(
            entry: entry,
            name: displayLabel(for: entry),
            subtitle: subtitleLabel(for: entry),
            isSelected: vm.selectedEntryIds.contains(entry.id)
        )
    }

    private func orphanRowModel(for entry: RosterEntry) -> TempRowModel? {
        guard case .archived(let hash) = entry,
              !vm.isPoolBacked(hash: hash) else { return nil }
        return TempRowModel(
            entry: entry,
            name: displayLabel(for: entry),
            subtitle: String(localized: "上次合盘保留的对方"),
            isSelected: vm.selectedEntryIds.contains(entry.id)
        )
    }

    private func displayLabel(for entry: RosterEntry) -> String {
        switch entry {
        case .archived(let hash):
            return vm.archivedCharts.first { $0.snapshotHash == hash }?.alias ?? String(localized: "未知存档")
        case .temp(let input, let alias, _, _):
            if let alias, !alias.isEmpty { return alias }
            let loc = input.placeName ?? String(format: String(localized: "经度 %@"), String(format: "%.1f", input.longitude))
            return String(format: String(localized: "对方 · %@ · %@"), input.wallClockDisplay, loc)
        }
    }

    private func subtitleLabel(for entry: RosterEntry) -> String {
        guard case .temp(let input, let alias, _, _) = entry else { return "" }
        let loc = input.placeName ?? String(format: String(localized: "经度 %@"), String(format: "%.1f", input.longitude))
        return (alias?.isEmpty == false) ? String(format: String(localized: "%@ · %@"), input.wallClockDisplay, loc) : loc
    }
}
