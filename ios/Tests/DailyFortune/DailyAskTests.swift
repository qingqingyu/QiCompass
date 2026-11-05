import XCTest
import SwiftData
@testable import QiCompass

/// S4 问事窗(2026-10-25,今日问事.html 定稿)的纯逻辑与模型半边:
/// - **出现时机**:DailyAskPresentation 单一阈值(< 64pt)+ 聊天页开 = 强制
///   不可见;内容不满屏(剩余为负)同样算「在底部」。
/// - **数据组装**:候选 = v6 ask_suggestions 优先,缺键/解读未成 →
///   EngineReadingTemplates 确定性表;开场白/窄条短引导/副题引用当日盘面,
///   宜忌词条与 HeroYiJiColumns 词表同源(2026-11-03 窄条化:候选只在
///   聊天页,问事条单行入口)。
/// - **对话流**:首发即收候选、作答中双闸(候选/草稿均拦)、草稿只在
///   成功发出时清、作答失败走可见失败气泡(接缝 DailyAskAnswering 注入)。
///
/// 语言口径:组装走 AppLanguage.current,测试基线设备为 zh——只断言 zh
/// 分支(对齐 chongLabel 测试的既定模式);EN 拼音副题等语言敏感分支不在此锁。
final class DailyAskTests: XCTestCase {

    // MARK: - 出现时机(纯函数)

    func testComposerVisible_距底阈值内可见() {
        XCTAssertTrue(
            DailyAskPresentation.composerVisible(remainingToBottom: 63.9, isChatPresented: false),
            "剩余 < 64pt → 可见"
        )
        XCTAssertTrue(
            DailyAskPresentation.composerVisible(remainingToBottom: 0, isChatPresented: false),
            "恰在底部 → 可见"
        )
    }

    func testComposerVisible_阈值边界严格小于() {
        XCTAssertFalse(
            DailyAskPresentation.composerVisible(remainingToBottom: 64, isChatPresented: false),
            "阈值 64 本身不可见(HTML remaining < 64 严格小于,px≈pt 1:1)"
        )
        XCTAssertFalse(
            DailyAskPresentation.composerVisible(remainingToBottom: 64.1, isChatPresented: false),
            "超出阈值 → 不可见"
        )
    }

    func testComposerVisible_内容不满屏算在底部() {
        XCTAssertTrue(
            DailyAskPresentation.composerVisible(remainingToBottom: -50, isChatPresented: false),
            "剩余为负(视口比内容高)= 已在底部 → 可见,不永不出现"
        )
    }

    func testComposerVisible_聊天页打开期间强制不可见() {
        XCTAssertFalse(
            DailyAskPresentation.composerVisible(remainingToBottom: 0, isChatPresented: true),
            "聊天页拉起期间问事框不可见(HTML onScroll 同款)"
        )
    }

    // MARK: - 数据组装(DailyAskModel.make)

