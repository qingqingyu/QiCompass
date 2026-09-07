import SwiftUI

/// 合盘配置态(2026-09-02 定稿「名单合一 · 勾选即选」,读查平铺单屏):
/// 标题区 → 命主行(A 盘纯展示)→ 「选择对方」单一名单(存档勾选+快速行混排)
/// → 底部「开始合盘」CTA(2026-09-07 单选:唯一点选者进文案)。
///
/// 事实源:`~/.gstack/projects/qingqingyu-QiCompass/designs/hepan-picker-20260902/finalized.html`
/// - 添加面板 = 半屏 sheet(`AddPersonSheet`),加入即关(修复旧内联表单 `showTempForm`
///   无收回路径的缺口)
/// - 2026-09-03 修订:添加与勾选解耦——加入名单的新行**未勾选**,是否排盘由用户
///   在名单上显式勾选(VM `selectedEntryIds`);取消勾选不再移出名单,移出走「移出」
///   小按钮 + 确认。修订 09-02 定稿「加入即自动勾选」一条。
/// - 2026-09-05 修订:行尾 badge(快速/存档)删除;临时人行加「修改」——同一
///   `AddPersonSheet` 双模式(添加/修改),修改 = VM `beginEditTempEntry` 回填 +
///   `updateTempEntry` 原位替换(勾选随迁;输入未变保留 resolvedHash)。
/// - 2026-09-07 修订:命主行「更换」menu 拔除——新建命盘入口已移除,存档池恒为
///   命主一盘,命主语义全局唯一(修订 09-02 定稿⑧的 A 盘单选列表收缩一条)。
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

    /// 添加/修改对方半屏 sheet 的呈现模式(nil = 关;定稿③④⑤ + 2026-09-05 修改模式)。
    @State private var personSheetMode: PersonSheetMode?
    /// 修改态标记:onDismiss 时还原添加草稿(beginEditTempEntry 覆盖了 vm.temp* 字段)。
    @State private var sheetWasEdit = false
    /// 临时人行取消勾选确认(定稿:防误删——移出后重加需再填表单)。
    @State private var tempRemovalCandidate: RosterEntry?
    /// 定稿⑤:最近经 sheet 加入的临时人 id(该行标「新」朱印;视图重建自然清除)。
    /// 2026-09-05:由 sheet 添加成功回调显式设置(原 roster diff 推断会把「修改后
    /// id 变化」误判为新加入,已弃用)。
    @State private var newlyAddedTempId: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                // 命主行(A 盘纯展示;无时辰 → 补时辰,2026-09-07 拔「更换」)
                PersonARowView(
                    chart: vm.archivedCharts[safe: vm.selectedChartAIndex],
                    isHourUnknown: vm.isSelfHourUnknown,
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
                    tempRows: vm.roster.compactMap(tempRowModel(for:)),
                    orphanRows: vm.roster.compactMap(orphanRowModel(for:)),
                    isHourUnknown: { vm.isArchivedHourUnknown(hash: $0) },
                    isSelfHourUnknown: vm.isSelfHourUnknown,
                    onToggleArchived: { vm.toggleArchived(hash: $0) },
                    onToggleTemp: { vm.toggleEntrySelection($0) },
                    onEditTemp: { entry in
                        // 回填失败(非 temp / 钟面串解析失败,VM 已记日志)不开 sheet——
                        // 开着会把无关表单现值保存进该 entry(错误显式传播,失败不进成功路径)
                        guard vm.beginEditTempEntry(entry) else { return }
                        sheetWasEdit = true
                        personSheetMode = .edit(entry)
                    },
                    onRemoveTemp: { tempRemovalCandidate = $0 },
                    onAddHour: onAddHour,
                    onAdd: { personSheetMode = .add },
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
        .safeAreaInset(edge: .bottom) {
            // CTA 摘要按点选子集(2026-09-03 勾选子集;2026-09-07 单选恒 ≤1 位)
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
        // 添加/修改对方:同一半屏 sheet 双模式(2026-09-05);修改态关闭时还原添加草稿
        // (beginEditTempEntry 覆盖了 vm.temp*,覆盖保存/取消/下滑三条关闭路径)
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
            Text("点选一位对方 · 解读单独解锁")
                .font(BaziFont.caption(size: 11.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    // MARK: - 名单行展示派生

    /// 临时人行展示模型(名称 / 副行 / 勾选态;从 RosterEntry 派生)。
    private func tempRowModel(for entry: RosterEntry) -> TempRowModel? {
        guard case .temp = entry else { return nil }
        return TempRowModel(
            entry: entry,
            name: displayLabel(for: entry),
            subtitle: subtitleLabel(for: entry),
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
            isSelected: vm.selectedEntryIds.contains(entry.id)
        )
    }

    /// 名单行主名(与 VM 兜底名策略一致:alias 或「对方 · 钟面 · 地点」)。
    private func displayLabel(for entry: RosterEntry) -> String {
        switch entry {
        case .archived(let hash):
            return vm.archivedCharts.first { $0.snapshotHash == hash }?.alias ?? "未知存档"
        case .temp(let input, let alias, _, _):
            if let alias, !alias.isEmpty { return alias }
            // birthDatetime 已是裸钟面字符串,直接读(= 出生地钟面,无时区换算问题)
            let loc = input.placeName ?? "经度 \(String(format: "%.1f", input.longitude))"
            return "对方 · \(input.wallClockDisplay) · \(loc)"
        }
    }

    /// 临时人行副行(出生钟面 + 地点;主名有 alias 时副行补全信息,无 alias 时降级为地点)。
    /// 仅 .temp entry 会走到此处(tempRowModel 已 guard)。
    private func subtitleLabel(for entry: RosterEntry) -> String {
        guard case .temp(let input, let alias, _, _) = entry else { return "" }
        let loc = input.placeName ?? "经度 \(String(format: "%.1f", input.longitude))"
        return (alias?.isEmpty == false) ? "\(input.wallClockDisplay) · \(loc)" : loc
    }
}

// MARK: - CTA 派生模型(单选改造:两态 + 全锁)

/// 配置页底部 CTA(纯值,单测覆盖;2026-09-07 单选改造):
/// - `.ready`:「开始合盘」+ 对方名注(· 解读单独解锁)
/// - `.emptySelection`:置灰「先点选一位对方」(决策 D13 零勾选拦截的前移表达;
///   2026-09-03 起名单非空但零勾选同态;case 名随单选改准确)
/// - `.selfHourUnknown`:置灰「补全时辰后可合盘」(S07 全锁的文案化)
struct CompatibilityConfigCTAModel: Equatable {
    enum Kind: Equatable {
        case ready(namesSummary: String)
        case emptySelection
        case selfHourUnknown
    }

    let kind: Kind

    var title: String {
        switch kind {
        case .ready: return "开始合盘"
        case .emptySelection: return "先点选一位对方"
        case .selfHourUnknown: return "补全时辰后可合盘"
        }
    }

    var note: String {
        switch kind {
        case .ready(let namesSummary): return "\(namesSummary) · 解读单独解锁"
        case .emptySelection: return "点选后即可排盘 · 名单上限 \(CompatibilityViewModel.rosterMax) 位"
        case .selfHourUnknown: return "时辰影响日柱,补全即恢复全部配对"
        }
    }

    var isEnabled: Bool {
        if case .ready = kind { return true }
        return false
    }

    /// - Parameters:
    ///   - selectedCount: 已点选人数(单选下 0 或 1;>1 仅测试直塞防御路径)
    ///   - selectedNames: 已点选人名(取首个非空;与 count 不一致或全空时兜底「1 对」)
    ///   - isSelfHourUnknown: 命主无时辰(S07 全锁优先于零点选展示)
    static func derive(selectedCount: Int, selectedNames: [String], isSelfHourUnknown: Bool) -> Self {
        if isSelfHourUnknown {
            return Self(kind: .selfHourUnknown)
        }
        guard selectedCount > 0 else {
            return Self(kind: .emptySelection)
        }
        let namesSummary = selectedNames.first { !$0.isEmpty } ?? "1 对"
        return Self(kind: .ready(namesSummary: namesSummary))
    }
}

// MARK: - 添加/修改对方半屏 sheet 呈现模式(2026-09-05)

/// `.add` = 添加(空表单起步,加入名单)/ `.edit(RosterEntry)` = 修改(回填该 entry)。
/// Identifiable 供 `.sheet(item:)`;edit 的 id 含 entry id,同一人重复进入不闪断。
private enum PersonSheetMode: Identifiable {
    case add
    case edit(RosterEntry)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let entry): return "edit:\(entry.id)"
        }
    }
}

