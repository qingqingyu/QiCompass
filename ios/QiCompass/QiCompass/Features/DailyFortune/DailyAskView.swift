import SwiftUI

// MARK: - S4 问事窗(2026-10-25 今日问事.html;2026-11-03 问事框窄条化,今日问事-窄条.html 定稿)

/// 今日页底部两级问事交互:
/// ① **问事窄条**(DailyAskComposerStrip):今日页滚到最底才从 tab 栏上方
///    滑出,收在顶部不可见——「运势读完」与「可以问事」是同一时刻(出现时机 =
///    `DailyAskPresentation` 纯函数,宿主 DailyFortuneMainView 注入滚动探针);
///    2026-11-03 窄条化(今日问事-窄条.html 四轮目验定稿):单行高 44、与
///    tab 栏同宽、虚一档(透底 0.86 + 影减半,不描边);候选 chips 只留
///    聊天页开场,窄条上不再展开;
/// ② **聊天页**(DailyAskChatView):点问事窄条向上拉起独立整页(无 tab 栏),
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
        DailyAskReply(text: L10n.DailyFortune.askPendingReply, followUps: [], cached: false, balance: nil, chargedFrom: nil)
    }
}

// MARK: 模型

/// 问事对话模型:开场消息 + 候选问题 + 消息流。宿主 DailyFortuneMainView
/// 持有(@State),换日/换盘重建(对话随旧盘走),用户开口后(pristine 之外)
/// 不再因解读态变化被重置。
/// (2026-10-28 审查 P2:ObservableObject → @Observable,与全仓 5 个
/// ViewModel 统一;聊天页因 $model.draft 用 @Bindable 注入)
@Observable
@MainActor
final class DailyAskModel {
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
    private(set) var messages: [Message]
    /// 剩余候选问题(首发即收——HTML offers 用过即删,不占对话流)。
    private(set) var offers: [String]
    /// 输入框草稿(空白/作答中发送为 no-op,草稿保留不误清)。
    var draft: String = ""
    /// 作答在飞(HTML busy 守卫:在飞期间新发送一律忽略)。
    private(set) var isAnswering = false
    /// 次数已用尽(402 ASK_CREDITS_REQUIRED 或本地余额 0 短路):聊天流
    /// 内嵌购买卡片;购买成功(余额 >0)由聊天页 onChange 复位。
    private(set) var creditsExhausted = false

    /// sheet 副题「辛未日 · 比肩」。
    let contextLine: String
    /// 问事窄条短引导「比肩当值 · 有事来问」。
    let composerLine: String

    // MARK: S多会话(2026-11-04,今日问事-多会话.html 定稿)

    /// 落盘记录(nil = 临时会话,首问发出时创建——空会话不落盘)。
    private(set) var record: AskConversation?
    /// 会话归属日(yyyy-MM-dd;≠ todayKeyProvider() = 往日只读)。
    let dateKey: String
    /// 今日键供给(闭包实时读——跨午夜由 store 刷新,不持旧值;默认恒等
    /// dateKey = 永不只读:tests / 无落盘环境不注入)。
    private let todayKeyProvider: () -> String
    /// 落盘材料(nil = 纯内存会话:tests / 离线兜底无盘身份,现行为不变)。
    private let persistence: AskPersistence?

    private let answerer: DailyAskAnswering
    /// 问事钱包(weak 表达所有权归 AppEnvironment——模型不延长钱包生命
    /// 周期;@Observable 的观察本身不持引用,weak 不再是防观察环;nil = 测试无钱包注入)
    weak var wallet: AskWalletModel?

