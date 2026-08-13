import SwiftUI

/// 合盘结果列表(决策 D9 列表卡片 / D11 纯展示)。
///
/// S01:每张卡片呈现 PairSummary 字段(名 / 出生日期 / 日主 / 五行互补 + 日主关系两句话 / 已解读标记)。
/// S02:卡片点击进 detail;S03:失败卡片失败态 + 重试。
struct CompatibilityPairListView: View {
    @Bindable var vm: CompatibilityViewModel
    let summaries: [PairSummary]
    let onBackToConfig: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: BaziTheme.Spacing.md) {
                ForEach(summaries) { summary in
                    PairSummaryCard(summary: summary)
                }
            }
            .padding(.horizontal)
            .padding(.top, BaziTheme.Spacing.md)
            .padding(.bottom, 100)  // 给底部 CTA 留位
        }
        .safeAreaInset(edge: .bottom) {
            Button(action: onBackToConfig) {
                HStack {
                    Image(systemName: "square.and.pencil")
                    Text("修改名单")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(BaziTheme.cinnabar)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(BaziTheme.paper.opacity(0.95))
            }
        }
    }
}

/// 单对卡片(决策 D9 + DESIGN.md §视觉)。
///
/// 纸白卡片底色 + hairline 分隔 + 4pt 圆角 + 朱砂点缀(已解读/CTA 色);
/// 不用阴影、不用渐变、不堆装饰(DESIGN.md §AI slop 反模式)。
///
/// S03 后 `status` 字段决定卡片态:成功(本视图)/ 失败(失败态 + 重试)。
struct PairSummaryCard: View {
    let summary: PairSummary

    var body: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            // 顶部:名 + 已解读标记
            HStack(alignment: .firstTextBaseline, spacing: BaziTheme.Spacing.sm) {
                Text(summary.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaziTheme.ink)
                if summary.isInterpreted {
                    Text("已解读")
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.paper)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(BaziTheme.jade, in: Capsule())
                }
                Spacer()
            }

            // 出生日期 + 日主
            HStack(spacing: BaziTheme.Spacing.md) {
                if let birthDate = summary.birthDate {
                    Text(Self.dateFormatter.string(from: birthDate))
                        .font(.caption)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                Text("日主 \(summary.dayMaster)")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
            }

            Divider().background(BaziTheme.hairline)

            // 两句话:五行互补 + 日主关系(决策 D9 信息密度)
            VStack(alignment: .leading, spacing: BaziTheme.Spacing.xs) {
                Text("五行 · \(summary.fiveElements)")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.ink)
                Text("日主 · \(summary.dayMasterRelation)")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.ink)
            }
        }
        .padding(BaziTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.hairline, lineWidth: 0.5))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}
