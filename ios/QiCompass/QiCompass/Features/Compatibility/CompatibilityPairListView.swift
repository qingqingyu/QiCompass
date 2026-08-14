import SwiftUI

/// 合盘结果列表(决策 D9 列表卡片 / D11 纯展示 / S03 对级错误隔离)。
///
/// S01:每张卡片呈现 PairSummary 字段。
/// S02:卡片点击进 detail(成功态)。
/// S03:失败卡片失败态 + 重试按钮 + 不可进详情(对级错误隔离)。
struct CompatibilityPairListView: View {
    @Bindable var vm: CompatibilityViewModel
    let summaries: [PairSummary]
    let onBackToConfig: () -> Void
    /// S02:点卡片进详情(仅成功态卡片调用)。
    let onOpenSummary: (PairSummary) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: BaziTheme.Spacing.md) {
                ForEach(summaries) { summary in
                    if summary.isComputed {
                        // 成功态:点卡片进详情
                        Button {
                            onOpenSummary(summary)
                        } label: {
                            PairSummaryCard(
                                summary: summary,
                                isRetrying: false,
                                onRetry: {}
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        // 失败态(S03):不进详情,显示重试按钮
                        PairSummaryCard(
                            summary: summary,
                            isRetrying: vm.retryingIds.contains(summary.id),
                            onRetry: { vm.retryPair(summary: summary) }
                        )
                    }
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

/// 单对卡片(决策 D9 + DESIGN.md §视觉 + S03 失败态)。
///
/// 纸白卡片底色 + hairline 分隔 + 4pt 圆角 + 朱砂点缀;
/// 不用阴影、不用渐变、不堆装饰(DESIGN.md §AI slop 反模式)。
///
/// S03:`summary.status` 决定卡片态:
/// - .computed → 正常展示(alias / 出生日期 / 日主 / 两句话 / 已解读标记)
/// - .failed(error) → 失败摘要 + 重试按钮,不展示 birthDate/五行/日主关系
struct PairSummaryCard: View {
    let summary: PairSummary
    /// S03:该对是否正在重试中(UI disable 重试按钮)。
    let isRetrying: Bool
    /// S03:失败态卡片的重试回调。
    let onRetry: () -> Void

    var body: some View {
        switch summary.status {
        case .computed:
            computedLayout
        case .failed(let error):
            failedLayout(error)
        }
    }

    // MARK: - 成功态

    private var computedLayout: some View {
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

    // MARK: - 失败态(S03)

    private func failedLayout(_ error: UserFacingError) -> some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: BaziTheme.Spacing.sm) {
                Text(summary.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BaziTheme.ink)
                Spacer()
                // 朱砂/destructive 点缀(DESIGN.md)标记失败态
                Text("推演失败")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.paper)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(BaziTheme.destructive, in: Capsule())
            }

            // 错误摘要(不静默吞,展示真实错误描述)
            Text(error.errorDescription ?? "未知错误")
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            Text(error.subtitle)
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMuted)

            // 重试按钮(单对重试,不拖垮其他对)
            Button(action: onRetry) {
                HStack(spacing: 4) {
                    if isRetrying {
                        ProgressView()
                            .tint(BaziTheme.cinnabar)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRetrying ? "重试中…" : "重试")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(BaziTheme.cinnabar)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(BaziTheme.cinnabarSoft, in: Capsule())
            }
            .disabled(isRetrying)
        }
        .padding(BaziTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BaziTheme.cardSurface, in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: BaziTheme.Radius.md).stroke(BaziTheme.destructive.opacity(0.4), lineWidth: 0.5))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}
