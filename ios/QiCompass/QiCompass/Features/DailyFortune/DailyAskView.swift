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
/// **作答链路**(S4c 已接):`LiveDailyAskAnswerer` 真调 `POST /api/bazi/daily-ask`
/// (上下文快照 DailyAskContext 由宿主 syncAskModel 组装,含 daily 族
/// context_token);`ServicePendingAskAnswerer` 保留为降级实现——上下文不可
/// 组装(离线兜底缺 chartPayload/token)时诚实告知,不伪造 AI 回答。
/// 作答返回的 `follow_up_suggestions` 复用 offers chip 通道点选直发;
/// 402 ASK_CREDITS_REQUIRED → 聊天流内嵌购买卡片(拍板:不自动弹墙)。

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

/// 问事作答服务。真实现 = `LiveDailyAskAnswerer`(后端问答端点 +
/// context_token);UI/模型这侧不感知网络细节。
protocol DailyAskAnswering: Sendable {
    /// - Parameter history: 对话上文(模型层已截 ≤20 轮;answerer 纵深再截)
    /// - Returns: DailyAskReply(正文 + 追问候选 + cached + 服务端余额)
    func reply(to question: String, history: [DailyAskTurn]) async throws -> DailyAskReply
}

/// 降级实现:上下文不可组装(离线兜底缺 chartPayload/token)——返回诚实
/// 告知文案,不冒充 AI 回答(演示 HTML 的手写回复是看效果用的,不进 App)。
struct ServicePendingAskAnswerer: DailyAskAnswering {
    func reply(to question: String, history: [DailyAskTurn]) async throws -> DailyAskReply {
        DailyAskReply(text: L10n.DailyFortune.askPendingReply, followUps: [], cached: false, balance: nil)
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
    /// 次数已用尽(402 ASK_CREDITS_REQUIRED 或本地余额 0 短路):聊天流
    /// 内嵌购买卡片;购买成功(余额 >0)由聊天页 onChange 复位。
    @Published private(set) var creditsExhausted = false

    /// sheet 副题「辛未日 · 比肩」。
    let contextLine: String
    /// 问事框引导句「比肩当值的一天。你的事,挑一条来问——」。
    let composerLine: String
    /// 问事框 chip(候选前两条)。
    let composerChips: [String]

    private let answerer: DailyAskAnswering
    /// 问事钱包(AppEnvironment 强持有,weak 防环;nil = 测试无钱包注入)
    weak var wallet: AskWalletModel?

    init(
        opening: String,
        offers: [String],
        composerLine: String,
        contextLine: String,
        answerer: DailyAskAnswering = ServicePendingAskAnswerer(),
        wallet: AskWalletModel? = nil
    ) {
        self.messages = [.init(role: .ai, text: opening)]
        self.offers = offers
        self.composerLine = composerLine
        self.composerChips = Array(offers.prefix(2))
        self.contextLine = contextLine
        self.answerer = answerer
        self.wallet = wallet
    }

    // MARK: 发送

    /// 点候选问题直接发出(问事框 chip 与聊天页 offers 同源同路)。
    func sendOffer(_ question: String) {
        _ = send(question)
    }

    /// 输入框发送:空白/作答中 no-op;成功过闸才清草稿(被闸拦时草稿
    /// 保留,不误删用户输入——次数尽被拦时文字还在框里,买完可直接再发)。
    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
        guard send(text) else { return }
        draft = ""
    }

