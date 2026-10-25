import SwiftUI

// MARK: - S4 问事窗(2026-10-25,docs/design-ref/today-type/今日问事.html 用户已认可)

/// 今日页底部两级问事交互:
/// ① **问事框**(DailyAskComposerCard):今日页滚到最底才从 tab 栏上方滑出,
///    收在顶部不可见——「运势读完」与「可以问事」是同一时刻(出现时机 =
///    `DailyAskPresentation` 纯函数,宿主 DailyFortuneMainView 注入滚动探针);
/// ② **聊天页**(DailyAskChatView):点问事框向上拉起独立整页(无 tab 栏),
///    开场不空白——登录后第一条消息已在 = AI 开场白 + 候选问题,点候选直接
///    作为用户消息发出。
///
/// 候选问题数据链(S2 已备):daily prompt v6 `ask_suggestions` →
/// `DailyInsight.askSuggestions` → 缺键/降级态回落 `EngineReadingTemplates`
/// 确定性三表(与本页宜忌词条/解读降级同哲学:AI 缺的由引擎产物补,不跳形态)。
///
/// **作答端点后置**(S4b,本片只落 UI):`DailyAskAnswering` 是接缝,当前唯一
/// 实现 `ServicePendingAskAnswerer` 诚实告知「作答服务接入中」——不伪造 AI
/// 回答(演示 HTML 的手写回复是看效果用的,不进 App);端点上线换实现即可,
/// 届时链路 = 命盘 + 今日运势上下文 + context_token 验签(守护栏见 CLAUDE.md)。

// MARK: 出现时机(纯逻辑,DailyAskTests 锁定)

/// 问事框可见性判定:距底剩余滚动距离 < 64pt 且聊天页未开(HTML onScroll
/// 同款单一阈值,px≈pt 1:1;内容不满屏时剩余为负同样算「在底部」)。
/// 聊天页打开期间强制不可见,关闭后在底部则重新滑出(HTML closeSheet →
/// onScroll 重算语义)。
enum DailyAskPresentation {
    /// 距底阈值(今日问事.html atBottom < 64px)。
    static let bottomThreshold: CGFloat = 64

    static func composerVisible(remainingToBottom: CGFloat, isChatPresented: Bool) -> Bool {
        remainingToBottom < bottomThreshold && !isChatPresented
    }
}

// MARK: 作答服务(接缝)

/// 问事作答服务。真实实现(S4b)= 后端问答端点 + context_token;协议先立,
/// UI/模型这侧不感知网络细节。
protocol DailyAskAnswering: Sendable {
    func reply(to question: String) async throws -> String
}

/// 当前实现:作答端点未上线——返回诚实告知文案,不冒充 AI 回答。
struct ServicePendingAskAnswerer: DailyAskAnswering {
    func reply(to question: String) async throws -> String {
        L10n.DailyFortune.askPendingReply
    }
}

// MARK: 模型

/// 问事对话模型:开场消息 + 候选问题 + 消息流。宿主 DailyFortuneMainView
/// 持有(@State),换日/换盘重建(对话随旧盘走),用户开口后(pristine 之外)
/// 不再因解读态变化被重置。
@MainActor
final class DailyAskModel: ObservableObject {
    enum Role {
        case ai
        case user
    }

    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        let text: String
    }

    /// 消息流(首条恒为 AI 开场白)。
    @Published private(set) var messages: [Message]
    /// 剩余候选问题(首发即收——HTML offers 用过即删,不占对话流)。
    @Published private(set) var offers: [String]
    /// 输入框草稿(空白/作答中发送为 no-op,草稿保留不误清)。
    @Published var draft: String = ""
    /// 作答在飞(HTML busy 守卫:在飞期间新发送一律忽略)。
    @Published private(set) var isAnswering = false

    /// sheet 副题「辛未日 · 比肩」。
    let contextLine: String
    /// 问事框引导句「比肩当值的一天。你的事,挑一条来问——」。
    let composerLine: String
    /// 问事框 chip(候选前两条)。
    let composerChips: [String]

    private let answerer: DailyAskAnswering

    init(
        opening: String,
        offers: [String],
        composerLine: String,
        contextLine: String,
        answerer: DailyAskAnswering = ServicePendingAskAnswerer()
    ) {
        self.messages = [.init(role: .ai, text: opening)]
        self.offers = offers
        self.composerLine = composerLine
        self.composerChips = Array(offers.prefix(2))
        self.contextLine = contextLine
        self.answerer = answerer
    }

    // MARK: 发送

    /// 点候选问题直接发出(问事框 chip 与聊天页 offers 同源同路)。
    func sendOffer(_ question: String) {
        send(question)
    }

    /// 输入框发送:空白/作答中 no-op;成功发出才清草稿(作答中被拦时
    /// 草稿保留,不误删用户输入)。
    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
        draft = ""
        send(text)
    }

    private func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
        offers = []
        messages.append(.init(role: .user, text: text))
        isAnswering = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.answerer.reply(to: text)
                self.messages.append(.init(role: .ai, text: reply))
            } catch {
                // 错误显式传播:原始 error 进日志,对话流里给可见的失败气泡
                // (不吞、不用「作答服务接入中」冒充失败语义——两码事)。
                // question 是用户私事自由文本,不标 .public——os_log 默认
                // .private 脱敏,对齐全仓「.public 只放运维元数据」口径。
                AppLogger.app.error(
                    "op=dailyAsk.reply failed question=\(String(text.prefix(40))) error=\(String(describing: error), privacy: .public)"
                )
                self.messages.append(.init(role: .ai, text: L10n.DailyFortune.askReplyFailed))
            }
            self.isAnswering = false
        }
    }

    /// 用户是否尚未开口(仅开场白、无作答在飞)——宿主据此判断解读态
    /// 变化时可否安全重建(开口后重建会丢对话)。
    var isPristine: Bool {
        messages.count <= 1 && !isAnswering
    }
}

