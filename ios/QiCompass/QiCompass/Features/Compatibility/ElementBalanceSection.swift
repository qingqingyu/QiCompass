import SwiftUI

/// 合盘五行分布区(BP Match 设计板 #4,2026-10-01)。
///
/// 两人各按 8 字(干支各 1 字)计五行,每字一枚五行色圆点 + 计数——让评估卡
/// 的「互补」有盘面事实可查。**每字一点,不做归一化缩放**(设计稿 mock 画了
/// 4 点上限,五行偏旺盘会溢出;如实按 1-8 点呈现,8 点 × 7pt 在半列宽内可容)。
///
/// 语言族同 SyncedFortuneTable:kicker + 列头 + hairline 行分 + 底部收边,
/// 无容器底色(卡片让位 hairline);计数 tabular-nums。时辰未知一侧按实际
/// 字数(6 字)计,脚注说明,不猜。
struct ElementBalanceSection: View {
    let pillars: [DualPillarSource]
    /// B 列头(对方称呼;A 列头恒「你/you」固定文案,同 SyncedFortuneTable 口径)。
    let nameB: String

    /// 纯值模型(供 Tests 直测计数)。
    struct Model: Equatable {
        struct Row: Equatable {
            let element: ElementColors
            let countA: Int
            let countB: Int
        }
        let rows: [Row]
        /// 任一侧时柱缺失(按 6 字计)→ 脚注。
        let hourUnknown: Bool

        static func make(pillars: [DualPillarSource]) -> Model {
            let countsA = CompatibilityRelationDetailBuilder.elementCounts(pillars, isA: true)
            let countsB = CompatibilityRelationDetailBuilder.elementCounts(pillars, isA: false)
            let hourUnknown = pillars.contains { $0.ganA == nil || $0.zhiA == nil || $0.ganB == nil || $0.zhiB == nil }
            return Model(
                rows: ElementColors.allCases.map { elem in
                    Row(element: elem, countA: countsA[elem] ?? 0, countB: countsB[elem] ?? 0)
                },
                hourUnknown: hourUnknown
            )
        }
    }

    private let labelColumnWidth: CGFloat = 44

    var body: some View {
        let model = Model.make(pillars: pillars)
        return VStack(alignment: .leading, spacing: 12) {
            Text(L10n.Compatibility.balanceTitle)
                .font(BaziFont.caption(size: 10))
                .tracking(1.5)
                .foregroundStyle(BaziTheme.inkMutedSecondary)

            VStack(spacing: 0) {
                header
                ForEach(model.rows, id: \.element) { row in
                    Rectangle()
                        .fill(BaziTheme.hairline)
                        .frame(height: 0.5)
                    rowView(row)
                }
            }
            .padding(.bottom, 16)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(BaziTheme.hairline)
                    .frame(height: 0.5)
            }

            if model.hourUnknown {
                Text(L10n.Compatibility.balanceHourUnknownNote)
                    .font(BaziFont.caption(size: 10))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        }
        .fadeIn()
    }

    // MARK: 列头(你 / {对方};caption2 弱墨,同 SyncedFortuneTable)

    private var header: some View {
        HStack(spacing: 8) {
            Text(L10n.Compatibility.balanceElement)
                .frame(width: labelColumnWidth, alignment: .leading)
            Text(L10n.Compatibility.selfDisplay)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(nameB)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption2)
        .foregroundStyle(BaziTheme.inkMuted)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }

    // MARK: 单行:五行字(着色) + 两人圆点与计数

    private func rowView(_ row: Model.Row) -> some View {
        let isZh = AppLanguage.current.isChinese
        return HStack(spacing: 8) {
            Text(isZh ? row.element.label : row.element.englishLabel)
                .font(BaziFont.ganzhi(size: 15))
                .foregroundStyle(row.element.color)
                .frame(width: labelColumnWidth, alignment: .leading)

            dots(count: row.countA, color: row.element.color)
            Spacer(minLength: 0)
            dots(count: row.countB, color: row.element.color)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel(row))
    }

    /// 圆点串 + 计数(每字一点,不归一化;0 字 → 无点仅计数)。
    private func dots(count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { _ in
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
            }
            Text("\(count)")
                .font(BaziFont.numeric(size: 12, weight: .medium))
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func a11yLabel(_ row: Model.Row) -> String {
        let isZh = AppLanguage.current.isChinese
        let name = isZh ? row.element.label : row.element.englishLabel
        return String(
            format: String(localized: "%1$@:你 %2$lld 字 · 对方 %3$lld 字"),
            name, row.countA, row.countB
        )
    }
}
