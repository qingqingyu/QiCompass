import SwiftUI

/// v1 prompt 系统单模块卡片(Stage 7a 引入)。
///
/// 纯展示组件:接受 `ModuleID` + `ModuleState` + 回调,不依赖具体 ViewModel。
/// 与现有 `InterpretationSection`(老 bazi_deep 路径)解耦。
///
/// 6 个状态对应 6 种 UI:
/// - pending:模块名 + 副标题(初始态,等待用户触发 / 等待上游依赖完成)
/// - fetching:ProgressView + 文案
/// - ok(text, cached):LLM 文本 + cached 标记
/// - failed(message):错误 + 重试
/// - locked:锁标 + 解锁 CTA(付费模块未购买)
/// - needsInput:提供输入 CTA(M4/M5 按需模块)
///
/// 视觉:复用 BaziTheme.cardSurface / hairline / cinnabar,对齐 DESIGN.md 现代东方极简。
/// 卡片之间用 BaziTheme.Spacing.md 间距(InterpretationSection ForEach 控制)。
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
        .padding(BaziTheme.Spacing.md)
        .background(
            BaziTheme.cardSurface,
            in: RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
        )
        .overlay(
            RoundedRectangle(cornerRadius: BaziTheme.Radius.md)
                .stroke(BaziTheme.hairline, lineWidth: 0.5)
        )
    }

    // MARK: - Subviews

    /// 卡片头部:模块名 + 付费/免费徽章 + cached 标记。
    private var headerView: some View {
        HStack(spacing: BaziTheme.Spacing.sm) {
            Text(module.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(BaziTheme.ink)
            Spacer()
            if module.isPaid {
                Text("付费")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.cinnabar)
                    .padding(.horizontal, BaziTheme.Spacing.xs)
                    .padding(.vertical, 2)
                    .background(
                        BaziTheme.cinnabarSoft,
                        in: Capsule()
                    )
            }
            if case .ok(_, let cached) = state, cached {
                Text("◎ 缓存")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
        }
    }

    /// pending 态:副标题 + 等待提示。
    private var pendingBody: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.xs) {
            Text(module.subtitle)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            if module.dependencies.isEmpty {
                // 入口模块(无依赖,M0)显示"开始生成"CTA;其他模块 pending 等链式调用自动触发
                PrimaryCTAButton(
                    title: "开始 M0 分析",
                    loadingTitle: "生成中…",
                    isLoading: false,
                    action: onGenerate
                )
            } else {
                Text("等待上游模块完成…")
                    .font(.caption2)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
        }
    }

    /// fetching 态:进度指示。
    private var fetchingBody: some View {
        HStack(spacing: BaziTheme.Spacing.sm) {
            ProgressView()
            Text("正在生成…")
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            Spacer()
        }
    }

    /// ok 态:LLM 文本 + cached 标记。
    /// 注:Stage 7a 先显示 LLM 返回的原始 JSON 字符串(不过 MarkdownSanitizer — 那是给
    /// markdown 文本用的,JSON 字符串里 `"` `-` `#` `>` 会被误 strip)。
    /// Stage 7c 解析关键字段(main_axis / innate / threshold 等)做结构化卡片。
    /// cached 参数已在 headerView 显示缓存标记,此处不再重复。
    private func okBody(text: String, cached _: Bool) -> some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.xs) {
            Text(text)
                .bodySerifText()
                .frame(maxWidth: .infinity, alignment: .leading)
                .fadeIn()
            // 2026-08-01 grill-me 决策 #15:不做"再生成"按钮(失败走 .failed 重试)
        }
    }

    /// failed 态:错误信息 + 重试 CTA。
    /// 重试不消耗每日次数(backend orchestrator 失败 refund,对齐 CLAUDE.md)。
    /// 重试是网络类操作,用 PrimaryCTAButton 与其他 CTA 视觉一致(DESIGN.md §CTA)。
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
    }

    /// locked 态:锁标 + 解锁 CTA(付费模块未购买)。
    /// 视觉对齐 PaidChaptersLockView(锁图标 + opacity 淡蒙层 + 朱砂红 CTA)。
    private var lockedBody: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            Text(module.subtitle)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            HStack(spacing: BaziTheme.Spacing.sm) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(BaziTheme.inkMuted)
                Text("付费内容,解锁后可生成")
                    .font(.body)
                    .foregroundStyle(BaziTheme.ink)
                Spacer()
            }
            .opacity(0.5)
            PrimaryCTAButton(
                title: "解锁深度命书",
                loadingTitle: "处理中…",
                isLoading: false,
                action: onUnlock
            )
        }
    }

    /// needsInput 态:M4/M5 提示提供输入。
    /// Stage 8 实现 HealthInputForm / WealthInputForm sheet,本 CTA 触发后弹 sheet。
    private var needsInputBody: some View {
        VStack(alignment: .leading, spacing: BaziTheme.Spacing.sm) {
            Text(module.subtitle)
                .font(.caption)
                .foregroundStyle(BaziTheme.inkMuted)
            HStack(spacing: BaziTheme.Spacing.sm) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(BaziTheme.inkMuted)
                Text(inputPromptText)
                    .font(.body)
                    .foregroundStyle(BaziTheme.ink)
                Spacer()
            }
            PrimaryCTAButton(
                title: "提供信息",
                loadingTitle: "处理中…",
                isLoading: false,
                action: onProvideInput
            )
        }
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
