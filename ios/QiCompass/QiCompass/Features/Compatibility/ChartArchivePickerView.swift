import SwiftUI

/// 已存档命盘选择器(A 盘单选 / B 盘多选两用,DESIGN.md §Color)。
///
/// 决策 D3:iPhone 屏宽适配,内联 List 行而非大卡片。
/// 多选改造(S01)新增多选变体 `ChartArchiveMultiPickerView`。

// MARK: - 单选(A 盘)

/// A 盘单选组件(原状)。
struct ChartArchivePickerView: View {
    let title: String
    let charts: [ArchivedChart]
    @Binding var selectedIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)

            VStack(spacing: 0) {
                ForEach(Array(charts.enumerated()), id: \.element.id) { idx, chart in
                    Button {
                        selectedIndex = idx
                    } label: {
                        ArchiveRowContent(
                            alias: chart.alias,
                            birthDate: chart.birthDate,
                            dayMaster: chart.dayMaster,
                            isSelected: idx == selectedIndex
                        )
                    }
                    if idx < charts.count - 1 {
                        Divider().background(BaziTheme.hairline)
                    }
                }
            }
            .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.hairline, lineWidth: 0.5))
        }
    }
}

// MARK: - 多选(B 盘名单,决策 D2)

/// B 盘多选组件(S01 新增)。
///
/// 与单选共享 row 视觉语言(`ArchiveRowContent`),区别:
/// - checkmark 用 `circle` / `checkmark.circle.fill`(单选)→ `circle` / `checkmark.circle.fill`(多选语义一致)
/// - 点击 toggle 而非替换
/// - 排除 A 盘自己(决策 D1:A 保持单选,自己不可入名单)
/// - 上限 8(决策 D2):UI 在外层 disable 超量勾选;此处仅视觉显示
struct ChartArchiveMultiPickerView: View {
    let title: String
    let charts: [ArchivedChart]
    /// 排除的 hash(A 盘自己;nil 表示无排除)。
    let excludedHash: String?
    /// 当前已选 hash 集合。
    let selectedHashes: Set<String>
    /// 点击行触发 toggle。
    let onToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)

            // 决策 D13:对方池空(只有自己 / 全部被排除)→ 引导
            if charts.isEmpty || charts.allSatisfy({ $0.snapshotHash == excludedHash }) {
                Text("暂无对方命盘。可在下方添加临时对方,或去「我的」新建命盘。")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(BaziTheme.Spacing.md)
                    .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
                    .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.hairline, lineWidth: 0.5))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(charts.enumerated()), id: \.element.id) { idx, chart in
                        let isExcluded = chart.snapshotHash == excludedHash
                        let isSelected = selectedHashes.contains(chart.snapshotHash)
                        Button {
                            guard !isExcluded else { return }
                            onToggle(chart.snapshotHash)
                        } label: {
                            ArchiveRowContent(
                                alias: chart.alias + (isExcluded ? "(A 盘)" : ""),
                                birthDate: chart.birthDate,
                                dayMaster: chart.dayMaster,
                                isSelected: isSelected,
                                isDisabled: isExcluded
                            )
                        }
                        .disabled(isExcluded)
                        if idx < charts.count - 1 {
                            Divider().background(BaziTheme.hairline)
                        }
                    }
                }
                .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
                .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.hairline, lineWidth: 0.5))
            }
        }
    }
}

// MARK: - 共享 row

/// 单行展示:alias + 出生日期 + 日主 + 选中态 checkmark。
/// 多选/单选共用,通过 `isSelected` / `isDisabled` 控制视觉态。
struct ArchiveRowContent: View {
    let alias: String
    let birthDate: Date
    let dayMaster: String
    let isSelected: Bool
    var isDisabled: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(alias)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isDisabled ? BaziTheme.inkMuted : BaziTheme.ink)
                HStack(spacing: 8) {
                    Text(Self.dateFormatter.string(from: birthDate))
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                    Text("日主 \(dayMaster)")
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(BaziTheme.cinnabar)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(BaziTheme.inkMuted.opacity(0.5))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? BaziTheme.cinnabarSoft
                : Color.clear
        )
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}