    init(
        opening: String,
        offers: [String],
        composerLine: String,
        contextLine: String,
        answerer: DailyAskAnswering = ServicePendingAskAnswerer(),
        wallet: AskWalletModel? = nil,
        persistence: AskPersistence? = nil,
        todayKeyProvider: (() -> String)? = nil
    ) {
        // 打开既有会话:消息从记录种入(开场白已随行入库),副题用
        // 记录定版值——往日线的日柱/十神属当天,不能拿今天的现算。
        // 损流水(解码失败 → turns 空)回落开场白:回看语境不塌成零气泡
        // (testing 审查:空壳会让 isPristine 判真,宿主可能重建——回落后
        // 记录仍在,行为退化为「重开只看得到开场白」,可见降级)。
        self.record = persistence?.record
        self.persistence = persistence
        self.messages = persistence?.record.flatMap { record in
            let seeded = record.turns.map { turn in
                Message(
                    role: turn.role == AskConversation.AskTurnRecord.roleUser ? .user : .ai,
                    text: turn.text
                )
            }
            return seeded.isEmpty ? nil : seeded
        } ?? [.init(role: .ai, text: opening)]
        self.offers = offers
        self.composerLine = composerLine
        self.contextLine = persistence?.record?.contextLine ?? contextLine
        let key = persistence?.dateKey ?? AskDayKey.of(Date())
        self.dateKey = key
        self.todayKeyProvider = todayKeyProvider ?? { key }
        self.answerer = answerer
        self.wallet = wallet
    }

    /// 往日只读(抽屉回看旧线;send 全闸不出网不入流——拍板不跨天续聊)。
    /// 判定 = `AskDayKey.isPastDay`(早于今日才只读):23:00 滚日窗口
    /// (页面日超前墙钟日)的新线必须可聊,判 `!=` 会 born-readonly。
    var isReadOnly: Bool { AskDayKey.isPastDay(dateKey, todayKey: todayKeyProvider()) }

    /// 顶栏标题:落盘会话用其标题(首问定版);临时会话回模块名「问事」。
    var displayTitle: String {
        if let record { return record.title }
        return L10n.DailyFortune.askTitle
    }

    /// 会话标题长度(首问截断;今日问事-多会话.html 定稿 12 字)。
    static let titleLength = 12

    // MARK: 发送

