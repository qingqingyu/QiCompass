import XCTest
@testable import QiCompass

/// S4 问事窗(2026-10-25,今日问事.html 定稿)的纯逻辑与模型半边:
/// - **出现时机**:DailyAskPresentation 单一阈值(< 64pt)+ 聊天页开 = 强制
///   不可见;内容不满屏(剩余为负)同样算「在底部」。
/// - **数据组装**:候选 = v6 ask_suggestions 优先,缺键/解读未成 →
///   EngineReadingTemplates 确定性表;开场白/引导句/副题引用当日盘面,
///   宜忌词条与 HeroYiJiColumns 词表同源。
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
    func testMake_v6候选优先_前两条进问事框chip() {
        let json = #"{"headline":"比肩当值\n同气相扶","work":"w","relationships":"r","energy":"e","reminder":"m","ask_suggestions":"今天适合去谈判吗？\n单干还是搭伙？\n和同伴分利注意什么？"}"#
        let model = DailyAskModel.make(
            response: makeResponse(),
            interpretState: .okFree(text: json, cached: false)
        )

        XCTAssertEqual(
            model.offers,
            ["今天适合去谈判吗？", "单干还是搭伙？", "和同伴分利注意什么？"],
            "v6 ask_suggestions 存在且非空 → 原样三条"
        )
        XCTAssertEqual(
            model.composerChips,
            ["今天适合去谈判吗？", "单干还是搭伙？"],
            "问事框 chip 只取前两条(HTML cp-chips 两条)"
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
            "比肩当值的一天。你的事,挑一条来问——",
            "问事框引导句(zh 逐字,HTML cp-line)"
        )
        XCTAssertEqual(
            model.contextLine,
            "辛未日 · 比肩",
            "sheet 副题 = 日柱+日+十神(zh)"
        )
        XCTAssertEqual(model.composerChips.count, 2, "chip 恒两条(确定性表也截前二)")
    }

    // MARK: - 对话流(注入假作答服务)

    /// 立即回话的假作答服务。
    private struct FakeAnswerer: DailyAskAnswering {
        var replyText: String = "已按盘面作答"
        var error: Error? = nil

        func reply(to question: String) async throws -> String {
            if let error { throw error }
            return replyText
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
    private func makeChatModel(answerer: FakeAnswerer = FakeAnswerer()) -> DailyAskModel {
        DailyAskModel.make(
            response: makeResponse(),
            interpretState: .fetching,
            answerer: answerer
        )
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
        let reply = try? await answerer.reply(to: "随便问")
        XCTAssertEqual(
            reply,
            L10n.DailyFortune.askPendingReply,
            "端点未上线 → 恒回「作答服务接入中」告知文案(不伪造 AI 回答)"
        )
    }
}
