import SwiftUI

/// 章节沉浸阅读页(盘面小景 ⑤-⑧):长文排版的唯一去处。
///
/// 结构:自定义顶 bar(‹ + 章题 + 目录)+ 左缘竖章号栏(44pt,hairline 分隔,
/// 章号 28pt 楷体,随页贯穿)+ 正文区 + 底部翻章条(hairline 上边)。
///
/// 正文排版(DESIGN.md §Body 首次落地):楷体 15.5pt · 行距 2.15× · 首行缩进
/// 2em(全角空格实现,SwiftUI Text 无 text-indent)· 两端对齐;章末右下朱批印。
///
/// 四态(同一页原地切换,不 pop):
/// - .ok:正文 + 章末「批」印
/// - .fetching / .pending:三墨点 breathe + 竖排「布算中」+ 小注(reduce-motion 静态)
/// - .failed:人话错误 + 原地重试 CTA + 「重试不消耗今日次数」
/// - .needsInput:S3 前沿用 M4/M5 sheet 表单(Stage 8 既有组件),S3 换页内表单
/// - .locked:防御态(目录不推锁章,但购买回退/状态错乱时诚实呈现解锁 CTA)
struct ChapterReadingView: View {
    @Bindable var vm: DeepAnalysisViewModel
    let module: ModuleID
    let response: BaziResponse
    /// 付费墙触点(下一章锁 / 防御 locked 态 CTA):上抛宿主弹 PaywallView sheet。
    var onShowPaywall: () -> Void
    /// 章间跳转(上一章/下一章):宿主替换 navigation path,单destination不叠栈。
    var onNavigate: (ModuleID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 章序(0-7,M0=壹 … M7=捌)。
    private var chapterIndex: Int {
        ModuleID.allCases.firstIndex(of: module) ?? 0
    }

    private var chapterState: ModuleState {
        vm.moduleStates[module] ?? .pending
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                edgeNumeral
                contentArea
            }
            pager
        }
        .background(BaziTheme.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: - 顶 bar(自定义,系统导航栏隐藏)

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .padding(6)
            }
            Spacer()
            Text("\(NumeralBadge.numeral(chapterIndex)) · \(chapterTitle)")
                .font(BaziFont.caption(size: 12.5))
                .tracking(2)
                .foregroundStyle(BaziTheme.inkMuted)
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("目录")
                    .font(BaziFont.caption(size: 12.5))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .padding(6)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    /// 章名(displayName 去「M{N} · 」前缀;不动 ModuleDefinitions,守护栏)。
    private var chapterTitle: String {
        let name = module.displayName
        guard let separator = name.range(of: "· ") else { return name }
        return String(name[separator.upperBound...])
    }

    // MARK: - 左缘竖章号

