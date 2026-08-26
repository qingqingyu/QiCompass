import SwiftUI

/// v1 prompt 系统单模块行(捌章卷轴,水墨孤本 2026-08-26 重排,参考 deep-p1-modules.html)。
///
/// 纯展示组件:接受 `ModuleID` + `ModuleState` + 回调,不依赖具体 ViewModel。
/// 视觉:大写数字圆徽(实线=可读/虚线=锁定)+ 楷体模块名 + 副题 + PaidTag 朱色斜标;
/// 无卡片底,由 InterpretationSection 的 hairline 分隔成卷轴。
///
/// 6 个状态对应 6 种 UI:
/// - pending:副标题 + 等待提示(入口模块 M0 显示"开始"CTA)
/// - fetching:进度 + 文案
/// - ok(text, cached):楷体正文 + cached 标记
/// - failed(message):错误 + 重试
/// - locked:虚线锁框 + 解锁 CTA(付费模块未购买)
/// - needsInput:虚线框 + 提供输入 CTA(M4/M5 按需模块)
struct ModuleCardView: View {
    let module: ModuleID
    let state: ModuleState

    /// 用户点击"生成"CTA(pending / 重新生成)。VM 编排链式调用。
    var onGenerate: () -> Void = {}
    /// 失败重试(.failed case)。Stage 7c VM 决定是否消耗次数。
    var onRetry: () -> Void = {}
    /// 付费模块点击"解锁"CTA(.locked case)。父 View 装配 PaywallView sheet。
    var onUnlock: () -> Void = {}
    /// M4/M5 点击"提供输入"CTA(.needsInput case)。Stage 8 装配 HealthInputForm / WealthInputForm sheet。
    var onProvideInput: () -> Void = {}

    /// 卷轴序号(M0-M7 → 壹-捌;ModuleID.allCases 顺序即章序)。
    private var chapterIndex: Int {
        ModuleID.allCases.firstIndex(of: module) ?? 0
    }

    /// 当前是否处于锁定视觉(付费未购 or .locked state)。
    private var isLockedVisual: Bool {
        if case .locked = state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            headerView

            switch state {
            case .pending:
                pendingBody

            case .fetching:
                fetchingBody

            case .ok(let text, let cached):
                okBody(text: text, cached: cached)

            case .failed(let message):
                failedBody(message: message)

            case .locked:
                lockedBody

            case .needsInput:
                needsInputBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 13)
    }

    // MARK: - Subviews

    /// 行头:大写数字圆徽 + 模块名/副题 + 付费斜标 + cached 标记。
    private var headerView: some View {
        HStack(alignment: .center, spacing: 14) {
            NumeralBadge(index: chapterIndex, locked: isLockedVisual, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(module.displayName)
                    .font(BaziFont.display(size: 15.5))
                    .tracking(1)
                    .foregroundStyle(isLockedVisual ? BaziTheme.inkMuted : BaziTheme.ink)
                Text(module.subtitle)
                    .font(BaziFont.caption(size: 11))
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if module.isPaid {
                PaidTag()
            }
            if case .ok(_, let cached) = state, cached {
                Text("◎ 缓存")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
        }
    }

    /// pending 态:入口模块(M0,无依赖)显示"开始"CTA;其他模块 pending 等链式调用自动触发。
    private var pendingBody: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            if module.dependencies.isEmpty {
                PrimaryCTAButton(
                    title: "开始 M0 分析",
                    loadingTitle: "生成中…",
                    isLoading: false,
                    action: onGenerate
                )
            } else {
                Text("等待上游模块完成…")
                    .font(.caption2)
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
            }
        }
        .padding(.leading, 52)
    }

    /// fetching 态:进度指示。
    private var fetchingBody: some View {
        HStack(spacing: BaziTheme.Spacing.sm) {
            ProgressView()
                .tint(BaziTheme.ink)
            Text("正在生成…")
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            Spacer()
        }
        .padding(.leading, 52)
    }

    /// ok 态:楷体正文 + 宽行距(Medium voice 阅读排版,DESIGN.md §Typography Body)。
    /// 注:Stage 7a 先显示 LLM 返回的原始 JSON 字符串(不过 MarkdownSanitizer — 那是给
    /// markdown 文本用的,JSON 字符串里 `"` `-` `#` `>` 会被误 strip)。
    /// cached 参数已在 headerView 显示缓存标记,此处不再重复。
    private func okBody(text: String, cached _: Bool) -> some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.xs) {
            Text(text)
                .bodySerifText(size: 14.5)
                .lineSpacing(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fadeIn()
            // 2026-08-01 grill-me 决策 #15:不做"再生成"按钮(失败走 .failed 重试)
        }
        .padding(.leading, 52)
    }

    /// failed 态:错误信息 + 重试 CTA。
    /// 重试不消耗每日次数(backend orchestrator 失败 refund,对齐 CLAUDE.md)。
    private func failedBody(message: String) -> some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.xs) {
            Text(message)
                .font(.caption)
                .foregroundStyle(BaziTheme.destructive)
            PrimaryCTAButton(
                title: "重试",
                loadingTitle: "重试中…",
                isLoading: false,
                action: onRetry
            )
        }
        .padding(.leading, 52)
    }

    /// locked 态:虚线锁框 + 解锁 CTA(dashed hairline 专用于锁定,DESIGN.md §Layout)。
    private var lockedBody: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            HStack(spacing: BaziTheme.Spacing.sm) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Text("付费内容,解锁后可生成")
                    .font(BaziFont.caption(size: 12))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(BaziTheme.hairlineDashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            PrimaryCTAButton(
                title: "解锁深度命书",
                loadingTitle: "处理中…",
                isLoading: false,
                action: onUnlock
            )
        }
        .padding(.leading, 52)
    }

    /// needsInput 态:M4/M5 提示提供输入(虚线框呼应锁定框,同为"待补"语义)。
    /// Stage 8 实现 HealthInputForm / WealthInputForm sheet,本 CTA 触发后弹 sheet。
    private var needsInputBody: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            HStack(spacing: BaziTheme.Spacing.sm) {
                Image(systemName: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Text(inputPromptText)
                    .font(BaziFont.caption(size: 12))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(BaziTheme.hairlineDashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            PrimaryCTAButton(
                title: "提供信息",
                loadingTitle: "处理中…",
                isLoading: false,
                action: onProvideInput
            )
        }
        .padding(.leading, 52)
    }

    /// M4/M5 各自的输入提示文案。
    /// 调用方应仅对 needsUserInput=true 的模块(M4/M5)触发 .needsInput state,
    /// 此处 default 分支用 fatalError 显式报错(不静默吞错误,对齐 CLAUDE.md 错误显式传播)。
    private var inputPromptText: String {
        switch module {
        case .m4: return "需要你的年龄与当前困扰(睡眠/疲劳/体重/情绪)"
        case .m5: return "需要你的资产概况与偏好(保守/平衡/进攻)"
        default:
            fatalError("inputPromptText 仅对 M4/M5 有效,收到 module=\(module.rawValue)")
        }
    }
}
