import SwiftUI

/// 双盘对比柱数据源(D6)。
///
/// 抽出此结构后,DualPillarsTable 不依赖具体数据源:
/// A 盘从本地 ChartSnapshot 解;模式 A 下 B 盘同;模式 B 下 B 从 response.personBChart 取。
struct DualPillarSource: Identifiable, Equatable {
    let position: String       // "年柱" / "月柱" / "日柱" / "时柱"
    let ganA: String
    let zhiA: String
    let nayinA: String
    let ganElementA: String    // 英文 key(给 ElementColors 取色)
    let zhiElementA: String
    let ganB: String
    let zhiB: String
    let nayinB: String
    let ganElementB: String
    let zhiElementB: String

    var id: String { position }
}

/// A 上 B 下紧凑双盘表(D6 + DESIGN.md §Color + §Ganzhi)。
///
/// iPhone 屏宽 ~375pt,8 列(2 人 × 4 柱)挤;改用「每柱一列,每列内 A 行上 B 行下」紧凑表。
/// 不复用 PillarsTable(信息密度过高)。
struct DualPillarsTable: View {
    let pillars: [DualPillarSource]  // 共 4 条(年/月/日/时)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("双盘对比")
                .zcoolCardTitle()

            // 4 列横向均分
            HStack(alignment: .top, spacing: 8) {
                ForEach(pillars) { p in
                    pillarColumn(p)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(BaziTheme.cardBackground, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.cardBorder, lineWidth: 0.5))
        }
    }

    /// 单柱列:位置 → A 盘 → B 盘。
    private func pillarColumn(_ p: DualPillarSource) -> some View {
        VStack(spacing: 6) {
            // 位置标签
            Text(p.position)
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)

            // A 盘
            pillarCell(
                gan: p.ganA, zhi: p.zhiA, nayin: p.nayinA,
                ganElement: p.ganElementA, zhiElement: p.zhiElementA,
                label: "A"
            )

            // 分隔点
            Circle()
                .fill(BaziTheme.separator)
                .frame(width: 4, height: 4)

            // B 盘
            pillarCell(
                gan: p.ganB, zhi: p.zhiB, nayin: p.nayinB,
                ganElement: p.ganElementB, zhiElement: p.zhiElementB,
                label: "B"
            )
        }
        .frame(maxWidth: .infinity)
    }

    /// 单人柱单元格:标签 + 干支(Songti SC)+ 纳音。
    private func pillarCell(
        gan: String, zhi: String, nayin: String,
        ganElement: String, zhiElement: String,
        label: String
    ) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(BaziTheme.inkMuted)
            HStack(spacing: 2) {
                Text(gan)
                    .foregroundStyle(BaziTheme.elementColor(ganElement))
                Text(zhi)
                    .foregroundStyle(BaziTheme.elementColor(zhiElement))
            }
            .font(BaziFont.ganzhi(size: 16))
            Text(nayin)
                .font(.system(size: 9))
                .foregroundStyle(BaziTheme.inkMuted)
                .lineLimit(1)
        }
    }
}

// MARK: - 从 BaziResponse 提炼 4 柱

extension DualPillarSource {
    /// 从 A、B 两份 BaziResponse 提炼 4 柱对比源。
    static func from(a: BaziResponse, b: BaziResponse) -> [DualPillarSource] {
        let pa = a.pillars
        let pb = b.pillars
        return [
            DualPillarSource(
                position: "年柱",
                ganA: pa.year.gan, zhiA: pa.year.zhi, nayinA: pa.year.nayin,
                ganElementA: pa.year.ganElement, zhiElementA: pa.year.zhiElement,
                ganB: pb.year.gan, zhiB: pb.year.zhi, nayinB: pb.year.nayin,
                ganElementB: pb.year.ganElement, zhiElementB: pb.year.zhiElement
            ),
            DualPillarSource(
                position: "月柱",
                ganA: pa.month.gan, zhiA: pa.month.zhi, nayinA: pa.month.nayin,
                ganElementA: pa.month.ganElement, zhiElementA: pa.month.zhiElement,
                ganB: pb.month.gan, zhiB: pb.month.zhi, nayinB: pb.month.nayin,
                ganElementB: pb.month.ganElement, zhiElementB: pb.month.zhiElement
            ),
            DualPillarSource(
                position: "日柱",
                ganA: pa.day.gan, zhiA: pa.day.zhi, nayinA: pa.day.nayin,
                ganElementA: pa.day.ganElement, zhiElementA: pa.day.zhiElement,
                ganB: pb.day.gan, zhiB: pb.day.zhi, nayinB: pb.day.nayin,
                ganElementB: pb.day.ganElement, zhiElementB: pb.day.zhiElement
            ),
            DualPillarSource(
                position: "时柱",
                ganA: pa.hour.gan, zhiA: pa.hour.zhi, nayinA: pa.hour.nayin,
                ganElementA: pa.hour.ganElement, zhiElementA: pa.hour.zhiElement,
                ganB: pb.hour.gan, zhiB: pb.hour.zhi, nayinB: pb.hour.nayin,
                ganElementB: pb.hour.ganElement, zhiElementB: pb.hour.zhiElement
            ),
        ]
    }
}
