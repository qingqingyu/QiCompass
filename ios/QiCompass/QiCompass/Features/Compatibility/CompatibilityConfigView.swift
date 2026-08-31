import SwiftUI

/// 合盘配置态(多选改造):A 盘单选 + B 名单(存档勾选 + 临时输入)+ 底部「开始合盘」CTA。
/// 2026-08-16:「合盘维度」picker 移除,context 固定 "general"(见 CompatibilityViewModel.context 注释)。
///
/// 决策 D1:A 单选不变 / B 改多选名单。
/// 决策 D2:名单 = 存档勾选 + 临时输入(可多个);上限 8 人。
/// 决策 D11:增删入口统一在配置页(结果列表纯展示)。
/// 决策 D4:`zi_hour_rule` 不暴露给用户,MVP 固定 `zi_next_day`(2026-08-16 起配置页
/// 不再显示只读提示——「我的」tab 已有全局设置,此处冗余;规则仍后端固定 setSect(1))。
struct CompatibilityConfigView: View {
    @Bindable var vm: CompatibilityViewModel
    let onStart: () -> Void
    /// S10:点击「不可合盘」标记行 → 打开该盘补时辰 sheet(D7 触点 1 的他人盘分支)。
    var onAddHour: ((String) -> Void)? = nil

    @State private var tempFormError: String?
    @State private var showTempForm: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // A 盘选择(单选不变)
                ChartArchivePickerView(
                    title: "A 盘(你)",
                    charts: vm.archivedCharts,
                    selectedIndex: $vm.selectedChartAIndex
                )
                .onChange(of: vm.selectedChartAIndex) { _, _ in
                    // A 盘切换后,如果名单里有勾选了同 hash(理论上不会,因为 picker 排除了)做兜底剔除
                    if let aHash = vm.currentPersonAHash,
                       vm.selectedArchivedHashes.contains(aHash) {
                        vm.toggleArchived(hash: aHash)
                    }
                }

                // B 名单(决策 D2 混合名单)
                section(title: "B 盘(对方)名单 · \(vm.roster.count)/\(CompatibilityViewModel.rosterMax)") {
                    rosterSection
                }

                if case .failed(let userError) = vm.state {
                    Text(userError.errorDescription ?? "未知错误")
                        .font(.caption)
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
            Button(action: onStart) {
                HStack {
                    Image(systemName: "person.2.wave.2")
                    Text("开始合盘")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(BaziTheme.onInkDeep)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    // S11:自己无时辰 → 全部对不可发起(置灰;解释行在 B 名单区顶部)
                    vm.isSelfHourUnknown ? BaziTheme.inkDeep.opacity(0.3) : BaziTheme.inkDeep,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(BaziTheme.paper.opacity(0.95))
            }
            .disabled(vm.isSelfHourUnknown)
        }
    }

    // MARK: - 名单区(存档多选 + 临时表单 + 已加入名单展示)

