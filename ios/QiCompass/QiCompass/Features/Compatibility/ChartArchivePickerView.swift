import SwiftUI

// MARK: - 配置页选人组件集(2026-09-02 定稿「名单合一 · 勾选即选」)
//
// 事实源:~/.gstack/projects/qingqingyu-QiCompass/designs/hepan-picker-20260902/finalized.html
// 原 ChartArchivePickerView(单选列表)+ ChartArchiveMultiPickerView(多选列表)三段堆叠
// 收敛为单一名单:命主行(PersonARowView)+ 勾选名单(RosterUnifiedListView)+ 共享行(ArchiveRowContent)。
// 添加面板迁半屏 sheet(见 CompatibilityConfigView.AddPersonSheet),本文件不含表单。

// MARK: - 命主行(A 盘,定稿⑧)

/// 命主行:单行呈现当前 A 盘,「更换」弹 menu 列全部存档盘。
///
/// - 已勾入名单的盘在 menu 中置灰(标「名单中」)——防「自己合自己」,
///   与 VM `toggleArchived` 的 is_person_a 守卫同向双保险
/// - 自己无时辰(定稿⑦):右侧「更换」变「补时辰」,直达 S10 补时辰 sheet
struct PersonARowView: View {
    /// 全部存档盘(menu 候选;当前 A 从中取)。
    let charts: [ArchivedChart]
    let selectedIndex: Int
    /// 已勾入名单的存档 hash(置灰判据)。
    let rosterHashes: Set<String>
    /// 自己(A 盘)无时辰 → 右侧变「补时辰」。
    let isHourUnknown: Bool
    let onSelect: (Int) -> Void
    /// 补时辰触点(参数 = 当前 A 盘 hash;nil 无宿主时按钮不渲染降级为「更换」)。
    var onAddHour: (() -> Void)? = nil

    private var current: ArchivedChart? { charts[safe: selectedIndex] }

    /// 头像首字:空别名回落「我」(不渲染空字)。
    private var avatarInitial: String {
        guard let alias = current?.alias, !alias.isEmpty else { return "我" }
        return String(alias.prefix(1))
    }