// MARK: - 添加对方半屏 sheet(定稿③④)

/// 快速添加/修改表单(称呼/出生时间/性别/出生城市,复用 VM `temp*` 草稿字段)。
/// - 添加(`editing == nil`):加入成功 → sheet 自动关闭(新行入名单、**未勾选**,
///   2026-09-03 修订:添加=入册,勾选=入本次合盘,两逻辑解耦)
/// - 修改(`editing` 非 nil,2026-09-05):表单由父层 `beginEditTempEntry` 回填;
///   保存 → `updateTempEntry` 原位替换(勾选随迁),关闭(草稿还原由父层 onDismiss)
/// - 失败 → 留在 sheet 显人话错误;下滑手势即收(系统 sheet 能力)
private struct AddPersonSheet: View {
    @Bindable var vm: CompatibilityViewModel
    /// 修改目标(nil = 添加模式;var + 默认值供 memberwise init 注入)。
    var editing: RosterEntry? = nil
    /// 添加成功回调(参数 = 新入册 entry;父层标「新」朱印。仅添加路径触发)。
    var onAdded: ((RosterEntry) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    private var isEditing: Bool { editing != nil }

    /// sheet 内表单错误(定稿④:重复添加等校验错误留在 sheet 内,不关不吞)。
    @State private var formError: String?

    /// 日期/时刻 wheel sheet 开关(2026-09-07 双行改造)。
    @State private var showDatePicker = false
    @State private var showTimePicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(isEditing ? "修改对方" : "添加对方")
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

                // 日期/时刻双行(2026-09-07:原 .compact DatePicker 系统弹层无「确定」,
                // 换 BirthFormView 同款 row + wheel sheet + 确定;tempBirthDate 是合成
                // Date,双 Binding 按对方出生地钟面拆/合)
                birthDateRow
                birthTimeRow

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
                    if isEditing {
                        saveEdit()
                    } else {
                        addTemp()
                    }
                } label: {
                    HStack {
                        if !isEditing {
                            Image(systemName: "plus.circle.fill")
                        }
                        Text(isEditing ? "保存修改" : "加入名单")
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
                // 满员只拦「加」不拦「改」(修改原位替换,不占新名额;与满员提示口径一致)
                .disabled((!isEditing && vm.roster.count >= CompatibilityViewModel.rosterMax)
                          || formError != nil)

                Text(isEditing
                     ? "保存后名单与勾选状态保持不变 · 下滑收起不保存"
                     : "加入名单后自行勾选 · 下滑可随时收起")
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

    // MARK: - 出生日期/时刻双行(2026-09-07:compact 弹层无确定 → row + wheel sheet)

    /// 出生日期行(点开 date-only wheel sheet;值按对方出生地钟面取)。
    private var birthDateRow: some View {
        Button {
            HapticEngine.light()
            showDatePicker = true
        } label: {
            pickerRowLabel(title: "出生日期", value: tempBirthDateString)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("出生日期")
        .accessibilityValue(tempBirthDateString)
        .sheet(isPresented: $showDatePicker) { tempDatePickerSheet }
    }

    /// 出生时刻行(点开 hourAndMinute wheel sheet)。
    private var birthTimeRow: some View {
        Button {
            HapticEngine.light()
            showTimePicker = true
        } label: {
            pickerRowLabel(title: "出生时刻", value: tempBirthTimeString)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("出生时刻")
        .accessibilityValue(tempBirthTimeString)
        .sheet(isPresented: $showTimePicker) { tempTimePickerSheet }
    }

    /// 双行共用行体(与「称呼」字段同款纸底 hairline 盒:标签居左弱墨,值居右浓墨 + ›)。
    private func pickerRowLabel(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(BaziFont.caption(size: 12))
                .foregroundStyle(BaziTheme.inkMuted)
            Spacer()
            Text(value)
                .font(BaziFont.body(size: 14))
                .foregroundStyle(BaziTheme.ink)
            Text("›")
                .font(BaziFont.caption(size: 12))
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .padding(BaziTheme.Spacing.sm)
        .background(BaziTheme.paper, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.sm).stroke(BaziTheme.hairline, lineWidth: 0.5))
    }

    /// 出生日期 wheel sheet(date-only,不晚于当下;确定=收起,live 拨动即写回)。
    private var tempDatePickerSheet: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
            WheelSheetHeader(title: "选择出生日期") { showDatePicker = false }
            DatePicker(
                "",
                selection: tempDateOnlyBinding,
                in: ...Date(),
                displayedComponents: [.date]
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            // WYSIWYG:表盘按对方出生地时区(S05;解释责任在后端 zoneinfo)
            .environment(\.calendar, vm.tempPlaceCalendar)
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
        .padding(.vertical, BaziTheme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(BaziTheme.paper)
    }

    /// 出生时刻 wheel sheet(hourAndMinute;无「不晚于当下」范围——单时刻无从比较,
    /// 未来校验落在日期+时刻合成值上,validateTempForm 提交时拦)。
    private var tempTimePickerSheet: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
            WheelSheetHeader(title: "选择出生时刻") { showTimePicker = false }
            DatePicker(
                "",
                selection: tempTimeOnlyBinding,
                displayedComponents: [.hourAndMinute]
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            // WYSIWYG:表盘按对方出生地时区(S05;解释责任在后端 zoneinfo)
            .environment(\.calendar, vm.tempPlaceCalendar)
        }
        .padding(.horizontal, BaziTheme.Spacing.xl)
        .padding(.vertical, BaziTheme.Spacing.lg)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(BaziTheme.paper)
    }

    // MARK: - tempBirthDate 拆/合 Binding(按对方出生地钟面)

    /// 日期分量:换年月日,保留原时分秒。
    /// 合成失败(日历边界,理论不可达)不静默丢时分——留在表单显人话错误。
    private var tempDateOnlyBinding: Binding<Date> {
        let cal = vm.tempPlaceCalendar
        return Binding(
            get: { cal.startOfDay(for: vm.tempBirthDate) },
            set: { newDay in
                var comps = cal.dateComponents([.year, .month, .day], from: newDay)
                let old = cal.dateComponents([.hour, .minute, .second], from: vm.tempBirthDate)
                comps.hour = old.hour
                comps.minute = old.minute
                comps.second = old.second
                if let combined = cal.date(from: comps) {
                    vm.tempBirthDate = combined
                } else {
                    AppLogger.app.error(
                        "compat.tempDate.combine.failed raw=\(String(describing: comps), privacy: .public)"
                    )
                    // 复用生辰表单合成失败文案(单一事实源;zh 逐字同款)
                    formError = L10n.BirthForm.errorCombineFailed
                }
            }
        )
    }

    /// 时刻分量:换时分,保留原年月日;秒显式归零(与 BirthFormView.combinedBirthDate
    /// 「秒归 0」同口径——表盘无秒位,旧值泄漏会让同一交互在两表单产出不同契约串)。
    private var tempTimeOnlyBinding: Binding<Date> {
        let cal = vm.tempPlaceCalendar
        return Binding(
            get: { vm.tempBirthDate },
            set: { newTime in
                let newHM = cal.dateComponents([.hour, .minute], from: newTime)
                var comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: vm.tempBirthDate)
                comps.hour = newHM.hour
                comps.minute = newHM.minute
                comps.second = 0
                if let combined = cal.date(from: comps) {
                    vm.tempBirthDate = combined
                } else {
                    AppLogger.app.error(
                        "compat.tempTime.combine.failed raw=\(String(describing: comps), privacy: .public)"
                    )
                    formError = L10n.BirthForm.errorCombineFailed
                }
            }
        )
    }

    /// 出生日期行文案(公历长日期,对方出生地钟面;与 BirthFormView.birthDateText 同式)。
    private var tempBirthDateString: String {
        let formatter = DateFormatter()
        formatter.calendar = vm.tempPlaceCalendar
        formatter.timeZone = vm.tempPlaceCalendar.timeZone
        formatter.locale = .current
        formatter.dateStyle = .long
        return formatter.string(from: vm.tempBirthDate)
    }

    /// 出生时刻行文案(HH:mm,对方出生地钟面;POSIX 模板防系统格式注入)。
    private var tempBirthTimeString: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = vm.tempPlaceCalendar.timeZone
        return formatter.string(from: vm.tempBirthDate)
    }

    private func addTemp() {
        do {
            let added = try vm.addTempToRoster()
            // 成功:关 sheet(新行已入名单、未勾选)+ 清草稿,可重开连加;
            // 「新」朱印显式回调(2026-09-05:不再靠父层 roster diff / append 位置推断)
            onAdded?(added)
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

    /// 修改保存:原位替换 + 关 sheet(表单草稿还原由父层 onDismiss 统一处理,
    /// 覆盖保存/取消/下滑三条关闭路径)。
    private func saveEdit() {
        guard let entry = editing else { return }
        do {
            try vm.updateTempEntry(entry)
            dismiss()
        } catch {
            // 错误面与添加一致:校验/重复文案留在 sheet 内,不关不吞
            if let userError = error as? UserFacingError {
                formError = userError.errorDescription
            } else {
                AppLogger.app.error(
                    "compat.saveEdit.unexpected_error error=\(String(describing: error), privacy: .public)"
                )
                formError = "保存失败,请重试"
            }
        }
    }
}