    @ViewBuilder
    private var rosterSection: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
            // S11 名单整体标记:自己无时辰 → 全部对不可用(解释行 + 下方行级置灰
            // + 底部「开始合盘」不可发起)。dashed hairline = 锁框/临时态(DESIGN.md)
            if vm.isSelfHourUnknown {
                Text(L10n.CompatibilityRosterGate.selfBanner)
                    .font(BaziFont.caption(size: 11.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BaziTheme.Spacing.md)
                    .overlay(
                        RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                            .stroke(BaziTheme.hairlineDashed, lineWidth: 1)
                    )
            }

            // 存档多选(A 盘自己排除;D13 对方池空时 picker 内置引导文案;
            // S11 无时辰行标记不勾入;S10 标记行点击直达补时辰 sheet)
            ChartArchiveMultiPickerView(
                title: "从存档选择",
                charts: vm.archivedCharts,
                excludedHash: vm.currentPersonAHash,
                selectedHashes: vm.selectedArchivedHashes,
                isHourUnknown: { vm.isArchivedHourUnknown(hash: $0) },
                onToggle: { vm.toggleArchived(hash: $0) },
                onAddHour: onAddHour
            )

            // 临时输入入口(S01 限 1 条;S04 扩多条 + 称呼字段)
            tempInputArea

            // 已加入名单展示(可移除;D11 配置页单一入口)
            if !vm.roster.isEmpty {
                VStack(alignment: .leading, spacing: BaziTheme.Spacing.xs) {
                    Text("已加入名单")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(BaziTheme.inkMuted)
                    ForEach(vm.roster) { entry in
                        rosterRow(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func rosterRow(_ entry: RosterEntry) -> some View {
        // S11 对级标记:任一方无时辰 → 该行置灰 + 「不可合盘」短注
        // (他人无时辰 = 该对;自己无时辰 = 全部对,解释行见 rosterSection 顶部)
        let hourBlocked = vm.isPairHourUnknownBlocked(entry: entry)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayLabel(for: entry))
                    .font(.subheadline)
                    .foregroundStyle(hourBlocked ? BaziTheme.inkMuted : BaziTheme.ink)
                Text(hourBlocked
                     ? "\(kindLabel(for: entry)) · \(L10n.CompatibilityRosterGate.mark)"
                     : kindLabel(for: entry))
                    .font(.caption)
                    .tracking(hourBlocked ? 1 : 0)
                    .foregroundStyle(hourBlocked ? BaziTheme.inkMutedSecondary : BaziTheme.inkMuted)
            }
            Spacer()
            Button {
                vm.removeRosterEntry(entry)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(BaziTheme.destructive)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(BaziTheme.paper, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.sm).stroke(BaziTheme.hairline, lineWidth: 0.5))
    }

    private func displayLabel(for entry: RosterEntry) -> String {
        switch entry {
        case .archived(let hash):
            return vm.archivedCharts.first { $0.snapshotHash == hash }?.alias ?? "未知存档"
        case .temp(let input, let alias, _):
            if let alias, !alias.isEmpty { return alias }
            // S04:birthDatetime 已是裸钟面字符串,直接读(= 出生地钟面,无时区换算问题)
            let loc = input.placeName ?? "经度 \(String(format: "%.1f", input.longitude))"
            return "对方 · \(input.wallClockDisplay) · \(loc)"
        }
    }

    private func kindLabel(for entry: RosterEntry) -> String {
        switch entry {
        case .archived: return "存档"
        case .temp: return "快速"
        }
    }

    // MARK: - 快速添加区(模式 B,S04 多条独立;2026-08-14 文案改「快速添加」,原「临时输入」)

    @ViewBuilder
    private var tempInputArea: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            HStack {
                Text("快速添加")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaziTheme.ink)
                Spacer()
                if vm.tempCountInRoster > 0 {
                    Text("已加入 \(vm.tempCountInRoster) 位")
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }

            if showTempForm {
                tempInputForm
                Button {
                    addTemp()
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("添加到名单")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaziTheme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(BaziTheme.cinnabarSoft, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }
                .disabled(vm.roster.count >= CompatibilityViewModel.rosterMax)
            } else {
                Button {
                    showTempForm = true
                } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text("填写对方信息")
                    }
                    .font(.subheadline)
                    .foregroundStyle(BaziTheme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                .disabled(vm.roster.count >= CompatibilityViewModel.rosterMax)
            }

            if let tempFormError {
                Text(tempFormError)
                    .font(.caption)
                    .foregroundStyle(BaziTheme.destructive)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var tempInputForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            // S04 新增:可选「称呼」字段(留空走兜底名「对方+出生日期」)
            HStack {
                Text("称呼").foregroundStyle(BaziTheme.inkMuted)
                TextField("可选,如「相亲对象甲」", text: $vm.tempAlias)
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
        }
        .padding(BaziTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
    }

    private func addTemp() {
        do {
            try vm.addTempToRoster()
            tempFormError = nil
            // S04:多条模式 → 添加成功后清空草稿(让用户继续添加下一个)
            vm.resetTempDraftForm()
        } catch {
            // 不静默吞(CLAUDE.md):UserFacingError(表单校验)文案原样展示;
            // 其他意外错误(如存储层)用人话兜底,原始 error 记日志不进 UI
            if let userError = error as? UserFacingError {
                tempFormError = userError.errorDescription
            } else {
                AppLogger.app.error(
                    "compat.addTemp.unexpected_error error=\(String(describing: error), privacy: .public)"
                )
                tempFormError = "添加失败,请重试"
            }
        }
    }

    // MARK: - Section

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
            content()
                .padding(BaziTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.hairline, lineWidth: 0.5))
        }
    }
}