    private var edgeNumeral: some View {
        Text(NumeralBadge.numeral(chapterIndex))
            .font(BaziFont.display(size: 28))
            .foregroundStyle(BaziTheme.ink)
            .frame(width: 44)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 50)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(BaziTheme.hairline)
                    .frame(width: 0.5)
            }
            .background(BaziTheme.cardSurface.opacity(0.5))
            .accessibilityHidden(true)
    }

    // MARK: - 正文区(四态)

    @ViewBuilder
    private var contentArea: some View {
        ScrollView {
            switch chapterState {
            case .ok(let text, _):
                chapterBody(text: text)
            case .fetching, .pending:
                calculatingBody
            case .failed(let message):
                failedBody(message: message)
            case .locked:
                lockedBody
            case .needsInput:
                needsInputBody
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 正文态:章题 + 副题 + hairline + 楷体正文(15.5/2.15×/缩进 2em)+ 章末批印。
    private func chapterBody(text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(chapterTitle)
                .font(BaziFont.display(size: 21))
                .tracking(3)
                .foregroundStyle(BaziTheme.ink)
                .padding(.top, 46)
            Text(module.subtitle)
                .font(BaziFont.caption(size: 10.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .padding(.top, 4)
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)
                .padding(.trailing, 34)
                .padding(.top, 16)
            Text(indentedProse(text))
                .bodySerifText(size: 15.5)
                .lineSpacing(18) // 行距 2.15× ≈ 15.5 × 1.15(SwiftUI 默认行高 ~1.2em)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 15)
                .padding(.bottom, 18)
            // 章末朱批印(落款,非朱字批语——后者依赖 prompt 输出,backlog)
            HStack {
                Spacer()
                SealStamp(character: "批", size: 26, rotation: 3, stampDelay: 0.2)
            }
            .padding(.trailing, 8)
            .padding(.bottom, 24)
        }
        .padding(.leading, 24)
        .padding(.trailing, 26)
    }

    /// 首行缩进 2em:SwiftUI Text 无 text-indent,全角空格前缀实现;
    /// 多段(LLM 文本含换行)逐段缩进,空行保留为段间距。
    private func indentedProse(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { line in
                line.trimmingCharacters(in: .whitespaces).isEmpty ? "" : "　　" + line
            }
            .joined(separator: "\n")
    }

    /// 生成中:三墨点 breathe + 竖排「布算中」(reduce-motion 静态降级)。
    private var calculatingBody: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 90)
            HStack(spacing: 14) {
                ForEach(Array([1.0, 0.55, 0.22].enumerated()), id: \.offset) { _, opacity in
                    Circle()
                        .fill(BaziTheme.inkDeep)
                        .opacity(opacity)
                        .frame(width: 9, height: 9)
                }
            }
            .breathe()
            Text("布算中")
                .font(BaziFont.display(size: 15))
                .tracking(8)
                .foregroundStyle(BaziTheme.ink)
            Text("正在生成本章 · 约 10-20 秒 · 失败不消耗次数")
                .font(BaziFont.caption(size: 10.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Spacer(minLength: 90)
        }
        .frame(maxWidth: .infinity)
    }

    /// 失败:人话错误 + 原地重试(失败 refund,重试不耗次数)。
    private func failedBody(message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chapterTitle)
                .font(BaziFont.display(size: 21))
                .tracking(3)
                .foregroundStyle(BaziTheme.ink)
                .padding(.top, 46)
            Text(message)
                .font(BaziFont.caption(size: 13))
                .foregroundStyle(BaziTheme.destructive)
                .lineSpacing(5)
            PrimaryCTAButton(
                title: "重试本章",
                loadingTitle: "重试中…",
                isLoading: false,
                action: { vm.retryV1Module(module) }
            )
            Text("重试不消耗今日次数")
                .font(BaziFont.caption(size: 10.5))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Spacer()
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 防御 locked 态(目录不推锁章;购买回退/状态错乱时诚实呈现)。
    private var lockedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chapterTitle)
                .font(BaziFont.display(size: 21))
                .tracking(3)
                .foregroundStyle(BaziTheme.ink)
                .padding(.top, 46)
            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                Text("付费内容,解锁后可生成")
                    .font(BaziFont.caption(size: 12))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
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
                action: onShowPaywall
            )
            Spacer()
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - M4/M5 needsInput(页内两问表单,定稿 ⑧)

    /// 章题 + 副题 + 亮纸框两问表单:原地作答,提交走 VM.submitM4/M5Input
    /// (内部自动重试,状态流翻到 fetching→ok,不离开阅读页)。
    @ViewBuilder
    private var needsInputBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chapterTitle)
                .font(BaziFont.display(size: 21))
                .tracking(3)
                .foregroundStyle(BaziTheme.ink)
                .padding(.top, 46)
            Text(module.subtitle)
                .font(BaziFont.caption(size: 10.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            if module.needsUserInput {
                ChapterReadingInputForm(
                    module: module,
                    initialM4: vm.m4UserInput,
                    initialM5: vm.m5UserInput,
                    onSubmitM4: { age, concern in
                        vm.submitM4Input(age: age, concern: concern)
                    },
                    onSubmitM5: { assets, preference in
                        vm.submitM5Input(assets: assets, preference: preference)
                    }
                )
            } else {
                // 目录/CTA 不推 needsInput 态的章;到这说明状态机错乱,显式记录
                let _ = AppLogger.app.error("chapterReading.needsInputBody unexpected module=\(module.rawValue, privacy: .public)")
            }
            Spacer()
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 底部翻章条

    private var pager: some View {
        let prev = chapterIndex > 0 ? ModuleID.allCases[chapterIndex - 1] : nil
        let next = chapterIndex < ModuleID.allCases.count - 1 ? ModuleID.allCases[chapterIndex + 1] : nil
        return HStack {
            if let prev {
                pagerButton("‹ \(pagerTitle(prev))", module: prev)
            } else {
                Spacer()
            }
            Spacer()
            if let next {
                let nextLocked = next.isPaid && vm.moduleStates[next]?.isOk != true
                if nextLocked {
                    Button {
                        onShowPaywall()
                    } label: {
                        Text("\(pagerTitle(next)) 🔒")
                            .font(BaziFont.caption(size: 11.5))
                            .tracking(1)
                            .foregroundStyle(BaziTheme.inkMutedSecondary)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                } else {
                    pagerButton("\(pagerTitle(next)) ›", module: next)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)
        }
    }

    private func pagerButton(_ label: String, module target: ModuleID) -> some View {
        Button {
            onNavigate(target)
        } label: {
            Text(label)
                .font(BaziFont.caption(size: 11.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
                .lineLimit(1)
                .padding(6)
        }
        .buttonStyle(.plain)
    }

    /// 翻章条标题:「贰 天赋能力」。
    private func pagerTitle(_ module: ModuleID) -> String {
        let idx = ModuleID.allCases.firstIndex(of: module) ?? 0
        let name = module.displayName
        let title = name.range(of: "· ").map { String(name[$0.upperBound...]) } ?? name
        return "\(NumeralBadge.numeral(idx)) \(title)"
    }
}

// MARK: - breathe 修饰符(三墨点,DESIGN.md §Motion 常驻微呼吸 7-8s)

private struct BreatheModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    func body(content: Content) -> some View {
        content
            .opacity(breathing ? 0.92 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 3.6).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

private extension View {
    func breathe() -> some View {
        modifier(BreatheModifier())
    }
}