    /// 点候选问题直接发出(聊天页 offers 点选直发;窄条化后候选只在聊天页)。
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
        // 往日只读闸(在余额闸之前——旧线连「次数尽」卡都不该出,回看而已)
        guard !isReadOnly else { return false }
        // 本地 0 余额短路:不出网(必 402 的往返没有意义),置购买卡片态;
        // 消息不入流——问题还没被回答,买完原话还在草稿/候选里可再发
        if wallet?.balance == 0 {
            if !creditsExhausted {
                creditsExhausted = true
                // TASK-06:余额打空瞬间记一次(试用尽 → 转化观察;置位幂等防重)
                Analytics.askTrialExhausted()
            }
            return false
        }
        offers = []
        // 对话上文:排除开场白(它不是对话回合),截末 20 轮(服务端整单
        // >20 轮 422,只注入末 6 轮——客户端保末 20 给模型足量记忆)
        let history = messages.dropFirst().suffix(20).map { message in
            DailyAskTurn(
                role: message.role == .user
                    ? AskConversation.AskTurnRecord.roleUser
                    : AskConversation.AskTurnRecord.roleAI,
                text: message.text
            )
        }
        messages.append(.init(role: .user, text: text))
        persistUserTurn(text)
        isAnswering = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let reply = try await self.answerer.reply(to: text, history: history)
                // TASK-12:paid 精确归因——服务端返回本次实扣来源
                // (缓存命中/免费重放 chargedFrom=nil 记 paid=false)
                Analytics.askSent(paid: reply.chargedFrom == "purchased")
                self.messages.append(.init(role: .ai, text: reply.text))
                self.persistAITurn(reply.text)
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
                    self.persistAITurn(L10n.DailyFortune.askReplyContextExpired)
                } else {
                    self.messages.append(.init(role: .ai, text: L10n.DailyFortune.askReplyFailed))
                    self.persistAITurn(L10n.DailyFortune.askReplyFailed)
                }
            }
            self.isAnswering = false
        }
        return true
    }

    // MARK: 多会话落盘(2026-11-04;AskPersistence 为 nil 时全链路跳过)

    /// 用户消息落盘:临时会话在此建记录——标题(首问截断)/副题/开场白
    /// 随行入库(回看语境完整);已落会话只追加。**建记录分支不调 onTurn**
    /// (register 已刷新列表,双调 = 同一轮三次 fetch,简化审查 S5)。
    private func persistUserTurn(_ text: String) {
        guard let p = persistence else { return }
        if let record {
            record.append(role: AskConversation.AskTurnRecord.roleUser, text: text)
            AskPersistence.save(p.context, what: "userTurn")
            p.onTurn?()
        } else {
            let conversation = AskConversation(
                chartHash: p.chartHash,
                dateKey: p.dateKey,
                title: String(text.prefix(Self.titleLength)),
                contextLine: contextLine
            )
            // 坑纪律:ModelContext 不保活 ModelContainer——生产侧容器由
            // AppEnvironment 全程持有(安全);测试侧见 makeAskContainer 注释
            p.context.insert(conversation)
            if let opening = messages.first?.text {
                conversation.append(
                    role: AskConversation.AskTurnRecord.roleAI,
                    text: opening,
                    at: conversation.createdAt
                )
            }
            conversation.append(role: AskConversation.AskTurnRecord.roleUser, text: text)
            AskPersistence.save(p.context, what: "firstTurn")
            record = conversation
            p.onFirstTurn?(conversation)
        }
    }

    /// AI 侧落盘(作答 / 失败 / 凭证过期气泡;402 无消息不入库——与消息流
    /// 同口径,history 语义会话内外一致:重开回看的线就是当时的那条线)。
    private func persistAITurn(_ text: String) {
        guard let p = persistence, let record else { return }
        record.append(role: AskConversation.AskTurnRecord.roleAI, text: text)
        AskPersistence.save(p.context, what: "aiTurn")
        p.onTurn?()
    }

    /// 用户是否尚未开口(仅开场白、无作答在飞)——宿主据此判断解读态
    /// 变化时可否安全重建(开口后重建会丢对话)。
    var isPristine: Bool {
        messages.count <= 1 && !isAnswering
    }

    /// 购买成功(余额 >0)后由聊天页调用:收起购买卡片,对话可继续
    /// (外部主动复位而非模型自监听——@Observable 观察不产生循环引用,
    /// 不自监听是职责单一:模型管对话态,钱包归 AppEnvironment)。
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
        wallet: AskWalletModel? = nil,
        persistence: AskPersistence? = nil,
        todayKeyProvider: (() -> String)? = nil
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
            wallet: wallet,
            persistence: persistence,
            todayKeyProvider: todayKeyProvider
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

// MARK: ① 问事窄条(滚到底滑出,tab 栏上方)

/// 问事窄条:今日页滚到最底从 tab 栏上方滑出的单行入口,整条可点开聊天页。
/// 视觉规格事实源 = 今日问事-窄条.html(2026-11-03 四轮目验定稿):
/// 与 tab 栏同宽(宿主注入左右 14 边距)/ 高 44 / radius = 高度一半(浮动
/// 胶囊语言,对齐系统 tab 栏)/ 一行 = 墨青灯点 + 「问事」 + 竖分隔 +
/// 短引导 + 余额签 + ›;**虚一档**(拍板「透底+减影」)= cardSurface 0.86
/// 不透明度(纸色透上来,边界对比弱半档)+ 影减淡放散(秤砣比 tab 轻半档),
/// **不描边**(细描边箍浅色窄条读作勾出来的框/临时态)。
/// 原四段卡(状态行/引导句/候选 chips/展开脚注)随窄条退役——候选问题
/// 只在聊天页开场携带;0 次加购形态同为一行:标题位换「问事次数已用完」+
/// 尾部加购签,点条 = 弹购买墙,不进聊天。
struct DailyAskComposerStrip: View {
    let model: DailyAskModel
    let wallet: AskWalletModel
    let onOpen: () -> Void
    /// 0 次加购形态点条入口(S4c:弹次数包购买墙;C3 换真墙)
    let onBuyPack: () -> Void