    /// 发送(含三道闸)。返回 false = 未出网(消息未入流),sendDraft
    /// 据此保草稿;返回 true = 已出网(用户消息已入流,等作答)。
    private func send(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return false }
        // 本地 0 余额短路:不出网(必 402 的往返没有意义),置购买卡片态;
        // 消息不入流——问题还没被回答,买完原话还在草稿/候选里可再发
        if wallet?.balance == 0 {
            creditsExhausted = true
            return false
        }
        offers = []
        // 对话上文:排除开场白(它不是对话回合),截末 20 轮(服务端整单
        // >20 轮 422,只注入末 6 轮——客户端保末 20 给模型足量记忆)
        let history = messages.dropFirst().suffix(20).map { message in
            DailyAskTurn(role: message.role == .user ? "user" : "ai", text: message.text)
        }
        messages.append(.init(role: .user, text: text))
        isAnswering = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.answerer.reply(to: text, history: history)
                self.messages.append(.init(role: .ai, text: reply.text))
                // 追问候选复用 offers 通道(点选直发;发起下一条时用过即收)
                self.offers = reply.followUps
                if let balance = reply.balance {
                    self.wallet?.apply(balance)
                }
            } catch {
                // 错误显式传播 + 分型(2026-10-26 拍板:402 = 内嵌购买卡片,
                // 不自动弹墙;context_token 过期 = 引导回今日页刷新;其余 =
                // 通用失败气泡)。question 是用户私事自由文本,不标 .public
                // ——os_log 默认 .private 脱敏,对齐全仓口径。
                AppLogger.app.error(
                    "op=dailyAsk.reply failed question=\(String(text.prefix(40))) error=\(String(describing: error), privacy: .public)"
                )
                if APIError.isAskCreditsRequired(error) {
                    // 用户消息保留(已发出),无失败气泡——卡片就是回应
                    self.creditsExhausted = true
                    self.wallet?.apply(0)
                } else if APIError.isContextTokenError(error) {
                    self.messages.append(.init(role: .ai, text: L10n.DailyFortune.askReplyContextExpired))
                } else {
                    self.messages.append(.init(role: .ai, text: L10n.DailyFortune.askReplyFailed))
                }
            }
            self.isAnswering = false
        }
        return true
    }

    /// 用户是否尚未开口(仅开场白、无作答在飞)——宿主据此判断解读态
    /// 变化时可否安全重建(开口后重建会丢对话)。
    var isPristine: Bool {
        messages.count <= 1 && !isAnswering
    }

    /// 购买成功(余额 >0)后由聊天页调用:收起购买卡片,对话可继续
    /// (外部主动复位而非模型自监听——模型不持有 wallet 的强引用,
    /// 避免ObservableObject 双向耦合)。
    func resetCreditsExhausted() {
        creditsExhausted = false
    }
}

// MARK: 工厂(从今日页数据组装)

extension DailyAskModel {