// MARK: 工厂(从今日页数据组装)

extension DailyAskModel {

    /// 组装:候选 = v6 ask_suggestions 优先,缺键/解读未成 → 确定性候选表;
    /// 开场白/引导句引用当日盘面(十神 + 宜忌词条 + 日柱),词条与屏上
    /// 宜忌双列同源(HeroYiJiColumns 词表)——开场白说的就是屏上那两列。
    static func make(
        response: DailyFortuneResponse,
        interpretState: InterpretState,
        answerer: DailyAskAnswering = ServicePendingAskAnswerer()
    ) -> DailyAskModel {
        let relation = response.dayRelationToDayMaster
        let suggestions: [String]? = {
            switch interpretState {
            case .okFree(let text, _), .okPaid(let text, _):
                // 解析失败(v4 畸形)→ nil 走确定性表,与解读区降级同路
                return DailyInsight.parse(text)?.askSuggestions
            case .offlineLegacy(let text, _):
                // v3 散文快照 parse nil → nil 同样走确定性表
                return DailyInsight.parse(text)?.askSuggestions
            case .idle, .fetching, .failed, .lockedPaid, .dailyLimitReached, .contextTokenExpired:
                // 解读未成/不可用:确定性表兜底。穷举显式列出(对齐
                // DailyInterpretationSection 的 switch 纪律)——未来新增带
                // 正文的 case 在这里编译期暴露,而不是静默漏进兜底。
                return nil
            }
        }()
        let offers = suggestions ?? EngineReadingTemplates.suggestions(for: relation)

        // 十神显示名走 BaziTerms 统一查表(同 chips 行 displayRelation 口径,
        // 该 helper 是 hero 私有;未知关系显式回落原值 + 日志)
        let relationDisplay = BaziTerms.display(relation)

        // 宜忌词条与屏上同源:词表查 miss 记日志 + fallback(对齐
        // HeroYiJiColumns.pair,不静默)。
        let pair: (yi: [String], ji: [String])
        if let hit = HeroYiJiColumns.mapping[relation] {
            pair = hit
        } else {
            AppLogger.app.warning(
                "op=dailyAsk.yijiLookupMiss day_relation=\(relation, privacy: .public) -> fallback"
            )
            pair = HeroYiJiColumns.fallback
        }
        let joiner = AppLanguage.current.isChinese ? "、" : ", "
        let yi = pair.yi.prefix(2).joined(separator: joiner)
        let ji = pair.ji.prefix(2).joined(separator: joiner)

        return DailyAskModel(
            opening: L10n.DailyFortune.askOpening(relation: relationDisplay, yi: yi, ji: ji),
            offers: offers,
            composerLine: L10n.DailyFortune.askComposerLine(relation: relationDisplay),
            contextLine: contextLine(dayPillar: response.dayPillar, relationDisplay: relationDisplay),
            answerer: answerer
        )
    }

    /// sheet 副题:zh 族「辛未日 · 比肩」;EN 零汉字纪律 → 日柱拼音
    /// (romanizedHyphen 同 enLunarLine 口径),查表 miss 回落原柱(记日志,
    /// 宁可露汉字不猜,对齐 hero lunarLine 先例的 parseMiss 日志)。
    static func contextLine(dayPillar: String, relationDisplay: String) -> String {
        if AppLanguage.current == .en {
            if let pinyin = BaziTerms.romanizedHyphen(dayPillar) {
                return "\(pinyin) day · \(relationDisplay)"
            }
            AppLogger.app.warning(
                "op=dailyAsk.pillarRomanizeMiss day_pillar=\(dayPillar, privacy: .public) -> rawFallback"
            )
        }
        return "\(dayPillar)\(L10n.DailyFortune.dayPillarSuffix) · \(relationDisplay)"
    }
}

