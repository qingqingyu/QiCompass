import SwiftUI

/// 购买弹窗(底部 sheet + grabber)。
///
/// M3c 决策(用户拍板):底部 sheet(默认 .medium)而非全屏
/// (避免与 OnboardingView 视觉重复)。2026-08-31 修 bug 加 .large:
/// 8 章清单 + 登录区理想高度 ~750pt,.medium(~392pt)装不下且无滚动,
/// 超高内容被 sheet 居中裁切(首章「壹」不可见);内容入 ScrollView
/// 顶部锚定 + .large 可拉满,彻底消灭裁切。
///
/// 视觉:遵守 DESIGN.md 宋瓷极简美学(无金色 / 无磨砂玻璃),
/// 锁标用 `lock.fill` + `inkMuted`,CTA 用朱砂红 PrimaryCTAButton。
///
/// 价格:M3c 硬编码 ¥128(中国区 Price Tier 60 估算,MONETIZATION.md §商品 SKU);
/// M3b 接 StoreKit 后改用 `Product.displayPrice`(App Store Connect 真价)。
struct PaywallView: View {
    @State private var viewModel: PaywallViewModel
    @EnvironmentObject private var env: AppEnvironment

    init(viewModel: PaywallViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        // 2026-08-31 修复:内容整体入 ScrollView(顶部锚定滚动)。
        // 此前是固定 VStack:8 章清单 + 印章头 + 登录区理想高度 ~750pt,
        // 远超 .medium 内容区(~392pt),超高内容被 sheet 垂直居中,
        // 上下两端同时裁掉——顶部丢「解」印 + 标题 + 「壹·命盘」行
        // (用户看到清单从「贰」开始),底部丢登录按钮 + 法律注。
        // detents 加 .large:拉起后整屏放下全部捌章(参考屏 deep-p3
        // 本就是 ~478px 高的 sheet,medium 只装得下前几行)。
        // S07 拦截态同入此容器(内容短,顶部锚定不受影响)。
        ScrollView {
            VStack(spacing: BaziTheme.Spacing.md) {
                if viewModel.isPurchaseIntercepted {
                    // S07 时辰未知拦截态(D6):不展示价格、不展示购买按钮、不加载
                    // StoreKit product(purchase 在 VM 层另有守卫,纵深防御)。
                    // D9 二期正式版文案:为什么拦(双重收费人话版)+ 补时辰引导;
                    // S10 接线 CTA → 补时辰 sheet;静默态文案降中性(入口保留)。
                    HourUnknownGateNotice(
                        title: L10n.PaywallGate.title,
                        reason: L10n.PaywallGate.paywallReason,
                        silenced: viewModel.hourUnknownSilenced,
                        onAddHour: viewModel.onAddHour
                    )
                } else {
                    purchaseBody
                }
            }
            // 顶部留白:给系统 drag indicator 让位(原自定义 Capsule grabber 删:
            // presentationDragIndicator(.visible) 本就画一个,内容不再被裁后会出现双横条)
            .padding(.top, BaziTheme.Spacing.md)
            .padding(.horizontal, BaziTheme.Spacing.lg)
            .padding(.bottom, BaziTheme.Spacing.lg)
        }
        .presentationBackground(BaziTheme.cardSurface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { await viewModel.loadProduct() }
    }

    // MARK: - B 章回分段派生(呈现层;判据与 Fix#3 购买按钮分支同构)

    /// 当前契约步(贰 钤印 / 叁 成契;壹 观其价打开即完成,无「进行中」态)。
    private var contractStep: PaywallContractStep {
        var signedIn = false
        if case .signedIn = env.accountManager.state { signedIn = true }
        return .derive(signedIn: signedIn, exchangeDone: env.accountManager.exchangeState == .done)
    }

    /// exchange 进行中(stepper 贰的副题切「钤印中…」)。
    private var isExchangingSeal: Bool {
        if case .signedIn = env.accountManager.state, env.accountManager.exchangeState == .inFlight {
            return true
        }
        return false
    }

    /// 第贰步标题行(未登录 / exchange 进行中 / 失败三分支共用,文案单一事实源)。
    private var sealingStepTitle: some View {
        StepTitleRow(
            stepNo: "第贰步",
            title: "钤印为凭",
            hint: "登录只为保存购买凭证 · 换机可恢复"
        )
    }

    /// 正常付费墙内容(有时辰用户)。购买链路与 S07 前一致(viewModel.purchase /
    /// PrimaryCTAButton);B 章回分段(2026-09-05)重排呈现层:stepper + 落价块 + 分步标题行。
    private var purchaseBody: some View {
        VStack(spacing: BaziTheme.Spacing.md) {
            // 水墨孤本(deep-p3):「解」印 + 标题 + 副题
            HStack(spacing: 14) {
                SealStamp(character: "解", size: 34, rotation: -4, stampDelay: 0.45)
                VStack(alignment: .leading, spacing: 5) {
                    Text("解锁余下\(NumeralBadge.numeral(viewModel.module.paidChapters.count))章")
                        .font(BaziFont.display(size: 19))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.ink)
                    Text("一次买断 · 全设备同步")
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, BaziTheme.Spacing.xs)

            // B 章回分段(2026-09-05 拍板):壹 观其价(打开即完成,价格未登录即见)
            // → 贰 钤印(登录)→ 叁 成契(购买)。分段信号 = 显式 stepper,零学习成本。
            ContractStepper(
                step: contractStep,
                isExchanging: isExchangingSeal,
                isPurchased: viewModel.state == .success
            )

            // 落价块:合同式大写数字(防篡改语义,呼应大写数字品牌指纹);
            // 角分价/千分位/越界 → 无大写,只显本地化数字(不造假)。
            PricePlate(
                upperPrice: viewModel.chineseUpperPrice,
                rawPrice: viewModel.rawPriceText
            )

            // 章节清单:大写数字徽(锁定虚线圆)+ 章名 + dashed hairline 分隔
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.module.paidChapters.enumerated()), id: \.element) { idx, chapter in
                    HStack(spacing: 12) {
                        NumeralBadge(index: idx + 1, locked: true, size: 28)
                        Text(chapter)
                            .font(BaziFont.body(size: 14))
                            .foregroundStyle(BaziTheme.ink)
                        Spacer()
                    }
                    .padding(.vertical, 9)
                    if idx < viewModel.module.paidChapters.count - 1 {
                        Rectangle()
                            .fill(BaziTheme.hairlineDashed)
                            .frame(height: 0.5)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 失败时显示错误文案(诊断 + UX:避免按钮恢复 idle 让用户以为"没反应")
            if case .failed(let message) = viewModel.state {
                errorCaption(message)
            }

            // CTA(Slice 5 决策:强制登录购买;Fix#3:登录 = exchange 完成,非仅 SIWA 成功)。
            // exchangeState(@Observable)驱动自动切按钮,不需要手动 dismiss / 跳转:
            // 购买按钮只在 qicompassUserId 落地后出现,与 PurchaseManager 的
            // isAuthenticated gate 同源,消灭"显示可购买、点了却报『请先登录』"死锁。
            // 防御:exchange 进行中 signOut 的竞态下,迟到的 .done 会与 .signedOut 并存,
            // 补 state 判据让该场景走登录区(正常流 .done 必然伴随 .signedIn,零行为变化)。
            //
            // B 章回分段呈现:操作区带「第几步」标题行,登录动机一句话钉死
            // (「登录只为保存购买凭证」),分段感来自 stepper + 标题行,不来自按钮换位。
            if case .signedIn = env.accountManager.state, env.accountManager.exchangeState == .done {
                // 叁 · 成契:购买就绪
                VStack(spacing: BaziTheme.Spacing.sm) {
                    StepTitleRow(
                        stepNo: "第叁步",
                        title: "成契",
                        hint: "Apple 确认后即解印 · 买断制不含订阅"
                    )
                    PrimaryCTAButton(
                        title: viewModel.displayPriceText,
                        loadingTitle: "处理中…",
                        isLoading: viewModel.state == .purchasing,
                        action: { Task { await viewModel.purchase() } }
                    )
                }
            } else if case .signedIn = env.accountManager.state {
                // SIWA 成功但账号未就绪(exchange 进行中 / 失败)
                switch env.accountManager.exchangeState {
                case .inFlight:
                    // 贰 · 钤印进行中:三墨点 breathe(DESIGN 动效三式,breathe 变奏)
                    VStack(spacing: BaziTheme.Spacing.sm) {
                        sealingStepTitle
                        VStack(spacing: BaziTheme.Spacing.sm) {
                            SealingDots()
                            Text("钤印中 · 正在完成登录…")
                                .font(.caption)
                                .foregroundStyle(BaziTheme.inkMuted)
                        }
                        .frame(maxWidth: .infinity)
                        // 与 AppleSignInButton 同高,登录区切换时 sheet 布局不跳
                        .frame(height: 50)
                    }
                case .failed(let message):
                    // exchange 失败:显错 + 重新登录重试(SIWA 已授权过,重登通常无感)
                    VStack(spacing: BaziTheme.Spacing.sm) {
                        sealingStepTitle
                        errorCaption(message)
                        AppleSignInButton(onResult: { result in
                            env.accountManager.handleAuthorization(result)
                        })
                        GoogleSignInButton {
                            env.accountManager.handleGoogleSignIn()
                        }
                    }
                case .idle, .done:
                    // 防御:signedIn 但 exchangeState 未定义(不变量破坏,正常不应出现)
                    signInPrompt
                }
            } else {
                // 未登录 / SIWA 失败(Fix#1:登录失败显式显错)
                signInPrompt
            }

            // 法律免责(DESIGN.md 反 AI slop + 命理类审核要求)
            Text("玄学娱乐,理性参考。\n购买即视为同意 Apple 标准用户协议。")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .multilineTextAlignment(.center)
                .tracking(1)
        }
    }

    /// 错误文案(购买失败 / 登录失败共用):caption + 凶色 + 居中。
    /// 颜色用 shenshaInauspicious(与 ProfileView 的 destructive 不同,
    /// 跟本 sheet 内既有购买失败文案保持一致)。
    private func errorCaption(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(BaziTheme.shenshaInauspicious)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    /// 未登录态的登录区(第贰步标题行 + 中性提示或登录失败显错 + 登录按钮)。
    private var signInPrompt: some View {
        VStack(spacing: BaziTheme.Spacing.sm) {
            sealingStepTitle
            // 登录失败显式显错(行为对齐 ProfileView accountSection .failed 分支:
            // 显错 + 保留重试按钮;样式见 errorCaption)。
            // 不渲染的话 SIWA 失败后 UI 无任何反馈,用户只看到按钮"没反应"。
            if case .failed(let message) = env.accountManager.state {
                errorCaption(message)
            } else {
                Text("登录后即可购买,已购内容跨设备同步")
                    .font(.caption)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .multilineTextAlignment(.center)
            }
            AppleSignInButton(onResult: { result in
                env.accountManager.handleAuthorization(result)
            })
            GoogleSignInButton {
                env.accountManager.handleGoogleSignIn()
            }
        }
    }
}

// MARK: - B 章回分段私有组件(2026-09-05 design-shotgun 定稿 variant-b)

/// 契约 stepper:壹 观其价 → 贰 钤印 → 叁 成契。
/// 壹 在 sheet 打开时即完成(价格未登录即见 = D1 拍板的核心);当前步 inkDeep
/// 实底圆,完成实线圆,未来虚线圆——与 NumeralBadge 实/虚线圆同一视觉语言。
private struct ContractStepper: View {
    let step: PaywallContractStep
    let isExchanging: Bool
    let isPurchased: Bool

    private enum ItemState { case done, current, future }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            item(state: .done, numeral: "壹", label: "观其价", sub: "价格已可见")
            connector(active: true)
            item(
                state: step == .dealing ? .done : .current,
                numeral: "贰",
                label: "钤印",
                sub: isExchanging ? "钤印中…" : "登录为凭"
            )
            connector(active: step == .dealing)
            item(
                state: step == .dealing ? (isPurchased ? .done : .current) : .future,
                numeral: "叁",
                label: "成契",
                sub: isPurchased ? "契成" : "一次买断"
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityProgressText)
    }

    /// 读屏进度文案(与可视子题同语义:壹 已完成 + 当前步子态)。
    private var accessibilityProgressText: String {
        if step == .dealing {
            return isPurchased ? "购买进度:已成契,内容已解锁" : "购买进度:第叁步,成契,待购买"
        }
        return isExchanging ? "购买进度:第贰步,钤印中" : "购买进度:第贰步,钤印,待登录"
    }

    private func item(state: ItemState, numeral: String, label: String, sub: String) -> some View {
        VStack(spacing: 5) {
            ZStack {
                switch state {
                case .current:
                    Circle().fill(BaziTheme.inkDeep)
                case .done:
                    Circle().stroke(BaziTheme.ink.opacity(0.4), lineWidth: 1)
                case .future:
                    Circle().stroke(
                        BaziTheme.hairlineDashed,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                }
                Text(numeral)
                    .font(BaziFont.display(size: 11, weight: .medium))
                    .foregroundStyle(textColor(for: state))
            }
            .frame(width: 25, height: 25)
            Text(label)
                .font(BaziFont.caption(size: 10.5))
                .tracking(2)
                .foregroundStyle(state == .future ? BaziTheme.inkMutedSecondary : BaziTheme.ink)
            Text(sub)
                .font(BaziFont.caption(size: 9))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
        }
        .frame(width: 88)
    }

    private func textColor(for state: ItemState) -> Color {
        switch state {
        case .current: return BaziTheme.onInkDeep
        case .done: return BaziTheme.ink
        case .future: return BaziTheme.inkMutedSecondary
        }
    }

    /// 步骤间连线(线高撑到圆心;已完成段加深)。
    private func connector(active: Bool) -> some View {
        Rectangle()
            .fill(active ? BaziTheme.ink.opacity(0.5) : BaziTheme.hairline)
            .frame(height: 0.5)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .frame(height: 25)
    }
}

/// 落价块:合同式大写数字(壹佰贰拾捌圆整)+ 本地化数字并置,上下 hairline 收束。
/// upperPrice == nil(角分价/千分位/越界/en 区)只显数字,不造假大写。
private struct PricePlate: View {
    let upperPrice: String?
    let rawPrice: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VText(phrase: "落价", size: 9.5, tracking: 3, color: BaziTheme.inkMutedSecondary)
            if let upperPrice {
                Text(upperPrice)
                    .font(BaziFont.display(size: 21, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                Text(rawPrice)
                    .font(BaziFont.numeric(size: 15, weight: .medium))
                    .foregroundStyle(BaziTheme.ink)
                Text("买断制 · 不含订阅")
                    .font(BaziFont.caption(size: 9.5))
                    .foregroundStyle(BaziTheme.inkMuted)
            }
        }
        .padding(.vertical, BaziTheme.Spacing.cmd)
        .overlay(alignment: .top) {
            Rectangle().fill(BaziTheme.hairline).frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(BaziTheme.hairline).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("价格 \(rawPrice),买断制,不含订阅")
    }
}

/// 操作区步骤标题行(「第贰步 · 钤印为凭」/「第叁步 · 成契」),顶 hairline 分段。
private struct StepTitleRow: View {
    let stepNo: String
    let title: String
    let hint: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(stepNo)
                .font(BaziFont.caption(size: 10))
                .tracking(2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
            Text(title)
                .font(BaziFont.display(size: 13.5, weight: .medium))
                .tracking(2)
                .foregroundStyle(BaziTheme.ink)
            Spacer(minLength: 6)
            Text(hint)
                .font(BaziFont.caption(size: 9.5))
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.top, BaziTheme.Spacing.sm)
        .overlay(alignment: .top) {
            Rectangle().fill(BaziTheme.hairline).frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 三墨点 breathe(钤印进行中;DESIGN 动效三式 breathe 的加载变奏——墨的呼吸,不是转圈)。
private struct SealingDots: View {
    var body: some View {
        HStack(spacing: 9) {
            ForEach(0..<3, id: \.self) { index in
                BreathingDot(delay: Double(index) * 0.4)
            }
        }
        .frame(maxWidth: .infinity)
        // 「钤印中 · 正在完成登录…」文案已承载语义,墨点纯装饰不进读屏
        .accessibilityHidden(true)
    }
}

private struct BreathingDot: View {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(BaziTheme.inkDeep)
            .frame(width: 6, height: 6)
            .opacity(dimmed ? 0.25 : 1)
            // reduce-motion 全降级(DESIGN.md 动效三式强制项):静态墨点,不驱动呼吸
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever().delay(delay),
                value: dimmed
            )
            .onAppear {
                guard !reduceMotion else { return }
                dimmed = true
            }
    }
}

// MARK: - S07 时辰未知拦截态组件(付费墙 / 深度解析整拦页 / 合盘对卡 / 每日运势整拦页共用)

/// 水墨克制拦截表达(DESIGN.md:一句话 + 入口,无红色警示)。
///
/// 四处复用,文案由调用方按场景传入(`L10n.PaywallGate`):
/// - `PaywallView` 拦截态(无时辰·日柱确定 → 付费墙位置)
/// - `DeepAnalysisView` 日柱歧义整拦页(免费 2 章亦拦,不进内容页)
/// - `CompatibilityPairListView` 对级拦截卡(任一方无时辰 → 整对拦,免费亦拦)
/// - `DailyFortuneView` 日柱歧义整拦页(S09)
///
/// S10:`onAddHour` 接线补时辰 sheet(D7);`silenced` = 「我确实不知道」静默态,
/// 文案切换中性版(不再主动提示,入口保留可点击)。
struct HourUnknownGateNotice: View {
    let title: String
    let reason: String
    /// S10 静默态(D7 第 4 条):标题/为什么/CTA 切中性文案(通用一组,不分场景)。
    var silenced: Bool = false
    /// S10 接线:CTA 打开补时辰 sheet。nil = 无宿主注入(测试渲染)→ CTA 不渲染
    /// (不可完成动作不展示按钮)。
    var onAddHour: (() -> Void)? = nil

    private var effectiveTitle: String {
        silenced ? L10n.PaywallGate.silentTitle : title
    }

    private var effectiveReason: String {
        silenced ? L10n.PaywallGate.silentReason : reason
    }

    private var effectiveCTA: String {
        silenced ? L10n.PaywallGate.silentCta : L10n.PaywallGate.cta
    }

    var body: some View {
        VStack(spacing: BaziTheme.Spacing.md) {
            // 「时」印:缺的不是钱,是时辰(朱印仅印章级小元素,符合 DESIGN.md 约束)
            SealStamp(character: "时", size: 34, rotation: -4, stampDelay: 0.2)
            Text(effectiveTitle)
                .font(BaziFont.display(size: 17))
                .tracking(2)
                .foregroundStyle(BaziTheme.ink)
                .multilineTextAlignment(.center)
            Text(effectiveReason)
                .font(BaziFont.caption(size: 11.5))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
                .multilineTextAlignment(.center)

            // CTA(S10 已接线):capsule hairline chip 形态(引导不是强卖,不做实底 CTA)
            if let onAddHour {
                Button {
                    HapticEngine.light()
                    onAddHour()
                } label: {
                    Text(effectiveCTA)
                        .font(.caption.weight(.semibold))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, BaziTheme.Spacing.md)
    }
}
