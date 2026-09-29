import SwiftUI

/// 购买弹窗(底部 sheet + grabber)。
///
/// M3c 决策(用户拍板):底部 sheet(默认 .medium)而非全屏
/// (避免与 OnboardingView 视觉重复)。2026-08-31 修 bug 加 .large:
/// 8 章清单 + 登录区理想高度 ~750pt,.medium(~392pt)装不下且无滚动,
/// 超高内容被 sheet 居中裁切(首章「壹」不可见);内容入 ScrollView
/// 顶部锚定 + .large 可拉满,彻底消灭裁切。
///
/// 2026-09-27 匿名购买重构(外部 review + 拍板):购买按钮常驻(登录不再是
/// 前置,App Store 审核风险 + 登录步流失)、补恢复购买入口(消耗型语义)、
/// 登录降级为可选绑定行(跨设备同步)、「落价」→「润金」、「日元」→「日主」、
/// 章节清单加静态预告行。旧 B 章回分段(stepper/钤印/成契)随登录中置设计移除。
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

    // MARK: - 账号绑定派生(2026-09-27 匿名购买:登录从购买前置降级为可选绑定)

    /// 账号绑定进行中(provider 登录成功、exchange 未完)——绑定行切「绑定中…」。
    private var isBindingInFlight: Bool {
        if case .signedIn = env.accountManager.state, env.accountManager.exchangeState == .inFlight {
            return true
        }
        return false
    }

    /// 正常付费墙内容(有时辰用户)。
    ///
    /// 2026-09-27 匿名购买重构:购买按钮**常驻**(登录不再是前置,App Store
    /// 审核风险 + 登录步流失);恢复购买补齐(消耗型语义,诚实文案);登录
    /// 降级为购买后的可选绑定行(跨设备同步是消耗型唯一的跨设备通道)。
    /// 旧 B 章回分段(壹观其价/贰钤印/叁成契)随「登录中置」设计一起移除。
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
                    Text(viewModel.module.freeChaptersHint)
                        .font(BaziFont.caption(size: 10.5))
                        .tracking(2)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, BaziTheme.Spacing.xs)

            // 润金块:合同式大写数字(防篡改语义,呼应大写数字品牌指纹)。
            // 大写存在时不再并显数字价(信息层级单一,数字价只在 CTA 按钮上);
            // 角分价/千分位/越界/en 区 → 无大写,只显本地化数字(不造假)。
            PricePlate(
                upperPrice: viewModel.chineseUpperPrice,
                rawPrice: viewModel.rawPriceText
            )

            // 章节清单:大写数字徽(锁定虚线圆)+ 章名 + 静态预告行
            // (2026-09-27 review:只有标题没信息量,¥128 价位需给价值密度)
            // + dashed hairline 分隔
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.module.paidChapters.enumerated()), id: \.element) { idx, chapter in
                    HStack(spacing: 12) {
                        NumeralBadge(index: idx + 1, locked: true, size: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(chapter)
                                .font(BaziFont.body(size: 14))
                                .foregroundStyle(BaziTheme.ink)
                            if idx < viewModel.module.chapterTeasers.count {
                                Text(viewModel.module.chapterTeasers[idx])
                                    .font(BaziFont.caption(size: 9.5))
                                    .foregroundStyle(BaziTheme.inkMutedSecondary)
                            }
                        }
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

            // CTA:常驻(登录与否都可买)。购买判据在 PurchaseManager 内部
            // (StoreKit 验签 + 后端 redeem),与登录态解耦。
            PrimaryCTAButton(
                title: viewModel.displayPriceText,
                loadingTitle: String(localized: "处理中…"),
                isLoading: viewModel.state == .purchasing,
                action: { Task { await viewModel.purchase() } }
            )

            // 恢复购买(App Store 惯例入口;消耗型语义:同机未完成交易 +
            // 登录态后端同步,匿名重装/换机诚实返回「未找到」)
            restoreSection

            // 绑定行(未登录才显示):登录动机一句话 = 跨设备同步(消耗型
            // 购买的唯一跨设备通道);已登录整行隐藏
            bindingSection

            // 法律免责(DESIGN.md 反 AI slop + 命理类审核要求)
            Text("玄学娱乐,理性参考。\n购买即视为同意 Apple 标准用户协议。")
                .font(.caption2)
                .foregroundStyle(BaziTheme.inkMutedSecondary)
                .multilineTextAlignment(.center)
                .tracking(1)
        }
    }

    /// 错误文案(购买失败;登录失败已收敛到 LoginGateButtons 并沿用同一规格):
    /// 10.5 caption + 凶色 + 居中——本 sheet 内两条错误路径字号/对齐一致。
    /// 颜色用 shenshaInauspicious(与 ProfileView 的 destructive 不同,
    /// 跟本 sheet 内既有购买失败文案保持一致)。
    private func errorCaption(_ message: String) -> some View {
        Text(message)
            .font(BaziFont.caption(size: 10.5))
            .foregroundStyle(BaziTheme.shenshaInauspicious)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - 恢复购买区

    /// 「恢复购买」ghost 按钮(capsule hairline chip,同 HourUnknownGateNotice
    /// CTA 形态——恢复是补救动作,不做实底 CTA)+ 状态反馈行。
    @ViewBuilder
    private var restoreSection: some View {
        VStack(spacing: BaziTheme.Spacing.sm) {
            Button {
                HapticEngine.light()
                Task { await viewModel.restore() }
            } label: {
                Text(viewModel.restoreState == .restoring ? String(localized: "恢复中…") : String(localized: "恢复购买"))
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
            }
            .disabled(viewModel.state == .purchasing || viewModel.restoreState == .restoring)

            // 状态反馈(完成后一行 caption;失败凶色,与本 sheet 错误文案同规格)
            switch viewModel.restoreState {
            case .restored:
                Text("已恢复购买")
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMuted)
            case .nothingFound:
                Text("未找到可恢复的购买")
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.inkMuted)
            case .failed(let message):
                Text(message)
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(BaziTheme.shenshaInauspicious)
                    .multilineTextAlignment(.center)
            case .idle, .restoring:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 绑定行(可选登录,购买后的跨设备同步通道)

    /// 绑定行:未登录显示(SIWA 入口 + 一句话动机);登录后绑定进度/失败重试;
    /// 完全绑定(.done)或启动恢复中(.loading)隐藏。
    @ViewBuilder
    private var bindingSection: some View {
        switch env.accountManager.state {
        case .signedIn:
            // provider 登录成功、exchange 未完:绑定进度(三墨点 breathe)
            switch env.accountManager.exchangeState {
            case .inFlight:
                VStack(spacing: BaziTheme.Spacing.sm) {
                    bindingCaption
                    VStack(spacing: BaziTheme.Spacing.sm) {
                        SealingDots()
                        Text("绑定中 · 正在完成登录…")
                            .font(.caption)
                            .foregroundStyle(BaziTheme.inkMuted)
                    }
                    .frame(maxWidth: .infinity)
                    // 与 AppleSignInButton 同高,绑定区切换时 sheet 布局不跳
                    .frame(height: 50)
                }
            case .failed(let message):
                // exchange 失败:显错 + 重新登录重试(SIWA 已授权过,重登通常无感)
                VStack(spacing: BaziTheme.Spacing.sm) {
                    bindingCaption
                    LoginGateButtons(
                        errorMessage: message,
                        errorColor: BaziTheme.shenshaInauspicious
                    )
                }
            case .idle, .done:
                // done=已绑定(隐藏);idle=防御分支(signedIn 但 exchange 未定义,
                // 不变量破坏,同样隐藏——购买不依赖登录,不阻塞主流程)
                EmptyView()
            }
        case .signedOut:
            // 未登录:可选绑定入口(登录失败显错由 LoginGateButtons 承载)
            VStack(spacing: BaziTheme.Spacing.sm) {
                bindingCaption
                LoginGateButtons()
            }
        case .failed(let message):
            // 登录失败(Fix#1:不吞,显错 + 保留重试按钮)
            VStack(spacing: BaziTheme.Spacing.sm) {
                bindingCaption
                LoginGateButtons(
                    errorMessage: message,
                    errorColor: BaziTheme.shenshaInauspicious
                )
            }
        case .loading:
            // 启动 Keychain 恢复中:未知登录态,不闪绑定行
            EmptyView()
        }
    }

    /// 绑定行动机一句话:消耗型购买的跨设备恢复只能靠账号(Apple 不恢复消耗型)。
    private var bindingCaption: some View {
        Text("绑定账号 · 已购内容跨设备同步")
            .font(.caption)
            .foregroundStyle(BaziTheme.inkMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - 润金块(PricePlate 为 internal:快照走查直接渲染有无大写两种形态)

/// 润金块:合同式大写数字(壹佰贰拾捌圆整)为主视觉,上下 hairline 收束。
/// 「润金」= 命理行业收费古称(2026-09-27 替换「落价」——该词有降价歧义)。
///
/// 大写存在时**不再并显数字价**(信息层级单一,数字价只出现在 CTA 按钮上);
/// upperPrice == nil(角分价/千分位/越界/en 区)降级显本地化数字,不造假大写。
struct PricePlate: View {
    let upperPrice: String?
    let rawPrice: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VText(phrase: String(localized: "润金"), size: 9.5, tracking: 3, color: BaziTheme.inkMutedSecondary)
            if let upperPrice {
                Text(upperPrice)
                    .font(BaziFont.display(size: 21, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            } else {
                Text(rawPrice)
                    .font(BaziFont.numeric(size: 19, weight: .medium))
                    .foregroundStyle(BaziTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Spacer(minLength: 8)
            Text("买断制 · 不含订阅")
                .font(BaziFont.caption(size: 9.5))
                .foregroundStyle(BaziTheme.inkMuted)
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

/// 三墨点 breathe(绑定进行中;DESIGN 动效三式 breathe 的加载变奏——墨的呼吸,不是转圈)。
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
/// - `PairSummaryCard` 对级拦截卡(任一方无时辰 → 整对拦,免费亦拦)
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