    var body: some View {
        Button(action: wallet.balance == 0 ? onBuyPack : onOpen) {
            HStack(spacing: 9) {
                // 墨青灯点:原头行「已看好今天的盘」的灯,窄条化后只留灯不落字
                Circle()
                    .fill(BaziTheme.jade)
                    .frame(width: 7, height: 7)
                if wallet.balance == 0 {
                    exhaustedTexts
                } else {
                    normalTexts
                }
                Text(verbatim: "›")
                    .font(.system(size: 13))
                    .foregroundStyle(BaziTheme.inkMuted)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 虚一档·透底:0.86(HTML rgba 0.92→0.86 同源;cardSurface 半透
            // 叠宣纸 = 纸色渗上来,形薄一档)
            .background(
                Capsule().fill(BaziTheme.cardSurface.opacity(0.86))
            )
            // 虚一档·减影:HTML 0 10px 26px·0.08(blur≈2×radius 的近似映射)
            .shadow(color: BaziTheme.ink.opacity(0.08), radius: 13, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11yLabel)
    }

    /// VoiceOver 标签(红队审查修复:静态 label 会把余额/次数尽状态藏掉)
    /// ——组合播报恒含信息:正常态 = 打开问事对话 + 剩余 N 问(视觉余额签
    /// 被 ViewThatFits 掉时 VO 仍播报,EN 掉签不掉信息);0 次态 = 状态 +
    /// 加购动作,不再只念 CTA。
    private var a11yLabel: String {
        if wallet.balance == 0 {
            return "\(L10n.DailyFortune.askCreditsTitle), \(L10n.DailyFortune.askBuyEntryCta)"
        }
        var label = L10n.DailyFortune.askComposerA11y
        if let balance = wallet.balance, balance > 0 {
            label += ", \(L10n.DailyFortune.askBalanceRemaining(balance))"
        }
        return label
    }

    /// 正常形态一行:「问事 | 比肩当值 · 有事来问 —— 剩余 N 问」。一行放不下时
    /// **先掉余额签保引导完整**(2026-11-03 拍板 A)——退化确定性:放不下 =
    /// 不显示,不戴省略号截断;余额落地(nil→N)不产生截断跳变。zh 余量
    /// ~40pt 永不触发;**EN 实测为常态触发**(带余额整行最短十神名也需
    /// ~426pt 屏宽,标准机型 375-402pt 不显余额,仅 Plus/Max 可显)——EN
    /// 余额仍见聊天页 header,VO 标签恒播报余额(a11yLabel)不受此影响。
    /// 手法沿用本文件 chips 行(已退役)的 ViewThatFits 先例。
    private var normalTexts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                leadTexts
                Spacer(minLength: 8)
                balanceText
            }
            HStack(spacing: 9) {
                leadTexts
                Spacer(minLength: 8)
            }
        }
    }