    /// 组装:候选 = v6 ask_suggestions 优先,缺键/解读未成 → 确定性候选表;
    /// 开场白/引导句引用当日盘面(十神 + 宜忌词条 + 日柱),词条与屏上
    /// 宜忌双列同源(HeroYiJiColumns 词表)——开场白说的就是屏上那两列。
    /// answerer 由宿主 syncAskModel 构造传入(上下文齐备 → Live,缺 →
    /// ServicePending 降级);make 保持静态纯组装,不触碰网络与快照。
    static func make(
        response: DailyFortuneResponse,
        interpretState: InterpretState,
        answerer: DailyAskAnswering = ServicePendingAskAnswerer(),
        wallet: AskWalletModel? = nil
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
            answerer: answerer,
            wallet: wallet
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
///
/// S4c 余额形态(拍板:问事框 + 聊天页双处显示):head 行尾「剩余 N 问」;
/// balance == 0 整卡切换加购形态(次数用完,点卡 = 弹购买墙,不进聊天)。
struct DailyAskComposerCard: View {
    let model: DailyAskModel
    @ObservedObject var wallet: AskWalletModel
    let onOpen: () -> Void
    let onQuickAsk: (String) -> Void
    /// 0 次加购形态点卡入口(S4c:弹次数包购买墙;C3 换真墙)
    let onBuyPack: () -> Void

    var body: some View {
        Button(action: wallet.balance == 0 ? onBuyPack : onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                if wallet.balance == 0 {
                    exhaustedBody
                } else {
                    normalBody
                }
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
        .accessibilityLabel(
            wallet.balance == 0 ? L10n.DailyFortune.askBuyEntryCta : L10n.DailyFortune.askComposerA11y
        )
    }

    /// 正常形态:状态行(含余额签)+ 引导句 + 候选 chip + 展开脚注。
    private var normalBody: some View {
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
    }

    /// 0 次加购形态:标题 + CTA chip(chips/引导句/脚注让位——次数尽时
    /// 唯一有意义的事是加购,保留卡片位不换形态会引导用户进死胡同)。
    private var exhaustedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            Text(L10n.DailyFortune.askCreditsTitle)
                .font(BaziFont.body(size: 16))
                .foregroundStyle(BaziTheme.ink)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 11)
            Text(L10n.DailyFortune.askBuyEntryCta)
                .font(.system(size: 12, weight: .medium))
                .tracking(1)
                .foregroundStyle(BaziTheme.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
        }
    }

    /// 头行:墨青圆点 + 状态签(HTML cp-head,圆点即「已看好」的灯)
    /// + 尾部余额签(拍板:问事框显示剩余次数;nil = 未查询不显示)。
    private var head: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(BaziTheme.jade)
                .frame(width: 7, height: 7)
            Text(L10n.DailyFortune.askHeadStatus)
                .font(.system(size: 11))
                .tracking(1.4)
                .foregroundStyle(BaziTheme.inkMuted)
            Spacer(minLength: 8)
            if let balance = wallet.balance, balance > 0 {
                Text(L10n.DailyFortune.askBalanceRemaining(balance))
                    .font(.system(size: 11))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
            }
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

/// 问事聊天页:顶栏(问事 + 盘面副题 + 余额副题 + ✕)+ 消息流 + 候选
/// 问题 + 次数尽内嵌购买卡 + 输入栏。作答在飞显示三点输入指示;新消息
/// 自动滚到底(短对话 plain VStack,scrollTo 惰性坑不涉及)。
struct DailyAskChatView: View {
    @ObservedObject var model: DailyAskModel
    @ObservedObject var wallet: AskWalletModel
    let onClose: () -> Void
    /// 次数尽卡片 CTA → 弹次数包购买墙(S4c C3:AskPaywallView 真墙)
    @State private var showAskPaywall = false
    @EnvironmentObject private var env: AppEnvironment

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
                            if model.creditsExhausted {
                                AskCreditsCard(onBuy: { showAskPaywall = true })
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
        // 购买成功(余额 >0)复位卡片态:inputBar 不禁用,买完可直接续问。
        // initial: true——fullScreenCover 重建不回放离场期间的余额变更
        // (402 后关页 → 问事框加购 → 重开聊天),挂载时点补判同一守卫,
        // 防「次数已用完」卡片与 header「剩余 N 问」同屏矛盾
        .onChange(of: wallet.balance, initial: true) { _, balance in
            if let balance, balance > 0, model.creditsExhausted {
                model.resetCreditsExhausted()
            }
        }
        // 次数包购买墙(S4c C3):买成功 dismiss,余额回写由 PurchaseManager
        // 直写 wallet → 上方 onChange 收起 402 卡片
        .sheet(isPresented: $showAskPaywall) {
            AskPaywallView(
                viewModel: AskPaywallViewModel(
                    purchaseManager: env.purchaseManager,
                    onPurchaseSuccess: { showAskPaywall = false }
                )
            )
        }
    }

    // MARK: 顶栏

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(L10n.DailyFortune.askTitle)
                .font(BaziFont.display(size: 17, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(BaziTheme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: model.contextLine)
                    .font(.system(size: 11))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
                // 余额副题(拍板:聊天页也显示;nil = 未查询不显示)。
                // 独立第二行而非 contextLine 尾接——EN 拼音副题已长,同行
                // 挤压换行(fixedSize 坑同款教训)。
                if let balance = wallet.balance, balance > 0 {
                    Text(L10n.DailyFortune.askBalanceRemaining(balance))
                        .font(.system(size: 10.5))
                        .tracking(1)
                        .foregroundStyle(BaziTheme.inkMuted)
                }
            }
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

    // MARK: 次数尽内嵌购买卡(拍板:卡片 + 按钮,不自动弹墙)

    /// 聊天流内嵌「次数已用完」卡片:卡面语言与 AI 气泡族同源
    /// (cardSurface + hairline,左对齐);CTA 打开购买墙。
    private struct AskCreditsCard: View {
        let onBuy: () -> Void

        var body: some View {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.DailyFortune.askCreditsTitle)
                        .font(BaziFont.body(size: 15))
                        .foregroundStyle(BaziTheme.ink)
                    Text(L10n.DailyFortune.askCreditsHint)
                        .font(.system(size: 12))
                        .foregroundStyle(BaziTheme.inkMuted)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        HapticEngine.light()
                        onBuy()
                    } label: {
                        Text(L10n.DailyFortune.askBuyEntryCta)
                            .font(.system(size: 12, weight: .medium))
                            .tracking(1)
                            .foregroundStyle(BaziTheme.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(DailyAskChatView.aiBubbleShape.fill(BaziTheme.cardSurface))
                .overlay(DailyAskChatView.aiBubbleShape.stroke(BaziTheme.hairline, lineWidth: 0.5))
                Spacer(minLength: 64)
            }
            .accessibilityElement(children: .contain)
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