// MARK: ① 问事框(滚到底滑出,tab 栏上方)

/// 问事框卡片:整卡可点开聊天页;chip 是嵌套 Button(内层优先接管命中,
/// 点击 = 开聊天页 + 直接发出该候选)。视觉对齐今日问事.html composer:
/// cardSurface 底 + hairline 描边 + 轻投影(ChainDoneToast 同款浮层语言,
/// 非 material——App 浮层惯用法一致优先于 HTML 的半透明模糊)。
/// radius 20 为设计稿定值(超出 BaziTheme.Radius 层级,HTML 认可稿)。
struct DailyAskComposerCard: View {
    let model: DailyAskModel
    let onOpen: () -> Void
    let onQuickAsk: (String) -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                head
                Text(verbatim: model.composerLine)
                    .font(BaziFont.body(size: 16))
                    .foregroundStyle(BaziTheme.ink)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                chips
                foot
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(BaziTheme.cardSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(BaziTheme.hairline, lineWidth: 0.5)
            )
            .shadow(color: BaziTheme.ink.opacity(0.10), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.DailyFortune.askComposerA11y)
    }

    /// 头行:墨青圆点 + 状态签(HTML cp-head,圆点即「已看好」的灯)。
    private var head: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(BaziTheme.jade)
                .frame(width: 7, height: 7)
            Text(L10n.DailyFortune.askHeadStatus)
                .font(.system(size: 11))
                .tracking(1.4)
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .padding(.bottom, 9)
    }

    /// 候选 chip 行:取前两条;EN 长文案放不下时上下堆叠(对齐头部 chips 行
    /// 的 ViewThatFits 手法,HStack 永不换行)。
    @ViewBuilder
    private var chips: some View {
        let items = model.composerChips
        Group {
            if !items.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, q in
                            chip(q)
                        }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, q in
                            chip(q)
                        }
                    }
                }
                .padding(.top, 11)
            }
        }
    }

    private func chip(_ question: String) -> some View {
        Button {
            onQuickAsk(question)
        } label: {
            Text(verbatim: question)
                .font(.system(size: 12))
                .foregroundStyle(BaziTheme.ink)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    /// 脚行:右对齐「展开对话 ›」。
    private var foot: some View {
        HStack {
            Spacer(minLength: 0)
            Text(L10n.DailyFortune.askComposerFoot)
                .font(.system(size: 10.5))
                .tracking(1.2)
                .foregroundStyle(BaziTheme.inkMuted)
        }
        .padding(.top, 10)
    }
}

// MARK: ② 聊天页(fullScreenCover 整页,无 tab 栏)

/// 问事聊天页:顶栏(问事 + 盘面副题 + ✕)+ 消息流 + 候选问题 + 输入栏。
/// 作答在飞显示三点输入指示;新消息自动滚到底(短对话 plain VStack,
/// scrollTo 惰性坑不涉及)。
struct DailyAskChatView: View {
    @ObservedObject var model: DailyAskModel
    let onClose: () -> Void

    /// AI 侧气泡形状(含 typing):尾角左下。HTML CSS `16px 16px 16px 4px`
    /// 顺序是 TL,TR,BR,BL → SwiftUI 元组须重排为 topLeading,
    /// bottomLeading, bottomTrailing, topTrailing(小角 = bottomLeading)。
    /// 收敛成常量:圆角手抄 5 份已实证会漂移(S4 review 修过一次互换)。
    private static let aiBubbleShape = UnevenRoundedRectangle(
        cornerRadii: .init(topLeading: 16, bottomLeading: 4, bottomTrailing: 16, topTrailing: 16),
        style: .continuous
    )

    /// 用户侧气泡形状:尾角右下(HTML `16px 16px 4px 16px`,BR=4 →
    /// bottomTrailing)。
    private static let userBubbleShape = UnevenRoundedRectangle(
        cornerRadii: .init(topLeading: 16, bottomLeading: 16, bottomTrailing: 4, topTrailing: 16),
        style: .continuous
    )

    var body: some View {
        ZStack {
            BaziTheme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(model.messages) { message in
                                bubble(message)
                                    .id(message.id)
                            }
                            if !model.offers.isEmpty {
                                offerList
                            }
                            if model.isAnswering {
                                typingBubble
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 12)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: model.messages.count) { _, _ in
                        if let last = model.messages.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
                inputBar
            }
        }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L10n.DailyFortune.askTitle)
                .font(BaziFont.display(size: 17, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(BaziTheme.ink)
            Text(verbatim: model.contextLine)
                .font(.system(size: 11))
                .tracking(1)
                .foregroundStyle(BaziTheme.inkMuted)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(BaziTheme.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.DailyFortune.askCloseA11y)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)
        }
    }

    // MARK: 消息气泡

    @ViewBuilder
    private func bubble(_ message: DailyAskModel.Message) -> some View {
        switch message.role {
        case .ai:
            // AI 气泡:左对齐、cardSurface 底、尾角左下(形状见 aiBubbleShape)。
            // Spacer minLength 64 = HTML max-width 78% 的定宽通道近似
            // (375pt 屏 ≈ 83%,短消息不受影响由 Spacer 吃余量,真机走查校)。
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.DailyFortune.askTitle)
                        .font(.system(size: 10))
                        .tracking(1.4)
                        .foregroundStyle(BaziTheme.inkMuted)
                    Text(verbatim: message.text)
                        .font(BaziFont.body(size: 16))
                        .foregroundStyle(BaziTheme.ink)
                        .lineSpacing(7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Self.aiBubbleShape.fill(BaziTheme.cardSurface))
                .overlay(Self.aiBubbleShape.stroke(BaziTheme.hairline, lineWidth: 0.5))
                Spacer(minLength: 64)
            }
        case .user:
            // 用户气泡:右对齐、焦墨底、尾角右下(形状见 userBubbleShape;
            // 对面通道同 64,与 AI 对称)。
            HStack {
                Spacer(minLength: 64)
                Text(verbatim: message.text)
                    .font(BaziFont.body(size: 16))
                    .foregroundStyle(BaziTheme.onInkDeep)
                    .lineSpacing(7)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Self.userBubbleShape.fill(BaziTheme.inkDeep))
            }
        }
    }

    /// 作答在飞:AI 侧三点输入指示气泡(尾角同 AI 气泡左下)。对
    /// VoiceOver 显式自报「正在作答」——纯装饰三点不标注则 VO 用户
    /// 发送后到回复出现前无任何状态反馈(页内其余元素均有 a11y 标签)。
    private var typingBubble: some View {
        HStack {
            AskTypingDots()
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.DailyFortune.askTypingA11y)
                .background(Self.aiBubbleShape.fill(BaziTheme.cardSurface))
                .overlay(Self.aiBubbleShape.stroke(BaziTheme.hairline, lineWidth: 0.5))
            Spacer(minLength: 0)
        }
    }

    // MARK: 候选问题(开场携带,点选直发)

    private var offerList: some View {
        VStack(spacing: 8) {
            ForEach(Array(model.offers.enumerated()), id: \.offset) { _, question in
                Button {
                    model.sendOffer(question)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "›")
                            .font(.system(size: 12))
                            .foregroundStyle(BaziTheme.inkMuted)
                        Text(verbatim: question)
                            .font(BaziFont.body(size: 15.5))
                            .foregroundStyle(BaziTheme.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(BaziTheme.hairline, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 输入栏

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(
                L10n.DailyFortune.askInputPlaceholder,
                text: $model.draft
            )
            .font(BaziFont.body(size: 15))
            .foregroundStyle(BaziTheme.ink)
            .submitLabel(.send)
            .onSubmit { model.sendDraft() }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .background(Capsule().fill(BaziTheme.cardSurface))
            .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))

            Button {
                model.sendDraft()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(BaziTheme.onInkDeep)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(BaziTheme.inkDeep))
            }
            .disabled(!canSend)
            .opacity(canSend ? 1 : 0.3)
            .accessibilityLabel(L10n.DailyFortune.askSendA11y)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(height: 0.5)
        }
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isAnswering
    }
}

// MARK: 三点输入指示

/// 作答在飞的三点指示:1s 周期、相位 0.18s 递进(HTML tp keyframes
/// 0.25→1→0.25 的形状近似);TimelineView 驱动无隐式动画状态,reduce-motion
/// 下暂停时间线回退为静态半透明三点了事(动效三式纪律:reduced 全降级)。
private struct AskTypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(BaziTheme.inkMuted)
                        .frame(width: 4, height: 4)
                        .opacity(reduceMotion ? 0.6 : Self.dotOpacity(t: t, index: index))
                }
            }
        }
    }

    /// 单点不透明度:sin(π·phase) 在 1s 周期内走 0.25→1→0.25 一整趟。
    static func dotOpacity(t: TimeInterval, index: Int) -> Double {
        let phase = (t + Double(index) * 0.18).truncatingRemainder(dividingBy: 1.0)
        return 0.25 + 0.75 * abs(sin(phase * .pi))
    }
}