    var body: some View {
        HStack(spacing: 13) {
            Circle()
                .fill(BaziTheme.inkDeep)
                .frame(width: 40, height: 40)
                .overlay(
                    Text(avatarInitial)
                        .font(BaziFont.display(size: 16, weight: .medium))
                        .foregroundStyle(BaziTheme.onInkDeep)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(current?.alias ?? "未知存档")
                    .font(BaziFont.body())
                    .fontWeight(.medium)
                    .foregroundStyle(BaziTheme.ink)
                Text("\(Self.dateString(current?.birthDate)) · 日主 \(current?.dayMaster ?? "—")")
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            Spacer(minLength: 8)
            if isHourUnknown, let onAddHour {
                Button {
                    onAddHour()
                } label: {
                    Text("补时辰 ›")
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(1.5)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            } else {
                Menu {
                    ForEach(Array(charts.enumerated()), id: \.element.id) { idx, chart in
                        let isCurrent = idx == selectedIndex
                        let inRoster = rosterHashes.contains(chart.snapshotHash)
                        Button {
                            onSelect(idx)
                        } label: {
                            // 系统 menu 忽略自定义前景色/Spacer,状态以文本后缀传达
                            // (定稿⑧语义:当前朱标 / 名单中置灰 → menu 内均退化为纯文本)
                            if isCurrent {
                                Text(chart.alias + "  ✓ 当前")
                            } else if inRoster {
                                Text(chart.alias + "  名单中 · 需先取消勾选")
                            } else {
                                Text(chart.alias)
                            }
                        }
                        .disabled(isCurrent || inRoster)
                    }
                } label: {
                    Text("更换 ⌄")
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(1.5)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
            }
        }
        .padding(.vertical, 12)
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "—" }
        return ArchiveRowContent.dateFormatter.string(from: date)
    }
}

// MARK: - 单一勾选名单(定稿②⑤⑥)

/// 「选择对方」名单:临时人行(恒勾选,置顶)+ 跨启动恢复行 + 存档行(勾选圈)
/// + 尾部「＋添加对方」行。开放布局(DESIGN.md:卡片让位 hairline)——行间 hairline 分隔,无卡片容器。
///
/// - 存档行勾选/取消 = `toggleArchived`(VM roster 进出)
/// - 临时人/恢复行点击 = 移出名单确认(父层 confirmationDialog 后 `removeRosterEntry`)
/// - 时辰未知行保留 S11(置灰无圈短注)/ S10(点击直达补时辰)行为
/// - 名单满 8(决策 D2):添加行置灰 + dashed 提示——上限拦「加」不拦「排」
/// - 池空(决策 D13):无候选且名单空 → 引导文案 + 添加行(定稿①两者并存)
struct RosterUnifiedListView: View {
    let charts: [ArchivedChart]
    /// 排除的 hash(A 盘自己)。
    let excludedHash: String?
    /// 名单(临时人行数据 + 满员判据)。
    let roster: [RosterEntry]
    let rosterMax: Int
    let selectedHashes: Set<String>
    /// 临时人行展示参数(顺序与 roster 中 .temp 一致):名称 / 副行 / badge。
    let tempRows: [TempRowModel]
    /// 跨启动恢复的存档行(S06:临时人持久化为 `.archived` hash,无 UserSnapshotLink
    /// → 不在 `charts` 内,候选区无对应行)。名单含该 entry 就必须有行——可见、可移出,
    /// 否则 CTA「排 N 对」出现隐形成员(承接旧「已加入名单」区的全覆盖语义)。
    let orphanRows: [TempRowModel]
    let isHourUnknown: (String) -> Bool
    /// 命主无时辰(S07 全锁,定稿⑦):整列置灰无圈、不可交互。
    let isSelfHourUnknown: Bool
    let onToggleArchived: (String) -> Void
    /// 临时人/恢复行点击(取消勾选确认;参数 = 该 entry)。
    let onRemoveTemp: (RosterEntry) -> Void
    /// S10:点击被标记行 → 补时辰 sheet。
    var onAddHour: ((String) -> Void)? = nil
    /// 打开添加 sheet(尾部「＋添加对方」行)。
    let onAdd: () -> Void
    /// 定稿⑤:最近加入的临时人行 id(该行渲染「新」朱印;nil = 无标记)。
    var newEntryId: String? = nil

    /// S11:被拦勾选的轻提示(无 S10 宿主时的回退)。
    @State private var showHourUnknownHint = false

    private var candidateCharts: [ArchivedChart] {
        charts.filter { $0.snapshotHash != excludedHash }
    }
    private var isFull: Bool { roster.count >= rosterMax }
    private var isPoolEmpty: Bool { candidateCharts.isEmpty && tempRows.isEmpty && orphanRows.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 段标:已选计数走朱色小注(印章级点缀;全锁时不给计数,定稿⑦)
            HStack(alignment: .firstTextBaseline) {
                Text("选 择 对 方")
                    .font(BaziFont.caption(size: 11))
                    .tracking(4)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Spacer()
                if !isSelfHourUnknown {
                    // 定稿⑥:满员时给容量「N / 8 位」,非常规态只给「N 位」
                    Text(isFull ? "已选 \(roster.count) / \(rosterMax) 位" : "已选 \(roster.count) 位")
                        .font(BaziFont.caption(size: 10))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.cinnabar)
                }
            }

            if isPoolEmpty {
                // 决策 D13:对方池空 → 引导 + 添加行(定稿①:两者并存,
                // 池空时添加行是快速添加的唯一入口,不可随行区一起消失)
                VStack(spacing: 0) {
                    poolEmptyHint
                    addRow
                }
            } else {
                rosterRows
            }

            if isFull {
                // 定稿⑥:满员 dashed 提示(上限拦「加」不拦「排」)
                Text("名单已满 \(rosterMax) 位(含未勾选)。取消某位勾选或将其移出名单,可再添加新的对方。")
                    .font(BaziFont.caption(size: 10))
                    .tracking(0.5)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .padding(BaziTheme.Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(
                        RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                            .stroke(BaziTheme.hairlineDashed, lineWidth: 1)
                    )
            }

            if showHourUnknownHint {
                Text(L10n.CompatibilityRosterGate.hint)
                    .font(BaziFont.caption(size: 11.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .transition(.opacity)
            }
        }
    }

    // MARK: 行区

    @ViewBuilder
    private var rosterRows: some View {
        // hairline 节奏与定稿 mock 一致:每个名单行(含最后一个)行后一条,
        // 添加行悬于 hairline 之下(不画线)
        VStack(spacing: 0) {
            // 临时人行(置顶,恒勾选;置顶 = 定稿⑤「新行落位名单顶部」)
            ForEach(tempRows) { row in
                rosterExtraRow(row)
                Divider().background(BaziTheme.hairline)
            }
            // 跨启动恢复行(名单有、候选区无;恒勾选,点击 = 移出确认)
            ForEach(orphanRows) { row in
                rosterExtraRow(row)
                Divider().background(BaziTheme.hairline)
            }
            // 存档候选行(排除 A 盘)
            ForEach(candidateCharts) { chart in
                let isHourUnknownRow = isHourUnknown(chart.snapshotHash)
                // 全锁(定稿⑦):行置灰无圈不可点;S10 补时辰直达只保留在无时辰行上
                Button {
                    guard !isSelfHourUnknown else { return }
                    guard !isHourUnknownRow else {
                        // S10 优先直达补时辰;无宿主退回 S11 轻提示
                        HapticEngine.light()
                        if let onAddHour {
                            onAddHour(chart.snapshotHash)
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) { showHourUnknownHint = true }
                        }
                        return
                    }
                    onToggleArchived(chart.snapshotHash)
                } label: {
                    ArchiveRowContent(
                        alias: chart.alias,
                        birthDate: chart.birthDate,
                        dayMaster: chart.dayMaster,
                        isSelected: selectedHashes.contains(chart.snapshotHash),
                        isLocked: isSelfHourUnknown,
                        hourUnknownMark: isHourUnknownRow ? L10n.CompatibilityRosterGate.mark : nil,
                        kindNote: "存档"
                    )
                }
                .disabled(isSelfHourUnknown)
                Divider().background(BaziTheme.hairline)
            }
            // 尾部添加行(满员置灰,定稿⑥)
            addRow
        }
    }

    /// 名单补行(临时人 / 跨启动恢复):朱色实圈(勾选态)+ 信息 + badge 小注;
    /// 点击 = 移出名单(父层确认)。全锁(定稿⑦):灰圈灰字不可点。
    /// 定稿⑤:最新加入的临时人行叠「新」朱印(印章级小元素,DESIGN.md 许可)。
    private func rosterExtraRow(_ row: TempRowModel) -> some View {
        Button {
            guard !isSelfHourUnknown else { return }
            onRemoveTemp(row.entry)
        } label: {
            HStack(spacing: 13) {
                Image(systemName: isSelfHourUnknown ? "circle" : "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(isSelfHourUnknown ? BaziTheme.inkMuted.opacity(0.5) : BaziTheme.cinnabar)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.name)
                        .font(BaziFont.body())
                        .fontWeight(.medium)
                        .foregroundStyle(isSelfHourUnknown ? BaziTheme.inkMuted : BaziTheme.ink)
                    Text(row.subtitle)
                        .font(BaziFont.caption(size: 10))
                        .tracking(0.5)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                Spacer()
                Text(row.badge)
                    .font(BaziFont.caption(size: 10))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelfHourUnknown ? Color.clear : BaziTheme.cinnabarSoft,
                in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
            )
            .overlay(alignment: .topLeading) {
                if row.entry.isTemp, row.entry.id == newEntryId, !isSelfHourUnknown {
                    Text("新")
                        .font(BaziFont.caption(size: 9))
                        .foregroundStyle(BaziTheme.onInkDeep)
                        .frame(width: 17, height: 17)
                        .background(BaziTheme.cinnabar, in: RoundedRectangle(cornerRadius: 2.5))
                        .rotationEffect(.degrees(-6))
                        .offset(x: 2, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isSelfHourUnknown)
        .accessibilityHint("移出名单")
    }

    private var addRow: some View {
        Button {
            guard !isFull else { return }
            onAdd()
        } label: {
            HStack(spacing: 13) {
                Circle()
                    .stroke(BaziTheme.hairlineDashed, lineWidth: 1.4)
                    .frame(width: 22, height: 22)
                    .overlay(Text("＋").font(.caption).foregroundStyle(BaziTheme.inkMuted))
                VStack(alignment: .leading, spacing: 3) {
                    Text("添加对方")
                        .font(BaziFont.body())
                        .foregroundStyle(isFull ? BaziTheme.inkMutedSecondary : BaziTheme.inkMuted)
                    Text(isFull ? "名单已满 · 上限 \(rosterMax) 位" : "不建档案 · 填出生信息即可")
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

    private var poolEmptyHint: some View {
        VStack(spacing: 7) {
            Text("还没有对方的盘")
                .font(BaziFont.body())
                .tracking(1.5)
                .foregroundStyle(BaziTheme.inkMuted)
            Text("在下方直接填对方出生信息,\n或先去「我的」为 TA 建一个存档命盘。")
                .font(BaziFont.caption(size: 10.5))
                .tracking(0.5)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
                .stroke(BaziTheme.hairlineDashed, lineWidth: 1)
        )
    }
}

// MARK: - 名单补行展示模型

/// 名单补行(临时人行 / 跨启动恢复行)展示参数(ConfigView 从 RosterEntry 派生;纯值)。
/// `badge` = 行右侧小注:「快速」(本会话临时人)/「存档」(S06 恢复的名单成员)。
struct TempRowModel: Identifiable {
    let entry: RosterEntry
    let name: String
    let subtitle: String
    let badge: String
    var id: String { entry.id }
}

// MARK: - 共享行(视觉沿用,自原 ArchiveRowContent 平移)

/// 单行展示:alias + 出生日期 + 日主 + 选中态 checkmark。
/// S11:`hourUnknownMark` 非空 → 置灰 + 留白记号(不画圈,以一行短注代替;无红色警示)。
struct ArchiveRowContent: View {
    let alias: String
    let birthDate: Date
    let dayMaster: String
    let isSelected: Bool
    /// S07 全锁(命主无时辰,定稿⑦):置灰 + 不画圈,不可交互。
    var isLocked: Bool = false
    /// S11:不可合盘短标(时辰未知);nil = 正常可选行。
    var hourUnknownMark: String? = nil
    /// 行尾来源小注(定稿②「存档」;正常行显示,标记/全锁行不显示——与「快速」badge 对称)。
    var kindNote: String? = nil

    private var isGreyed: Bool { isLocked || hourUnknownMark != nil }
    /// 正常行(可勾选、无短标)才给行尾小注(定稿②:标记行以短注代替,⑦全锁行无注)。
    private var showsKindNote: Bool { kindNote != nil && !isLocked && hourUnknownMark == nil }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(alias)
                    .font(BaziFont.body())
                    .fontWeight(.medium)
                    .foregroundStyle(isGreyed ? BaziTheme.inkMuted : BaziTheme.ink)
                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: birthDate))
                        .font(BaziFont.caption(size: 10))
                        .foregroundStyle(BaziTheme.inkMuted)
                    Text("日主 \(dayMaster)")
                        .font(BaziFont.caption(size: 10))
                        .foregroundStyle(BaziTheme.inkMuted)
                    // S11 留白记号:置灰短注随行内联(不上红色,不做警示形态)
                    if let hourUnknownMark {
                        Text(hourUnknownMark)
                            .font(BaziFont.caption(size: 9.5))
                            .tracking(1)
                            .foregroundStyle(BaziTheme.inkMutedSecondary)
                    }
                }
            }
            Spacer()
            if showsKindNote, let kindNote {
                Text(kindNote)
                    .font(BaziFont.caption(size: 10))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
            if hourUnknownMark == nil && !isLocked {
                if isSelected {
                    // 朱色选中圈(印章级点缀);行底 cinnabarSoft(选中态,极少量)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(BaziTheme.cinnabar)
                } else {
                    Image(systemName: "circle")
                        .font(.body)
                        .foregroundStyle(BaziTheme.inkMuted.opacity(0.5))
                }
            }
            // S11/S07 留白:不可选行不画圈(无勾选位,水墨留白表达)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected && hourUnknownMark == nil && !isLocked
                ? BaziTheme.cinnabarSoft
                : Color.clear
        )
    }

    /// 行内日期格式(文件内共享:命主行 dateString 亦复用,单一事实源)。
    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}

// MARK: - 推演中(定稿⑨)

/// computing 态视觉:竖排「推演合盘」+ 三墨点 breathe + i/N 计数(决策 D3 串行)。
/// reduce-motion:墨点静态呈现(DESIGN.md 动效全降级)。
struct CompatibilityCastingView: View {
    let completed: Int
    let total: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    /// 三墨点呼吸两端 opacity(breathe 动效,定稿⑨)。
    private static let dotsBreathing: [Double] = [0.35, 0.65, 1.0]
    private static let dotsStatic: [Double] = [1.0, 0.5, 0.22]

    var body: some View {
        VStack(spacing: 26) {
            VText(phrase: "推演合盘", size: 21, tracking: 10)
            HStack(spacing: 14) {
                ForEach(0..<3, id: \.self) { idx in
                    Circle()
                        .fill(BaziTheme.inkDeep)
                        .frame(width: 9, height: 9)
                        .opacity(breathing ? Self.dotsBreathing[idx] : Self.dotsStatic[idx])
                }
            }
            Text("\(completed) / \(total)")
                .font(.system(.footnote, design: .default).monospacedDigit())
                .tracking(2)
                .foregroundStyle(BaziTheme.inkMuted)
            Text("确定性排盘 · 未完成的对不进列表")
                .font(BaziFont.caption(size: 10.5))
                .tracking(1.5)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("推演合盘中,已完成 \(completed) 对,共 \(total) 对")
    }
}
