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
/// - .ok:正文 + 章末「批」印(JSON 形态但解析失败 → 显式异常态 + 重生成 CTA,不裸奔)
/// - .fetching / .pending:三墨点 breathe + 竖排「布算中」+ 小注(reduce-motion 静态)
/// - .failed:人话错误 + 原地重试 CTA + 「重试不消耗今日次数」
/// - .needsInput:M4/M5 页内两问表单(ChapterReadingInputForm,原地作答)
/// - .locked:防御态(目录不推锁章,但购买回退/状态错乱时诚实呈现解锁 CTA)
struct ChapterReadingView: View {
    @Bindable var vm: DeepAnalysisViewModel
    let module: ModuleID
    let response: BaziResponse
    /// 付费墙触点(下一章锁 / 防御 locked 态 CTA):上抛宿主弹 PaywallView sheet。
    var onShowPaywall: () -> Void
    /// 章间跳转(上一章/下一章):宿主替换 navigation path,单destination不叠栈。
    var onNavigate: (ModuleID) -> Void
    /// 「重新排盘」出口(2026-10-08 外评 #7):深度 tab 内的 RecalculateChartButton
    /// 传宿主动作——清阅读页导航 + vm.reset() 落回排盘表单。用户已在深度 tab,
    /// 按钮默认的 switchTab 在此无可见效果(点了没反应),必须显式换动作。
    var onRecalculateChart: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// 本地 entitlement 查询:VM 单源方法(与付费守卫/主页目录行同口径),只读。
    /// 翻章条 🔒 判定用——已购用户的付费章翻章不弹墙,进章布算/原地重试。
    private var hasEntitlementForPaid: Bool {
        vm.hasDeepEntitlement(contentHash: response.contentHash)
    }

    /// 章序原始下标(0-7,仅作数组运算;展示章号用 chapterNumeral,见下)。
    private var chapterIndex: Int {
        ModuleID.allCases.firstIndex(of: module) ?? 0
    }