    /// 行首固定段:标题 + 竖分隔 + 短引导。
    private var leadTexts: some View {
        HStack(spacing: 9) {
            Text(L10n.DailyFortune.askTitle)
                .font(BaziFont.display(size: 15.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(BaziTheme.ink)
            Rectangle()
                .fill(BaziTheme.hairline)
                .frame(width: 0.5, height: 14)
            Text(verbatim: model.composerLine)
                .font(.system(size: 12))
                .tracking(0.5)
                .foregroundStyle(BaziTheme.inkMuted)
                .lineLimit(1)
        }
    }

    /// 行尾余额签(未查询 nil / 用尽 0 不显示)。
    @ViewBuilder
    private var balanceText: some View {
        if let balance = wallet.balance, balance > 0 {
            Text(L10n.DailyFortune.askBalanceRemaining(balance))
                .font(.system(size: 11))
                .tracking(0.5)
                .lineLimit(1)
                .foregroundStyle(BaziTheme.inkMuted)
        }
    }

    /// 0 次加购形态一行:「问事次数已用完 —— +15 问,继续问事」(点条弹墙)。
    /// EN 小屏放不下时同拍板 A:掉尾部加购签保主句(› 与点条动作仍在,
    /// 加购语义不丢)。
    private var exhaustedTexts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                exhaustedTitle
                Spacer(minLength: 8)
                buyCtaText
            }
            HStack(spacing: 9) {
                exhaustedTitle
                Spacer(minLength: 8)
            }
        }
    }

    /// 0 次形态主句。
    private var exhaustedTitle: some View {
        Text(L10n.DailyFortune.askCreditsTitle)
            .font(BaziFont.display(size: 15.5, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(BaziTheme.ink)
            .lineLimit(1)
    }

    /// 尾部加购签(正常态不渲染)。
    private var buyCtaText: some View {
        Text(L10n.DailyFortune.askBuyEntryCta)
            .font(.system(size: 11))
            .tracking(0.5)
            .lineLimit(1)
            .foregroundStyle(BaziTheme.inkMuted)
    }
}

// MARK: ② 聊天页(fullScreenCover 整页,无 tab 栏)

/// 问事聊天页:顶栏(三叠横墨抽屉钮 + 会话标题 + 盘面副题 + 余额副题 +
/// ✕)+ 消息流 + 候选问题 + 次数尽内嵌购买卡 + 输入栏(往日只读线换成
/// 提示条)。S多会话(2026-11-04):左上抽屉钮拉开「问事录」——每次对话
/// 一条,今日可聊 / 往日只读;作答在飞显示三点输入指示;新消息自动滚到底
/// (短对话 plain VStack,scrollTo 惰性坑不涉及)。
struct DailyAskChatView: View {
    @Bindable var model: DailyAskModel
    let wallet: AskWalletModel
    /// 会话协调器(抽屉/只读条/换日刷新依赖它;宿主必建——lazy store 先于
    /// 任何 askModel 存在,fullScreenCover 守卫处与 model 双解包)。
    let store: AskConversationStore
    let onClose: () -> Void
    /// 次数尽卡片 CTA → 弹次数包购买墙(S4c C3:AskPaywallView 真墙)
    @State private var showAskPaywall = false
    /// S多会话:问事录抽屉开合。
    @State private var showDrawer = false
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

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
                            // 只读线的候选是死控件(点击被只读闸无声拦下)——
                            // 不可操作的信息不上屏(red-team:同头栏余额隐藏口径)
                            if !model.offers.isEmpty, !model.isReadOnly {
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
                bottomBar
            }
            // S多会话:问事录抽屉(左滑 + 压暗;reduce-motion 降级纯淡入)
            if showDrawer {
                drawerLayer
            }
        }
        // 跨午夜:回前台刷新今日键——旧线转只读、列表重新分组(拍板:
        // 换日 = 新盘,昨天的活跃线不作数)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshTodayKey()
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
        HStack(alignment: .center, spacing: 10) {
            // S多会话:三叠横墨抽屉钮——沿用「深度」tab 的线描语言
            // (今日问事-多会话.html 认可稿:不引入系统 hamburger 图形),
            // 与右上 ✕ 对称的 30pt 描边圆钮
            Button {
                HapticEngine.light()
                store.reload()
                openDrawer()
            } label: {
                TabIcons.DeepTabIcon(size: 15)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(BaziTheme.hairline, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.DailyFortune.askMenuA11y)
            // HIG 命中目标 44pt(2026-10-27 审查 H2 同款):视觉 30pt 圈不动
            .contentShape(Rectangle().inset(by: -7))
            VStack(alignment: .leading, spacing: 2) {
                // S多会话:标题 = 会话标题(首问定版;临时会话回模块名)
                Text(verbatim: model.displayTitle)
                    .font(BaziFont.display(size: 17, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(BaziTheme.ink)
                    .lineLimit(1)
                Text(verbatim: model.contextLine)
                    .font(.system(size: 11))
                    .tracking(1)
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
                // 余额副题(拍板:聊天页也显示;nil = 未查询不显示)。
                // 独立第二行而非 contextLine 尾接——EN 拼音副题已长,同行
                // 挤压换行(fixedSize 坑同款教训);往日只读线不显示
                // (不可操作的信息不上屏)。
                if let balance = wallet.balance, balance > 0, !model.isReadOnly {
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
            // HIG 命中目标 44pt(2026-10-27 审查 H2):视觉 30pt 圈不动,
            // contentShape 负向外扩热区到 44——不改布局不碰视觉
            .contentShape(Rectangle().inset(by: -7))
        }
        .padding(.horizontal, 14)
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
                    // HIG 命中目标 44pt(2026-10-27 审查 H2):视觉 chip ~30pt
                    // 不动,热区外扩;上方是说明文字(不可点),重叠无副作用
                    .contentShape(Rectangle().inset(by: -7))
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
            // 身份用内容而非位置(2026-10-28 审查 P3:offers 用后清/被
            // followUps 替换,位置身份在行获状态时会咬人)
            ForEach(model.offers, id: \.self) { question in
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

    // MARK: S多会话:问事录抽屉(左滑 + 压暗)

    /// 底栏二态:今日线 = 输入栏;往日只读线 = 提示条(+新开一问直达)。
    @ViewBuilder
    private var bottomBar: some View {
        if model.isReadOnly {
            readonlyBar
        } else {
            inputBar
        }
    }

    /// 往日只读提示条:「不跨天续聊」拍板的落地形态——今天的盘不答昨天
    /// 的线,回看可以,续问开新线。页面日落后墙钟日(离线陈旧页)时新线
    /// 同样必只读,chip 隐藏 + 文案换陈旧页变体(不可操作的信息不上屏,
    /// 文案不得指引已隐藏的动作)。
    @ViewBuilder
    private var readonlyBar: some View {
        HStack(spacing: 10) {
            Text(
                store.canStartNewThread
                    ? L10n.DailyFortune.askReadonlyHint
                    : L10n.DailyFortune.askReadonlyHintStale
            )
                .font(.system(size: 12.5))
                .foregroundStyle(BaziTheme.inkMuted)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if store.canStartNewThread {
                newThreadChip { store.startNew() }
            }
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

    /// 抽屉开合(reduce-motion 降级淡入;动效三式纪律)。
    private func openDrawer() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.9)) {
            showDrawer = true
        }
    }

    private func dismissDrawer() {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.9)) {
            showDrawer = false
        }
    }

    /// 「+ 新开一问」chip(只读条 + 抽屉头共用,样式单一事实源;横向 11pt
    /// = HTML 认可稿定值,简化审查 S3:两份手抄必漂移)。
    private func newThreadChip(action: @escaping () -> Void) -> some View {
        Button {
            HapticEngine.light()
            action()
        } label: {
            Text(L10n.DailyFortune.askDrawerNew)
                .font(.system(size: 12))
                .foregroundStyle(BaziTheme.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        // HIG 44pt:视觉 chip ~30pt,热区外扩
        .contentShape(Rectangle().inset(by: -7))
    }

    /// 抽屉层:压暗(点按即收)+ 左滑面板(宽 78%,**上限 420**——iPad/
    /// 横屏 regular 宽度下 78% 会撑到 1000pt+,封顶回落手机规格列)。
    /// VO:escape 手势可收抽屉(压暗层对 VO 不可见不可点,red-team a11y)。
    private var drawerLayer: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(BaziTheme.inkDeep.opacity(0.30))
                    .ignoresSafeArea()
                    .onTapGesture(perform: dismissDrawer)
                    .accessibilityHidden(true)
                drawerPanel
                    .frame(width: min(geo.size.width * 0.78, 420))
            }
        }
        .transition(
            reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading))
        )
        .accessibilityAction(.escape) { dismissDrawer() }
    }

    /// 面板:头(问事录 + 新开一问)+ 会话列表(今天/往日)+ 脚注。
    private var drawerPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.DailyFortune.askDrawerTitle)
                    .font(BaziFont.display(size: 19, weight: .semibold))
                    .tracking(2)
                    .foregroundStyle(BaziTheme.ink)
                Spacer(minLength: 8)
                if store.canStartNewThread {
                    newThreadChip {
                        store.startNew()
                        dismissDrawer()
                    }
                }
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(BaziTheme.hairline).frame(height: 0.5)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.todaySummaries.isEmpty && store.pastSummaries.isEmpty {
                        Text(L10n.DailyFortune.askDrawerEmpty)
                            .font(.system(size: 12))
                            .foregroundStyle(BaziTheme.inkMuted)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                    } else {
                        if !store.todaySummaries.isEmpty {
                            drawerGroupLabel(L10n.DailyFortune.askDrawerToday)
                            ForEach(store.todaySummaries) { summary in
                                drawerRow(summary)
                            }
                        }
                        if !store.pastSummaries.isEmpty {
                            drawerGroupLabel(L10n.DailyFortune.askDrawerPast)
                            ForEach(store.pastSummaries) { summary in
                                drawerRow(summary)
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            Text(L10n.DailyFortune.askDrawerFoot)
                .font(.system(size: 11))
                .tracking(0.5)
                .foregroundStyle(BaziTheme.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .overlay(alignment: .top) {
                    Rectangle().fill(BaziTheme.hairline).frame(height: 0.5)
                }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(BaziTheme.cardSurface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(BaziTheme.hairline).frame(width: 0.5)
        }
        // HTML 12px 0 32px·0.14 → 右向投影(x=12)
        .shadow(color: BaziTheme.ink.opacity(0.14), radius: 16, x: 12)
    }

    private func drawerGroupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .tracking(1.6)
            .foregroundStyle(BaziTheme.inkMuted)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }

    /// 会话行:标题(首问定版)+ 只读签 + 时间签,副行末轮预览;当前条 =
    /// 墨青灯点 + 淡墨底(与窄条灯点同语言);往日整行压淡。isPast 与模型
    /// isReadOnly 同源(AskDayKey.isPastDay)——分组与只读闸不打架。
    private func drawerRow(_ summary: AskConversationSummary) -> some View {
        let isCurrent = summary.id == model.record?.id
        let isPast = AskDayKey.isPastDay(summary.dateKey, todayKey: store.todayKey)
        return Button {
            HapticEngine.light()
            store.select(summary.id)
            dismissDrawer()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    if isCurrent {
                        Circle()
                            .fill(BaziTheme.jade)
                            .frame(width: 7, height: 7)
                    }
                    Text(verbatim: summary.title)
                        .font(BaziFont.body(size: 15))
                        .foregroundStyle(BaziTheme.ink)
                        .lineLimit(1)
                    if isPast {
                        Text(L10n.DailyFortune.askReadonlyBadge)
                            .font(.system(size: 9.5))
                            .tracking(1)
                            .foregroundStyle(BaziTheme.inkMuted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .overlay(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
                    }
                    Spacer(minLength: 4)
                    Text(verbatim: summary.timeLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(BaziTheme.inkMuted)
                }
                Text(verbatim: summary.preview)
                    .font(.system(size: 11.5))
                    .foregroundStyle(BaziTheme.inkMuted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(BaziTheme.ink.opacity(isCurrent ? 0.05 : 0))
            )
            .opacity(isPast ? 0.58 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        // VO:整行合并播报(标题+只读签+预览+时间),当前线加 isSelected
        // 特征(墨青灯点是纯视觉,VO 用户无从得知在哪条线)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
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
            // HIG 命中目标 44pt(2026-10-27 审查 H2):视觉 40pt 圆不动,外扩 2pt
            .contentShape(Rectangle().inset(by: -2))
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
