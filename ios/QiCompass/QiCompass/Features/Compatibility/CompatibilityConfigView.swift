import SwiftUI

/// 合盘配置态(多选改造):A 盘单选 + B 名单(存档勾选 + 临时输入)+ context picker + 底部「开始合盘」CTA。
///
/// 决策 D1:A 单选不变 / B 改多选名单。
/// 决策 D2:名单 = 存档勾选 + 临时输入(可多个);上限 8 人。
/// 决策 D11:增删入口统一在配置页(结果列表纯展示)。
/// 决策 D4:`zi_hour_rule` 不暴露给用户,MVP 固定 `zi_next_day`,显示只读提示。
struct CompatibilityConfigView: View {
    @Bindable var vm: CompatibilityViewModel
    let onStart: () -> Void

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

                // context picker(决策 D8 配置页全局)
                section(title: "合盘维度") {
                    Picker("合盘维度", selection: $vm.context) {
                        Text("通用").tag("general")
                        Text("婚姻").tag("marriage")
                        Text("事业").tag("business")
                    }
                    .pickerStyle(.segmented)

                    Text(contextDescription)
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                }

                // 子时规则只读提示
                section(title: "子时规则") {
                    HStack {
                        Text("23:00 换日(早子时归当日)")
                            .foregroundStyle(BaziTheme.inkMuted)
                        Spacer()
                    }
                    Text("MVP 固定规则,后端 setSect(1)。")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
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
                .foregroundStyle(BaziTheme.paper)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(BaziTheme.paper.opacity(0.95))
            }
        }
    }

    // MARK: - 名单区(存档多选 + 临时表单 + 已加入名单展示)

    @ViewBuilder
    private var rosterSection: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.md) {
            // 存档多选(A 盘自己排除;D13 对方池空时 picker 内置引导文案)
            ChartArchiveMultiPickerView(
                title: "从存档选择",
                charts: vm.archivedCharts,
                excludedHash: vm.currentPersonAHash,
                selectedHashes: vm.selectedArchivedHashes,
                onToggle: { vm.toggleArchived(hash: $0) }
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
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayLabel(for: entry))
                    .font(.subheadline)
                    .foregroundStyle(BaziTheme.ink)
                Text(kindLabel(for: entry))
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
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
                    .foregroundStyle(BaziTheme.cinnabar)
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
                    .foregroundStyle(BaziTheme.cinnabar)
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
            // WYSIWYG:表盘按对方出生城市时区(S04;解释责任在后端 zoneinfo)
            .environment(\.calendar, vm.tempPlaceCalendar)

            Picker("性别", selection: $vm.tempGender) {
                Text("男").tag("male")
                Text("女").tag("female")
            }
            .pickerStyle(.segmented)

            Toggle("手动输入经度", isOn: $vm.tempUseManualLongitude)
                .foregroundStyle(BaziTheme.ink)

            if vm.tempUseManualLongitude {
                HStack {
                    Text("经度").foregroundStyle(BaziTheme.inkMuted)
                    TextField("东正西负", value: $vm.tempManualLongitude, format: .number)
                        .keyboardType(.numbersAndPunctuation)
                        .foregroundStyle(BaziTheme.ink)
                        .padding(BaziTheme.Spacing.sm)
                        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm))
                }
            } else {
                // S04:全球城市搜索(与深度解析同一组件)
                CityPickerField(selection: $vm.tempPlace)
            }
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
            // 不静默吞(CLAUDE.md):展示真实错误
            tempFormError = error.localizedDescription
        }
    }

    // MARK: - context 说明

    private var contextDescription: String {
        switch vm.context {
        case "general":  return "整体缘分概览"
        case "marriage": return "侧重感情质量与家庭节奏"
        case "business": return "侧重合作契合与利益节奏"
        default:         return ""
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
