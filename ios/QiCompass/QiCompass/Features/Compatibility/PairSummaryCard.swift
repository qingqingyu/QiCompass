import SwiftUI

/// 单对卡片(水墨孤本 H2,2026-08-26 重排,参考 hepan-h2-list.html;2026-09-29 S5
/// 自 CompatibilityPairListView.swift 迁出——整页列表视图已随结果页主页化退役,
/// 卡片由结果壳 list 态内容区复用)。
///
/// hairline 描边对卡(无底色)+ 「合」小印 + 定性一行 + 底部 dashed 分隔的状态行;
/// 失败态 dashed destructive 框 + 单对重试(对级错误隔离不变)。
///
/// `summary.status` 决定卡片态:
/// - .computed → 正常展示(alias / 出生日期 / 日主 / 两句话 / 已解读标记)
/// - .failed(error) → 失败摘要 + 重试按钮,不展示 birthDate/五行/日主关系
/// - .hourUnknownBlocked → S07 拦截态 + S10 CTA(目标盘补时辰 sheet)
struct PairSummaryCard: View {
    let summary: PairSummary
    /// S03:该对是否正在重试中(UI disable 重试按钮)。
    let isRetrying: Bool
    /// S03:失败态卡片的重试回调。
    let onRetry: () -> Void
    /// S10:拦截态卡片的补时辰回调(被拦侧的盘;nil = 临时对方无 hash → CTA 不渲染)。
    var onAddHour: (() -> Void)? = nil

    var body: some View {
        switch summary.status {
        case .computed:
            computedLayout
        case .failed(let error):
            failedLayout(error)
        case .hourUnknownBlocked:
            hourUnknownBlockedLayout
        }
    }

    // MARK: - 时辰未知拦截态(S07,与付费墙拦截同款表达)

    /// 水墨克制:dashed hairline 框 + 留白说明 + 共用拦截组件(无红色警示)。
    /// S10:CTA → 补时辰 sheet(他人盘补时辰同 hash 重建,对级关系自然重算)。
    private var hourUnknownBlockedLayout: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: BaziTheme.Spacing.sm) {
                Text("与 \(summary.displayName)")
                    .font(BaziFont.display(size: 15.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                Spacer()
            }

            HourUnknownGateNotice(
                title: L10n.PaywallGate.compatibilityTitle,
                reason: L10n.PaywallGate.compatibilityReason,
                onAddHour: onAddHour
            )
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(BaziTheme.hairlineDashed, lineWidth: 1)
        )
    }

    // MARK: - 成功态

    private var computedLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部:「与 X」+ 合小印
            HStack(alignment: .center, spacing: 10) {
                Text("与 \(summary.displayName)")
                    .font(BaziFont.display(size: 15.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.ink)
                Spacer()
                SealStamp(character: "合", size: 20, rotation: 4, stampDelay: nil)
            }

            // 定性一行:五行 + 日主关系(决策 D9 信息密度)
            Text("五行\(summary.fiveElements) · 日主\(summary.dayMasterRelation)")
                .font(BaziFont.caption(size: 12.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
                .padding(.top, 10)

            // 底部状态行:dashed 分隔 + 已解读/日期/日主
            HStack(spacing: 14) {
                if summary.isInterpreted {
                    Text("已解读")
                        .font(.caption2)
                        .tracking(1)
                        .foregroundStyle(BaziTheme.jade)
                } else {
                    Text("总览可读")
                        .font(.caption2)
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                if let birthDate = summary.birthDate {
                    Text(Self.dateFormatter.string(from: birthDate))
                        .font(.caption2)
                        .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                Text("日主 \(summary.dayMaster)")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Spacer()
                Text("查看 ›")
                    .font(.caption2)
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            .padding(.top, 10)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(BaziTheme.hairlineDashed)
                    .frame(height: 0.5)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(BaziTheme.hairline, lineWidth: 1)
        )
    }

    // MARK: - 失败态(S03)

    private func failedLayout(_ error: UserFacingError) -> some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: BaziTheme.Spacing.sm) {
                Text("与 \(summary.displayName)")
                    .font(BaziFont.display(size: 15.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                Spacer()
                // 失败态:朱色文字标(不做实底块)
                Text("推演失败 · 此对隔离")
                    .font(.caption2)
                    .tracking(1)
                    .foregroundStyle(BaziTheme.destructive)
            }

            // 错误摘要(不静默吞,展示真实错误描述)
            Text(error.errorDescription ?? L10n.Common.unknownError)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            Text(error.subtitle)
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)

            // 重试按钮(单对重试,不拖垮其他对)
            Button(action: onRetry) {
                HStack(spacing: 4) {
                    if isRetrying {
                        ProgressView()
                            .tint(BaziTheme.ink)
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRetrying ? String(localized: "重试中…") : String(localized: "重试这一对"))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
            }
            .disabled(isRetrying)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(BaziTheme.destructive.opacity(0.35),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}