    /// 展示章号:M0=壹 … M7=捌(设计稿⑤口径;2026-09-02 修 off-by-one,
    /// 原 numeral(chapterIndex) 显示零-柒)。
    private var chapterNumeral: String {
        NumeralBadge.numeral(chapterIndex + 1)
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
            // 2026-09-25 暗色走查 #11:顶 bar 不再带章号——左缘竖章号栏(edgeNumeral)已表达
            // 「贰」,正文大标题表达「天赋能力」,原先三处重复读起来像复读。
            Text(chapterTitle)
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

    /// 章名(displayName 去「M{N} · 」前缀;S4 收敛到 ModuleID.chapterName)。
    private var chapterTitle: String {
        module.chapterName
    }

    // MARK: - 左缘竖章号

    private var edgeNumeral: some View {
        Text(chapterNumeral)
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
            case .contextTokenExpired:
                contextTokenExpiredBody
            case .dailyLimitReached(let nextReset):
                dailyLimitReachedBody(nextReset: nextReset)
            case .locked:
                lockedBody
            case .needsInput:
                needsInputBody
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 正文态:章题 + 副题 + hairline + 正文(模块 JSON → ChapterContentView 结构化
    /// 排版;散文退回 15.5/2.15×/缩进 2em;JSON 形态但解析失败 → 显式异常态)+ 章末批印。
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
            // L3/F1:本章仍是待译原文且翻译链在飞 → 章首小注(原文照常展示,
            // 译完整章替换)。视觉:hairline ink@18% 级弱提示,不用朱红。
            if vm.isChapterTranslationPending(module) {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(String(
                        format: String(localized: "正在译为%@…"),
                        AppLanguage.displayName(forWire: AppLanguage.currentWire)
                    ))
                    .font(BaziFont.caption(size: 10.5))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                }
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // R2(2026-10-02 review):本章翻译失败 → 原文照常展示,章首小注
            // 「翻译失败 · 重试」;点击 = 重试翻译(不扣次数)。视觉与
            // 「正在译为」同款弱提示。
            else if vm.isChapterTranslationFailed(module) {
                Button {
                    vm.acceptTranslation()
                } label: {
                    Text(String(localized: "翻译失败 · 重试"))
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMuted)
                        .underline()
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 正文(2026-09-02):模块输出是 JSON(v1 链式契约)→ 结构化排版;
            // 解析失败(非 JSON/非法 JSON,如老缓存散文或 LLM 违约)退回散文并记日志。
            // 2026-10-01 加固:parse 失败且内容呈 JSON 形态(截断半截/契约破坏)→
            // 显式异常态,不再把 JSON 原文当散文排版(裸奔)。
            if let content = ChapterContent.parse(text) {
                ChapterContentView(content: content)
                    .padding(.top, 15)
                    .padding(.bottom, 18)
                chapterSeal
            } else if ChapterContent.looksLikeJSON(text) {
                // 读缓存层自愈(CachedInterpretationReader.purgeIfPoisoned)已在冷启动
                // 拦截存量中毒行;到达此处 = 新破损绕过了上游校验,error 级留痕。
                // 异常态不挂章末「批」印(印 = 章成落款,与 .failed 态同口径不盖章)。
                let _ = AppLogger.app.error(
                    "chapterReading.contentUnrenderableJSON module=\(module.rawValue, privacy: .public) len=\(text.count) — 显示异常态,不裸奔 JSON"
                )
                corruptedBody
            } else {
                let _ = AppLogger.app.warning(
                    "chapterReading.contentParseMiss module=\(module.rawValue, privacy: .public) — 退回散文排版"
                )
                Text(indentedProse(text))
                    .bodySerifText(size: 15.5)
                    .lineSpacing(18) // 行距 2.15× ≈ 15.5 × 1.15(SwiftUI 默认行高 ~1.2em)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 15)
                    .padding(.bottom, 18)
                chapterSeal
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 26)
    }

    /// 章末朱批印(落款,非朱字批语——后者依赖 prompt 输出,backlog)。
    private var chapterSeal: some View {
        HStack {
            Spacer()
            SealStamp(character: "批", size: 26, rotation: 3, stampDelay: 0.2)
        }
        .padding(.trailing, 8)
        .padding(.bottom, 24)
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

    /// 内容异常态(parse 失败且内容呈 JSON 形态,2026-10-01):人话说明 + 原地重生成。
    /// CTA 与 .failed 态同一重试路径(`vm.retryV1Module`,生成失败退款不耗次数;
    /// 点击后 moduleStates 翻 .fetching,整页自动切换布算中态)。
    /// R2(2026-10-02 review):本章还有跨语言原文行时,重试语义是**重译**
    /// (转发 acceptTranslation,不扣次数)——原文行被消费前走重生成,
    /// STALE/翻译重试会把本章按旧原文再处理,白烧次数。
    private var corruptedBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "本章内容生成时出现异常,重新生成即可恢复"))
                .font(BaziFont.caption(size: 13))
                .foregroundStyle(BaziTheme.inkMuted)
                .lineSpacing(5)
            PrimaryCTAButton(
                title: String(localized: "重新生成本章"),
                loadingTitle: String(localized: "生成中…"),
                isLoading: false,
                action: retryCurrentChapter
            )
        }
        .padding(.top, 15)
        .padding(.bottom, 18)
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
            Text(L10n.DeepChain.readingGenerating)
                .font(BaziFont.caption(size: 10.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Text(L10n.DeepChain.readingLeaveHint)
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
                title: String(localized: "重试本章"),
                loadingTitle: String(localized: "重试中…"),
                isLoading: false,
                action: retryCurrentChapter
            )
            Text("重试不消耗今日次数")
                .font(BaziFont.caption(size: 10.5))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Spacer()
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 凭证失效(2026-10-08):老快照盘的章节生成/翻译必 403——章题 +
    /// 失效说明 + 「重新排盘」出口(无「重试本章」,点了必然再 403)。
    /// 出口动作 = onRecalculateChart(清导航 + reset 回表单,外评 #7:
    /// 用户已在深度 tab,switchTab 无可见效果);重排后新 chart 快照带新
    /// token,链自动自愈。
    private var contextTokenExpiredBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chapterTitle)
                .font(BaziFont.display(size: 21))
                .tracking(3)
                .foregroundStyle(BaziTheme.ink)
                .padding(.top, 46)
            Text(L10n.Errors.contextTokenTitle)
                .font(BaziFont.caption(size: 13))
                .foregroundStyle(BaziTheme.destructive)
                .lineSpacing(5)
            Text(L10n.Errors.contextTokenSubtitle)
                .font(BaziFont.caption(size: 10.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            RecalculateChartButton(action: onRecalculateChart)
            Spacer()
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 服务端免费配额达限(2026-10-08 外评 #6):章题 + 达限文案(b3c76d8 双池
    /// 口径中立版)+ UTC 零点倒计时。**禁重试**——重试本章/回前台自动续跑
    /// 只会反复 429(服务端池与本地 10 次/日池不同源,共享 IP/多设备会先耗尽
    /// 服务端池);nextReset 取下一个 UTC 零点(后端 bucket 按 UTC 日)。
    private func dailyLimitReachedBody(nextReset: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(chapterTitle)
                .font(BaziFont.display(size: 21))
                .tracking(3)
                .foregroundStyle(BaziTheme.ink)
                .padding(.top, 46)
            Text(L10n.Errors.limitTitle)
                .font(BaziFont.caption(size: 13))
                .foregroundStyle(BaziTheme.destructive)
                .lineSpacing(5)
            Text(L10n.Errors.limitSubtitle)
                .font(BaziFont.caption(size: 10.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            CountdownResetLabel(nextReset: nextReset)
                .padding(.top, 2)
            Spacer()
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 章节级「重试」分流(R2,2026-10-02 review):本章有未消费的跨语言
    /// 原文行(STALE 降级重生成失败保留原行的场景)→ 重译(免次数);
    /// 否则才是正常重新生成。
    private func retryCurrentChapter() {
        if vm.hasCrossLanguageOriginal(for: module) {
            vm.acceptTranslation()
        } else {
            vm.retryV1Module(module)
        }
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
                title: String(localized: "解锁深度命书"),
                loadingTitle: String(localized: "处理中…"),
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
                // 🔒 判定走 ChapterRowModel 单一事实源(与主页目录行同语义):
                // 已购用户的付费章不锁(进章布算/原地重试),未购才弹付费墙
                let nextLocked = ChapterRowModel.resolve(
                    module: next,
                    state: vm.moduleStates[next],
                    hasEntitlement: hasEntitlementForPaid
                ) == .lockedPaid
                if nextLocked {
                    Button {
                        onShowPaywall()
                    } label: {
                        // 2026-09-25 暗色走查 #11:🔒 彩色 emoji 与水墨单色语言冲突,
                        // 换单色 SF Symbol(继承 inkMutedSecondary,深浅色自适应)。
                        HStack(spacing: 3) {
                            Text(pagerTitle(next))
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8.5))
                        }
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

    /// 翻章条标题:「贰 天赋能力」(M0=壹 … M7=捌,与章号同口径 +1)。
    private func pagerTitle(_ module: ModuleID) -> String {
        let idx = ModuleID.allCases.firstIndex(of: module) ?? 0
        let name = module.displayName
        let title = name.range(of: "· ").map { String(name[$0.upperBound...]) } ?? name
        return "\(NumeralBadge.numeral(idx + 1)) \(title)"
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