    /// 最小响应夹具(问事只用 dayPillar + dayRelationToDayMaster,其余对齐
    /// HourUnknownGateTests.fixtureResponse 形状)。
    private func makeResponse(
        dayPillar: String = "辛未",
        relation: String = "比肩"
    ) -> DailyFortuneResponse {
        DailyFortuneResponse(
            dayPillar: dayPillar,
            dayRelationToDayMaster: relation,
            dayChong: nil,
            dayChongTargets: [],
            hourPillars: [],
            currentHourIndex: nil,
            lunarDate: "九月十五",
            huangliYi: ["出行"],
            huangliJi: ["动土"],
            tomorrowPreview: TomorrowPreviewDTO(dayPillar: "庚申", dayRelation: "比肩", dayChong: nil),
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1
            )
        )
    }

    @MainActor
    func testMake_v6候选优先_原样进offers() {
        let json = #"{"headline":"比肩当值\n同气相扶","work":"w","relationships":"r","energy":"e","reminder":"m","ask_suggestions":"今天适合去谈判吗？\n单干还是搭伙？\n和同伴分利注意什么？"}"#
        let model = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .okFree(text: json, cached: false)
        )

        XCTAssertEqual(
            model.offers,
            ["今天适合去谈判吗？", "单干还是搭伙？", "和同伴分利注意什么？"],
            "v6 ask_suggestions 存在且非空 → 原样三条(窄条化后候选只在聊天页,不再截前二上条)"
        )
    }

    @MainActor
    func testMake_v5缺键与解读未成_回落确定性候选表() {
        let v5 = #"{"headline":"h","work":"w","relationships":"r","energy":"e","reminder":"m"}"#
        for state in [InterpretState.okFree(text: v5, cached: false), .fetching] {
            let model = DailyAskModel.make(response: makeResponse(), interpretState: state)
            XCTAssertEqual(
                model.offers,
                EngineReadingTemplates.suggestions(for: "比肩"),
                "缺键/未成 → 确定性三表兜底(与解读降级同哲学)"
            )
        }
    }

    @MainActor
    func testMake_开场白引导句副题引用当日盘面() {
        let model = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching
        )

        // zh 基线:开场白 = 已看好 + 十神 + 宜忌词条前二(与 HeroYiJiColumns 同源)
        XCTAssertEqual(
            model.messages.first?.text,
            "这里的盘我看好了:比肩当值,宜独立、立界,忌争执、攀比。挑一条问,或直接说你的事。",
            "开场白逐字锁定(zh;词条 = HeroYiJiColumns zh 表比肩前二)"
        )
        XCTAssertEqual(model.messages.first?.role, .ai, "首条恒为 AI 开场白")

        XCTAssertEqual(
            model.composerLine,
            "比肩当值 · 有事来问",
            "问事窄条短引导(zh 逐字,今日问事-窄条.html 2026-11-03 定稿)"
        )
        XCTAssertEqual(
            model.contextLine,
            "辛未日 · 比肩",
            "sheet 副题 = 日柱+日+十神(zh)"
        )
    }

    // MARK: - 对话流(注入假作答服务)

    /// 立即回话的假作答服务(class:@MainActor 隔离即 Sendable,且
    /// reply 内的录制对测试可见——struct 拷贝会丢录制)。
    @MainActor
    private final class FakeAnswerer: DailyAskAnswering {
        var replyText: String = "已按盘面作答"
        var followUps: [String] = []
        var balance: Int? = nil
        var error: Error? = nil
        private(set) var callCount = 0
        private(set) var recordedHistories: [[DailyAskTurn]] = []

        nonisolated init(
            replyText: String = "已按盘面作答",
            followUps: [String] = [],
            balance: Int? = nil,
            error: Error? = nil
        ) {
            self.replyText = replyText
            self.followUps = followUps
            self.balance = balance
            self.error = error
        }

        func reply(to question: String, history: [DailyAskTurn]) async throws -> DailyAskReply {
            callCount += 1
            recordedHistories.append(history)
            if let error { throw error }
            return DailyAskReply(text: replyText, followUps: followUps, cached: false, balance: balance)
        }
    }

    private struct BoomError: Error {}

    /// 等作答在飞结束(isAnswering 翻 false)。立即回话的假服务一到两个
    /// yield 即过;2s 兜底防挂死。
    @MainActor
    private func waitUntilAnswered(_ model: DailyAskModel) async {
        let deadline = Date().addingTimeInterval(2)
        while model.isAnswering && Date() < deadline {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(model.isAnswering, "2s 内作答应已结束(假服务立即回话)")
    }

    @MainActor
    private func makeChatModel(
        answerer: FakeAnswerer = FakeAnswerer(),
        wallet: AskWalletModel? = nil
    ) -> DailyAskModel {
        DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            answerer: answerer,
            wallet: wallet
        )
    }

    /// 带 Mock 客户端的钱包(apply 直灌初值)。
    @MainActor
    private func makeWallet(_ balance: Int?) -> AskWalletModel {
        let wallet = AskWalletModel(apiClient: MockAPIClient())
        if let balance { wallet.apply(balance) }
        return wallet
    }

    @MainActor
    func test对话流_点候选直发_候选用过即收() async {
        let model = makeChatModel()
        XCTAssertTrue(model.isPristine, "开场即 pristine")
        XCTAssertFalse(model.offers.isEmpty)

        model.sendOffer("今天适合去谈判吗？")
        XCTAssertTrue(model.isAnswering, "发出即作答在飞(HTML busy)")
        XCTAssertEqual(model.messages.last?.role, .user)
        XCTAssertEqual(model.messages.last?.text, "今天适合去谈判吗？")
        XCTAssertTrue(model.offers.isEmpty, "候选用过即收(HTML offersEl.remove)")

        await waitUntilAnswered(model)
        XCTAssertEqual(model.messages.last?.role, .ai)
        XCTAssertEqual(model.messages.last?.text, "已按盘面作答")
        XCTAssertFalse(model.isPristine, "开口后不再是 pristine(宿主不再重建)")
    }

    @MainActor
    func test对话流_作答中双闸_候选与草稿均拦() async {
        let model = makeChatModel()

        model.sendOffer("今天适合去谈判吗？")
        XCTAssertTrue(model.isAnswering)

        // 作答在飞:候选再点、草稿发送均 no-op,不改消息流
        model.sendOffer("单干还是搭伙？")
        model.draft = "第二条草稿"
        model.sendDraft()
        XCTAssertEqual(model.messages.count, 2, "在飞期间新发送一律忽略(HTML busy 守卫)")
        XCTAssertEqual(model.draft, "第二条草稿", "被拦的草稿保留,不误清")

        await waitUntilAnswered(model)
    }

    @MainActor
    func test对话流_空白草稿no_op_成功发送才清草稿() async {
        let model = makeChatModel()

        model.draft = "   \n "
        model.sendDraft()
        XCTAssertEqual(model.messages.count, 1, "空白草稿不产生消息")
        XCTAssertEqual(model.draft, "   \n ", "no-op 不动草稿")

        model.draft = "今天该不该签约？"
        model.sendDraft()
        XCTAssertEqual(model.draft, "", "成功发出草稿清空")
        await waitUntilAnswered(model)
        XCTAssertEqual(model.messages[1].text, "今天该不该签约？")
    }

    @MainActor
    func test对话流_作答失败_可见失败气泡不吞() async {
        let model = makeChatModel(
            answerer: FakeAnswerer(error: BoomError())
        )

        model.sendOffer("今天适合去谈判吗？")
        await waitUntilAnswered(model)

        XCTAssertEqual(model.messages.count, 3, "开场 + 用户问 + 失败气泡")
        XCTAssertEqual(model.messages.last?.role, .ai)
        XCTAssertEqual(
            model.messages.last?.text,
            L10n.DailyFortune.askReplyFailed,
            "失败走可见失败气泡(原文进日志;断言对 L10n 值,语言无关)"
        )
    }

    @MainActor
    func testServicePendingAnswerer_诚实告知不冒充AI() async {
        let answerer = ServicePendingAskAnswerer()
        let reply = try? await answerer.reply(to: "随便问", history: [])
        XCTAssertEqual(reply?.text, L10n.DailyFortune.askPendingReply, "降级告知文案(不伪造 AI 回答)")
        XCTAssertEqual(reply?.followUps, [], "降级实现不带追问")
        XCTAssertEqual(reply?.balance, nil, "降级实现不带余额")
    }

    // MARK: - S4c 作答链路(追问 / 402 分型 / 0 余额短路 / history)

    @MainActor
    func test对话流_作答成功_追问进候选_余额回写钱包() async {
        let wallet = makeWallet(3)
        let answerer = FakeAnswerer(followUps: ["几点开口最稳?", "对方不让步怎么办?"], balance: 2)
        let model = makeChatModel(answerer: answerer, wallet: wallet)

        model.sendOffer("今天适合去谈判吗？")
        await waitUntilAnswered(model)

        XCTAssertEqual(model.offers, ["几点开口最稳?", "对方不让步怎么办?"], "follow_ups 复用 offers 通道(点选直发)")
        XCTAssertEqual(wallet.balance, 2, "作答响应的余额回写钱包")
        XCTAssertFalse(model.creditsExhausted)
    }

    @MainActor
    func test对话流_402_保留用户消息_置卡片态不发失败气泡() async {
        let wallet = makeWallet(1)
        let answerer = FakeAnswerer(
            error: APIError.backendError(code: "ASK_CREDITS_REQUIRED", message: "次数尽", requestId: "t")
        )
        let model = makeChatModel(answerer: answerer, wallet: wallet)

        model.sendOffer("今天适合去谈判吗？")
        await waitUntilAnswered(model)

        XCTAssertEqual(model.messages.count, 2, "开场 + 用户问;402 不产生 AI 气泡(卡片才是回应)")
        XCTAssertEqual(model.messages.last?.role, .user, "用户消息保留")
        XCTAssertTrue(model.creditsExhausted, "置内嵌购买卡片态(拍板:不自动弹墙)")
        XCTAssertEqual(wallet.balance, 0, "402 后钱包归零(与后端口径一致)")
    }

    @MainActor
    func test对话流_403上下文过期_专用气泡引导刷新() async {
        let answerer = FakeAnswerer(
            error: APIError.backendError(code: "CONTEXT_TOKEN_INVALID", message: "凭证失效", requestId: "t")
        )
        let model = makeChatModel(answerer: answerer)

        model.sendOffer("今天适合去谈判吗？")
        await waitUntilAnswered(model)

        XCTAssertEqual(
            model.messages.last?.text,
            L10n.DailyFortune.askReplyContextExpired,
            "context_token 过期 → 引导回今日页下拉刷新的专用气泡(非通用失败)"
        )
        XCTAssertFalse(model.creditsExhausted)
    }

    @MainActor
    func test对话流_余额0_本地短路不出网_草稿保留() async {
        let wallet = makeWallet(0)
        let answerer = FakeAnswerer()
        let model = makeChatModel(answerer: answerer, wallet: wallet)

        // 候选直发:不出网、消息不入流、置卡片态
        model.sendOffer("今天适合去谈判吗？")
        XCTAssertEqual(answerer.callCount, 0, "本地 0 余额短路,不出网(省一次必 402 往返)")
        XCTAssertEqual(model.messages.count, 1, "问题未被回答,不入消息流")
        XCTAssertTrue(model.creditsExhausted)

        // 草稿:被闸拦时文字保留(买完可直接再发)
        model.draft = "明天呢？"
        model.sendDraft()
        XCTAssertEqual(answerer.callCount, 0)
        XCTAssertEqual(model.draft, "明天呢？", "短路被拦草稿保留,不误清")

        // 余额回正 → 卡片复位,发送恢复
        wallet.apply(3)
        model.resetCreditsExhausted()
        XCTAssertFalse(model.creditsExhausted)
        model.sendDraft()
        await waitUntilAnswered(model)
        XCTAssertEqual(answerer.callCount, 1, "复位后正常出网")
        XCTAssertEqual(model.messages.count, 3, "开场白 + 草稿那条问题 + AI 回答,正常入流作答")
    }

    @MainActor
    func test对话流_history排除开场白_截末20轮() async throws {
        let answerer = FakeAnswerer()
        let model = makeChatModel(answerer: answerer)

        // 21 轮问答(开场白之外 42 条消息),服务端契约整单 ≤20 轮
        for round in 0..<21 {
            model.sendOffer("第\(round)问？")
            await waitUntilAnswered(model)
        }

        // 第 21 次发送(第 20 问)时:上文 = 已完成 20 轮 = 40 条消息,
        // dropFirst 排开场白后取末 20 → 自「第10问」的 user 回合起
        let lastHistory = try XCTUnwrap(answerer.recordedHistories.last)
        XCTAssertEqual(lastHistory.count, 20, "history 截末 20 轮(服务端 >20 整单 422)")
        XCTAssertEqual(lastHistory.first?.role, "user", "截取段首是 user 回合(开场白不入 history)")
        XCTAssertEqual(lastHistory.first?.text, "第10问？", "最老的「第0-9问」被截掉")
        XCTAssertEqual(lastHistory.last?.role, "ai", "末条是第 19 轮的 AI 回答")
    }

    // MARK: - DailyAskContext.interpretationText(纯函数四分支)

    private func joined(_ insight: DailyInsight) -> String {
        [insight.headline, insight.work, insight.relationships, insight.energy, insight.reminder]
            .joined(separator: "\n")
    }

    func test解读正文_okFree五段重连() {
        let v6 = "{\"headline\":\"静心开局\",\"work\":\"先做要紧的事\",\"relationships\":\"话留三分\",\"energy\":\"按节奏\",\"reminder\":\"量力而行\"}"
        let text = DailyAskContext.interpretationText(for: .okFree(text: v6, cached: false), relation: "比肩")
        XCTAssertEqual(text, "静心开局\n先做要紧的事\n话留三分\n按节奏\n量力而行", "五段值 \\n 连(label 是 UI 骨架不进上下文)")
    }

    func test解读正文_畸形JSON回落引擎模板() {
        let text = DailyAskContext.interpretationText(for: .okFree(text: "不是JSON的散文", cached: false), relation: "比肩")
        XCTAssertEqual(text, joined(EngineReadingTemplates.insight(for: "比肩")), "parse nil → 与屏上降级同路(引擎模板)")
    }

    func test解读正文_离线v3散文透传() {
        let prose = "二〇二六年旧版散文快照,一段完整正文。"
        let text = DailyAskContext.interpretationText(for: .offlineLegacy(text: prose, languageNote: nil), relation: "比肩")
        XCTAssertEqual(text, prose, "v3 散文没有五段可拆,原文即屏上正文")
    }

    func test解读正文_离线畸形v4快照_回落引擎模板与屏上同路() {
        // 离线快照 parse 失败 + looksLikeJSON = 畸形 v4(缓存毒化残留形态):
        // 屏上兜底渲染引擎模板(DailyInterpretationSection 三分支),context 须同路,
        // 不把原始畸形 JSON 串当「用户所见的今日解读」发给后端
        let malformed = "{\"headline\":\"静心开局\",\"work\":\"先做要紧的事"
        let text = DailyAskContext.interpretationText(for: .offlineLegacy(text: malformed, languageNote: nil), relation: "比肩")
        XCTAssertEqual(
            text,
            joined(EngineReadingTemplates.insight(for: "比肩")),
            "畸形 v4 离线快照 → 引擎模板(与屏上 degradedBody 同款),非原文透传"
        )
    }

    func test解读正文_未就绪态走引擎模板_超4096截断() {
        XCTAssertEqual(
            DailyAskContext.interpretationText(for: .idle, relation: "劫财"),
            joined(EngineReadingTemplates.insight(for: "劫财")),
            "idle/fetching/failed 等未就绪态 = 降级态屏上渲染的引擎模板"
        )
        let long = String(repeating: "长", count: 5000)
        let clamped = DailyAskContext.interpretationText(for: .offlineLegacy(text: long, languageNote: nil), relation: "比肩")
        XCTAssertEqual(clamped.count, 4096, "统一 prefix(4096) clamp(服务端 max_length=4096)")
    }

    // MARK: - S多会话(2026-11-04,今日问事-多会话.html 定稿)

    /// 内存容器(@MainActor 测试)。用 `ModelContainerFactory.makeInMemory()`
    /// 既有工厂。**调用方必须显式持有返回的 container**——ModelContext 不
    /// 保活容器,容器释放后 context 上的操作会直接 trap(2026-11-05 测试
    /// 二分实证);故本 helper 只返回 container,context 由调用方自行取,
    /// 两者都在测试作用域内存活。
    @MainActor
    private func makeAskContainer() throws -> ModelContainer {
        try ModelContainerFactory.makeInMemory()
    }

    @MainActor
    private func makePersistence(
        context: ModelContext,
        record: AskConversation? = nil,
        chartHash: String = "hashA",
        dateKey: String,
        onFirstTurn: ((AskConversation) -> Void)? = nil
    ) -> AskPersistence {
        AskPersistence(
            record: record,
            context: context,
            chartHash: chartHash,
            dateKey: dateKey,
            onFirstTurn: onFirstTurn,
            onTurn: nil
        )
    }

    @MainActor
    func test多会话_首问落盘_标题截断_重开回读() async throws {
        let container = try makeAskContainer()
        let context = container.mainContext
        let today = AskDayKey.of(Date())
        var registered: AskConversation?
        let model = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            answerer: FakeAnswerer(),
            persistence: makePersistence(context: context, dateKey: today) { registered = $0 },
            todayKeyProvider: { today }
        )
        XCTAssertTrue(model.isPristine, "临时会话 pristine(空会话不落盘)")

        let question = "这句话超过十二个字会被截断作为标题吗？"
        model.sendOffer(question)
        await waitUntilAnswered(model)

        let record = try XCTUnwrap(registered, "首问发出即落盘并回告")
        XCTAssertEqual(record.title, String(question.prefix(DailyAskModel.titleLength)), "标题 = 首问截断(12 字)")
        XCTAssertEqual(record.chartHash, "hashA")
        XCTAssertEqual(record.dateKey, today)
        XCTAssertEqual(record.contextLine, "辛未日 · 比肩", "副题创建时定版")
        XCTAssertEqual(record.turns.map(\.role), ["ai", "user", "ai"], "开场白随行入库 + 问 + 答")

        // 重开:消息从记录种入,副题/标题用定版值;非 pristine 宿主不再重建
        let reopened = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            persistence: makePersistence(context: context, record: record, dateKey: today),
            todayKeyProvider: { today }
        )
        XCTAssertEqual(reopened.messages.count, 3)
        XCTAssertEqual(reopened.messages.map(\.text), record.turns.map(\.text))
        XCTAssertEqual(reopened.contextLine, record.contextLine)
        XCTAssertEqual(reopened.displayTitle, record.title)
        XCTAssertFalse(reopened.isPristine)
    }

    @MainActor
    func test多会话_往日只读_发送短路不出网_草稿保留() throws {
        let container = try makeAskContainer()
        let context = container.mainContext
        let yesterday = try XCTUnwrap(
            Calendar.current.date(byAdding: .day, value: -1, to: Date())
        )
        let past = AskConversation(
            chartHash: "hashA",
            dateKey: AskDayKey.of(yesterday),
            title: "昨天的问",
            contextLine: "乙丑日 · 偏财"
        )
        context.insert(past)
        past.append(role: AskConversation.AskTurnRecord.roleAI, text: "开场")
        past.append(role: AskConversation.AskTurnRecord.roleUser, text: "昨问")
        past.append(role: AskConversation.AskTurnRecord.roleAI, text: "昨答")
        try context.save()

        let today = AskDayKey.of(Date())
        let answerer = FakeAnswerer()
        // 0 余额 + 只读同时在场:锁死闸序——只读在前,旧线连次数尽卡都不出
        let model = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            answerer: answerer,
            wallet: makeWallet(0),
            persistence: makePersistence(
                context: context,
                record: past,
                dateKey: AskDayKey.of(yesterday)
            ),
            todayKeyProvider: { today }
        )
        XCTAssertTrue(model.isReadOnly, "记录日早于今日 = 只读")
        XCTAssertEqual(model.displayTitle, "昨天的问")
        XCTAssertEqual(model.contextLine, "乙丑日 · 偏财", "副题用记录定版值,不拿今天现算")

        // 只读闸在余额闸之前:不出网、不入流、草稿保留、不置次数尽卡
        model.sendOffer("今天接着问？")
        model.draft = "草稿保留"
        model.sendDraft()
        XCTAssertEqual(answerer.callCount, 0)
        XCTAssertEqual(model.messages.count, 3)
        XCTAssertEqual(model.draft, "草稿保留")
        XCTAssertFalse(model.creditsExhausted, "只读闸在前:旧线连次数尽卡都不出")
    }

    @MainActor
    func test多会话_跨午夜_provider实时翻转只读() throws {
        let container = try makeAskContainer()
        let context = container.mainContext
        var key = "2026-11-03"
        let record = AskConversation(chartHash: "A", dateKey: key, title: "t", contextLine: "c")
        context.insert(record)
        record.append(role: AskConversation.AskTurnRecord.roleAI, text: "o")
        record.append(role: AskConversation.AskTurnRecord.roleUser, text: "q")
        try context.save()

        let model = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            persistence: makePersistence(context: context, record: record, dateKey: key),
            todayKeyProvider: { key }
        )
        XCTAssertFalse(model.isReadOnly, "当日可聊")
        key = "2026-11-04"   // provider 实时读 store.todayKey 的语义模拟
        XCTAssertTrue(model.isReadOnly, "跨午夜后旧线转只读")
    }

    /// 23:00 滚日窗口(zi_next_day,APIClient 硬编码产品默认):23:00–00:00
    /// 页面 businessDate 已前移到次日而墙钟未跨日——该窗口的新线 dateKey =
    /// 页面日(超前墙钟日一天),踩的正是已解锁的新盘,必须可聊;判 `!=`
    /// 会每晚这一小时全部 born-readonly(2026-11-06 双 review R1)。
    @MainActor
    func test多会话_23点滚日窗口_页面超前日新线可聊() throws {
        let container = try makeAskContainer()
        let context = container.mainContext
        let wallToday = AskDayKey.of(Date())
        let pageTomorrow = AskDayKey.of(
            Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        )
        let answerer = FakeAnswerer()
        // 临时新线:record = nil,dateKey = 页面日(超前)——不得判只读
        let model = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            answerer: answerer,
            persistence: makePersistence(context: context, dateKey: pageTomorrow),
            todayKeyProvider: { wallToday }
        )
        XCTAssertFalse(model.isReadOnly, "页面超前日(23:00 滚日窗口)新线可聊")

        // 落在窗口内创建的线(dateKey = 页面日):墙钟追平(次日)后仍是
        // 当日线,继续可聊;再过一日才转只读
        let windowLine = AskConversation(
            chartHash: "hashA", dateKey: pageTomorrow, title: "t", contextLine: "c"
        )
        context.insert(windowLine)
        try context.save()
        let nextDay = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            persistence: makePersistence(context: context, record: windowLine, dateKey: pageTomorrow),
            todayKeyProvider: { pageTomorrow }
        )
        XCTAssertFalse(nextDay.isReadOnly, "墙钟追平后 = 今日线,可聊")

        // store 侧同口径:超前日线归「今天」组、不压只读签;canStartNewThread
        // 在页面超前时为真(新开一问照常可点)
        let store = AskConversationStore(context: context)
        store.syncDay(chartHash: "hashA", dateKey: pageTomorrow)
        XCTAssertEqual(store.todaySummaries.map(\.id), [windowLine.id], "超前日线归今天组(仍可聊)")
        XCTAssertTrue(store.pastSummaries.isEmpty)
        XCTAssertTrue(store.canStartNewThread, "页面超前日可开新线")

        // 反向:离线陈旧页(页面日落后墙钟日)canStartNewThread = false
        // ——新线必 born-readonly,「+ 新开一问」chip 该隐藏
        let stalePage = AskDayKey.of(
            Calendar.current.date(byAdding: .day, value: -2, to: Date())!
        )
        store.syncDay(chartHash: "hashA", dateKey: stalePage)
        XCTAssertFalse(store.canStartNewThread, "页面落后墙钟日:新线不可开(chip 隐藏)")
    }

    @MainActor
    func test多会话_损流水回落开场白_拒覆写保残骸() throws {
        let container = try makeAskContainer()
        let context = container.mainContext
        let today = AskDayKey.of(Date())
        let corrupt = AskConversation(
            chartHash: "hashA",
            dateKey: today,
            title: "损",
            contextLine: "c",
            messagesData: Data("not-json".utf8)
        )
        context.insert(corrupt)
        try context.save()
        XCTAssertTrue(corrupt.turns.isEmpty, "损数据按空处理(留痕不崩)")

        // 种入:空流水回落开场白,不塌成零气泡(testing 审查:空壳会让
        // isPristine 判真 + 零气泡死屏)
        let model = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            persistence: makePersistence(context: context, record: corrupt, dateKey: today),
            todayKeyProvider: { today }
        )
        XCTAssertEqual(model.messages.first?.role, .ai, "回看语境完整:回落开场白")

        // append 拒覆写(red-team:decode 空 + 追加 = 把残骸整块冲掉)
        corrupt.append(role: AskConversation.AskTurnRecord.roleUser, text: "新问")
        XCTAssertEqual(
            String(data: corrupt.messagesData, encoding: .utf8),
            "not-json",
            "拒追加,残骸原样保留"
        )
    }

    @MainActor
    func test多会话_既有线追问与失败气泡_同口径落盘() async throws {
        let container = try makeAskContainer()
        let context = container.mainContext
        let today = AskDayKey.of(Date())
        var registered: AskConversation?
        let model = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            answerer: FakeAnswerer(),
            persistence: makePersistence(context: context, dateKey: today) { registered = $0 },
            todayKeyProvider: { today }
        )
        model.sendOffer("第一问？")
        await waitUntilAnswered(model)
        let record = try XCTUnwrap(registered)

        // 重开追问:走「既有线追加」分支,不建新记录,顺序交替
        let reopened = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            persistence: makePersistence(context: context, record: record, dateKey: today),
            todayKeyProvider: { today }
        )
        reopened.sendOffer("第二问？")
        await waitUntilAnswered(reopened)
        XCTAssertEqual(record.turns.map(\.role), ["ai", "user", "ai", "user", "ai"], "既有线只追加,顺序不乱")

        // 失败气泡入库:重开回看可见当时那条失败线
        let failing = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            answerer: FakeAnswerer(error: BoomError()),
            persistence: makePersistence(context: context, record: record, dateKey: today),
            todayKeyProvider: { today }
        )
        failing.sendOffer("第三问？")
        await waitUntilAnswered(failing)
        XCTAssertEqual(record.turns.last?.text, L10n.DailyFortune.askReplyFailed, "失败气泡随行入库")

        // 402:用户问入库、无 AI 尾(与消息流同口径——卡片才是回应)
        let exhausted = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            answerer: FakeAnswerer(
                error: APIError.backendError(code: "ASK_CREDITS_REQUIRED", message: "次数尽", requestId: "t")
            ),
            wallet: makeWallet(1),
            persistence: makePersistence(context: context, record: record, dateKey: today),
            todayKeyProvider: { today }
        )
        exhausted.sendOffer("第四问？")
        await waitUntilAnswered(exhausted)
        XCTAssertEqual(record.turns.last?.role, "user", "402 无 AI 气泡入库")
    }

    @MainActor
    func test多会话_store三态选择与今日归组_按盘过滤() throws {
        let container = try makeAskContainer()
        let context = container.mainContext
        var fakeNow = Date()
        let store = AskConversationStore(context: context, now: { fakeNow })
        let today = store.todayKey
        let yesterday = AskDayKey.of(Calendar.current.date(byAdding: .day, value: -1, to: Date())!)

        func seed(_ chart: String, _ day: String, title: String, updated: Date) -> AskConversation {
            let record = AskConversation(chartHash: chart, dateKey: day, title: title, contextLine: "ctx")
            context.insert(record)
            record.append(role: AskConversation.AskTurnRecord.roleAI, text: "开场")
            record.append(role: AskConversation.AskTurnRecord.roleUser, text: title)
            record.updatedAt = updated
            return record
        }

        let early = seed("A", today, title: "早的今日线", updated: Date(timeIntervalSinceNow: -100))
        let late = seed("A", today, title: "晚的今日线", updated: Date())
        let past = seed("A", yesterday, title: "昨日线", updated: Date(timeIntervalSinceNow: -50))
        let twoDaysAgo = AskDayKey.of(Calendar.current.date(byAdding: .day, value: -2, to: Date())!)
        _ = seed("A", twoDaysAgo, title: "前日线", updated: Date())
        _ = seed("B", today, title: "别盘线", updated: Date())
        try context.save()

        store.syncDay(chartHash: "A", dateKey: today)
        XCTAssertEqual(store.todaySummaries.map(\.title), ["晚的今日线", "早的今日线"], "updatedAt 降序;B 盘不混入")
        XCTAssertEqual(store.pastSummaries.map(\.title), ["前日线", "昨日线"], "往日组 updatedAt 降序")

        // 时间签三分支:今天 HH:mm / 昨天 / 更早 M月d日
        XCTAssertTrue(
            store.todaySummaries.allSatisfy {
                $0.timeLabel.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil
            },
            "今天分支 HH:mm"
        )
        let byTitle = Dictionary(uniqueKeysWithValues: store.pastSummaries.map { ($0.title, $0) })
        XCTAssertEqual(byTitle["昨日线"]?.timeLabel, L10n.DailyFortune.askTimeYesterday, "昨天分支")
        XCTAssertFalse(byTitle["前日线"]?.timeLabel.isEmpty ?? true, "更早分支(M月d日 模板)已执行")

        // .auto = 最近一条今日会话(strip 打开语义)
        XCTAssertEqual(store.resolveRecord()?.id, late.id)
        // .record = 显式选中(含往日只读回看)
        store.select(past.id)
        XCTAssertEqual(store.resolveRecord()?.id, past.id)
        // .newThread = 恒新线(不回落最近一条)
        store.startNew()
        XCTAssertNil(store.resolveRecord())
        // register(首问回告)= **只刷列表不动 selection**(对抗审查 F1:动
        // selection 会让宿主把在飞作答的模型整个换掉)
        store.register(early)
        XCTAssertEqual(store.selection, .newThread, "selection 不动")
        // 选择失效(记录已不存在)→ 回落最近今日线,不空开
        store.select(UUID())
        XCTAssertEqual(store.resolveRecord()?.id, late.id, "失效选择回落 strip 打开语义")
        // strip 重开语义:回看完往日线后重置
        store.select(past.id)
        store.resetSelection()
        XCTAssertEqual(store.resolveRecord()?.id, late.id, "重置回 auto = 最近今日线")
        // 换盘重置回 auto:新盘的最近今日线
        store.select(past.id)
        store.syncDay(chartHash: "B", dateKey: today)
        XCTAssertEqual(store.resolveRecord()?.title, "别盘线")

        // 跨午夜(store 时钟注入):今日键前移 → 活跃选择作废 + 归组翻转
        // (store 此刻视角 = B 盘:别盘线转入往日)
        fakeNow = Calendar.current.date(byAdding: .day, value: 1, to: fakeNow)!
        store.refreshTodayKey()
        XCTAssertEqual(store.todayKey, AskDayKey.of(fakeNow))
        XCTAssertTrue(store.todaySummaries.isEmpty, "昨天的今日线整体转入往日")
        XCTAssertEqual(store.pastSummaries.map(\.title), ["别盘线"], "B 盘视角:唯一会话转入往日")
    }
}
