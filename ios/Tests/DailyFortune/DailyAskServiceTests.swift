import XCTest
@testable import QiCompass

/// S4c 问事服务层测试(C1 网络层半边):
/// - **DTO 编解码**:DailyAskRequest 的 target_date 单字段 `yyyy-MM-dd`
///   (Pydantic date 严格拒绝时间分量)、snake_case 显式键、Optional 字段
///   nil 省略;DailyAskResponse 的 follow_up_suggestions 映射;AskRedeem
///   系列契约键。
/// - **Mock 三端点**:dailyAsk 默认应答(固定答案+2 追问+内部余额自减)、
///   余额耗尽抛 402 ASK_CREDITS_REQUIRED(与真后端同 code,402→购买卡片
///   分型链路 mock 走查可验)、askRedeem +15 幂等(同 tx 重放 credits=0)、
///   responder 注入与请求录制。
///
/// C2 追加:LiveDailyAskAnswerer(question/history 截断/组包)与
/// AskWalletModel(首查带 device_token 置 flag、apply 单调守卫)。
final class DailyAskServiceTests: XCTestCase {

    // MARK: - DTO:DailyAskRequest 编码

    private func makeRequest(
        question: String = "今天适合去谈判吗?",
        history: [DailyAskTurn] = [],
        userLocalId: String? = "ulid-test-1",
        contextToken: String? = "tok-daily-1"
    ) -> DailyAskRequest {
        DailyAskRequest(
            contentHash: "chash-ask-1",
            context: [
                "day_master": AnyCodableJSON("辛金"),
                "favorable_elements": AnyCodableJSON("土、金"),
            ],
            contextToken: contextToken,
            targetDate: Date(timeIntervalSince1970: 0),  // 编码断言用固定日期
            userLocalId: userLocalId,
            question: question,
            history: history,
            dailyInterpretation: "比肩当值 同气相扶亦暗藏争夺。"
        )
    }

    func test请求编码_target_date为yyyyMMdd本地时区() throws {
        // 固定一个本地时区正午,排除跨日歧义(编码走 .current 时区)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
        let req = makeRequest()
        let encoded = try JSONEncoder().encode(
            DailyAskRequest(
                contentHash: req.contentHash, context: req.context,
                contextToken: req.contextToken, targetDate: noon,
                userLocalId: req.userLocalId, question: req.question,
                history: req.history, dailyInterpretation: req.dailyInterpretation
            )
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["target_date"] as? String, "2026-10-25", "后端 date 字段严格拒绝时间分量")
        XCTAssertEqual(json["content_hash"] as? String, "chash-ask-1")
        XCTAssertEqual(json["context_token"] as? String, "tok-daily-1")
        XCTAssertEqual(json["user_local_id"] as? String, "ulid-test-1")
        XCTAssertEqual(json["daily_interpretation"] as? String, "比肩当值 同气相扶亦暗藏争夺。")
        XCTAssertNil(json["device_token"], "作答请求恒不带 device_token(铸造职责在 balance 首查)")
    }

    func test请求编码_Optional字段nil省略_无默认值键() throws {
        let req = makeRequest(userLocalId: nil, contextToken: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        XCTAssertNil(json["user_local_id"])
        XCTAssertNil(json["context_token"])
    }

    func test请求编码_history嵌套snake无关_字段名原样() throws {
        let req = makeRequest(history: [
            DailyAskTurn(role: "user", text: "第一问"),
            DailyAskTurn(role: "ai", text: "第一答"),
        ])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        let history = try XCTUnwrap(json["history"] as? [[String: Any]])
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0]["role"] as? String, "user")
        XCTAssertEqual(history[1]["text"] as? String, "第一答")
    }

    func test请求解码_roundTrip保真() throws {
        let original = makeRequest(history: [DailyAskTurn(role: "user", text: "问")])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DailyAskRequest.self, from: data)
        XCTAssertEqual(decoded.contentHash, original.contentHash)
        XCTAssertEqual(decoded.context["day_master"], AnyCodableJSON("辛金"))
        XCTAssertEqual(decoded.history, original.history)
        // yyyy-MM-dd 只保「日」不保时刻:round-trip 断言同日(本地时区),
        // 时分秒被舍去是契约本身,不是丢数据
        XCTAssertTrue(Calendar.current.isDate(decoded.targetDate, inSameDayAs: original.targetDate),
                      "round-trip 须保同一本地日")
    }

    // MARK: - DTO:响应解码

    func test响应解码_followUpSuggestions映射与cachedBalance() throws {
        let json = """
        {"answer": "宜午前开口。", "follow_up_suggestions": ["几点开口最稳?", "对方不让步怎么办?"],
         "cached": false, "balance": 2}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(DailyAskResponse.self, from: json)
        XCTAssertEqual(resp.answer, "宜午前开口。")
        XCTAssertEqual(resp.followUps, ["几点开口最稳?", "对方不让步怎么办?"])
        XCTAssertFalse(resp.cached)
        XCTAssertEqual(resp.balance, 2)
    }

    func testRedeem响应解码_契约键对齐() throws {
        let json = """
        {"credits": 15, "balance": 18, "transaction_id": "txn-1", "purchased_at": "2026-10-26T08:00:00Z"}
        """.data(using: .utf8)!
        let resp = try JSONDecoder().decode(AskRedeemResponse.self, from: json)
        XCTAssertEqual(resp.credits, 15)
        XCTAssertEqual(resp.balance, 18)
        XCTAssertEqual(resp.transactionId, "txn-1")
        XCTAssertEqual(resp.purchasedAt, "2026-10-26T08:00:00Z", "ISO 串原样保留不转 Date")
    }

    func testRedeem请求编码_snakeCase键() throws {
        let req = AskRedeemRequest(transactionId: "txn-1", productId: "com.qicompass.daily_ask.pack15", userLocalId: "ulid-1")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        XCTAssertEqual(json["transaction_id"] as? String, "txn-1")
        XCTAssertEqual(json["product_id"] as? String, "com.qicompass.daily_ask.pack15")
        XCTAssertEqual(json["user_local_id"] as? String, "ulid-1")
    }

    // MARK: - Mock 三端点

    func testMock作答_默认应答_余额自减并回传() async throws {
        let mock = MockAPIClient()
        mock.setMockAskBalance(3)
        let resp = try await mock.dailyAsk(request: makeRequest())
        XCTAssertFalse(resp.cached)
        XCTAssertEqual(resp.balance, 2, "试用 3 − 1")
        XCTAssertEqual(resp.followUps.count, 2)
        XCTAssertEqual(mock.mockAskBalance, 2)
    }

    func testMock作答_余额耗尽_抛402同码() async {
        let mock = MockAPIClient()
        mock.setMockAskBalance(0)
        do {
            _ = try await mock.dailyAsk(request: makeRequest())
            XCTFail("余额 0 应抛 ASK_CREDITS_REQUIRED")
        } catch {
            XCTAssertTrue(APIError.isAskCreditsRequired(error), "mock 与真后端同 code,分型链路可走查")
        }
    }

    func testMock作答_请求录制与responder注入() async throws {
        let mock = MockAPIClient()
        mock.dailyAskResponder = { req in
            DailyAskResponse(answer: "注入答案", followUps: ["追问A"], cached: true, balance: 9)
        }
        let resp = try await mock.dailyAsk(request: makeRequest(question: "录制断言"))
        XCTAssertEqual(resp.answer, "注入答案")
        XCTAssertTrue(resp.cached)
        let recorded = mock.recordedDailyAskRequests
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded[0].question, "录制断言", "录制在钩子之前完成,responder 不影响断言")
    }

    func testMock余额_返回内部钱包值() async throws {
        let mock = MockAPIClient()
        mock.setMockAskBalance(18)
        let resp = try await mock.askBalance(userLocalId: "ulid-1", deviceToken: nil)
        XCTAssertEqual(resp.balance, 18)
    }

    func testMock次数包赎回_加15_同tx重放幂等credits0() async throws {
        let mock = MockAPIClient()
        mock.setMockAskBalance(3)
        let req = AskRedeemRequest(transactionId: "txn-pack-1", productId: AskPackProductID.pack15, userLocalId: "ulid-1")
        let first = try await mock.askRedeem(request: req)
        XCTAssertEqual(first.credits, 15)
        XCTAssertEqual(first.balance, 18, "试用 3 + 15")
        let replay = try await mock.askRedeem(request: req)
        XCTAssertEqual(replay.credits, 0, "重放不重复入账")
        XCTAssertEqual(replay.balance, 18)
        XCTAssertEqual(mock.recordedAskRedeemRequests.count, 2, "每次都录(后端语义:每次都验,幂等在台账层)")
    }

    func testMock余额_调用录制含deviceToken携带态() async throws {
        let mock = MockAPIClient()
        _ = try await mock.askBalance(userLocalId: "ulid-1", deviceToken: nil)
        _ = try await mock.askBalance(userLocalId: "ulid-1", deviceToken: "dc-token-1")
        XCTAssertEqual(
            mock.recordedAskBalanceCalls,
            [
                MockAPIClient.RecordedAskBalanceCall(userLocalId: "ulid-1", deviceToken: nil),
                MockAPIClient.RecordedAskBalanceCall(userLocalId: "ulid-1", deviceToken: "dc-token-1"),
            ],
            "C2「首查带 device_token 置 flag」的断言面:device_token 是否发出只能在此验")
    }

    // MARK: - 402 分型判定

    func testAskCredits判定_他码与裸错误为否() {
        XCTAssertTrue(APIError.isAskCreditsRequired(
            APIError.backendError(code: "ASK_CREDITS_REQUIRED", message: "次数尽", requestId: "r-1")))
        XCTAssertFalse(APIError.isAskCreditsRequired(
            APIError.backendError(code: "QUOTA_EXCEEDED", message: "他码", requestId: "r-1")),
            "同走付费墙的旧码不得混入——分型错误会弹错卡片")
        XCTAssertFalse(APIError.isAskCreditsRequired(URLError(.timedOut)),
                       "非 APIError(网络层错误)走通用失败面,不进购买卡")
    }

    // MARK: - query 编码(send 统一拼接的 %2B 补丁)

    func testQuery编码_加号转义保DeviceCheck令牌() throws {
        // base64 令牌含 '+'/'/'/'=':URLComponents.queryItems 不编码 RFC
        // 合法的裸 '+',而 starlette parse_qsl 把 '+' 解码为空格 → 令牌腐蚀
        let items = [
            URLQueryItem(name: "user_local_id", value: "ulid-1"),
            URLQueryItem(name: "device_token", value: "AbC+/123=="),
        ]
        let query = try XCTUnwrap(LiveAPIClient.percentEscapedQuery(items))
        XCTAssertFalse(query.contains("+"), "裸 + 必须全部转义为 %2B: \(query)")
        // 服务端解码语义(queryItems getter 模拟 parse_qsl 的 unquote):还原原值
        var comps = URLComponents()
        comps.percentEncodedQuery = query
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "device_token" })?.value, "AbC+/123==")
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "user_local_id" })?.value, "ulid-1")
    }

    // MARK: - C2:LiveDailyAskAnswerer(组包/截断/录制断言)

    @MainActor
    func testLive作答_组包字段与上下文透传() async throws {
        let mock = MockAPIClient()
        let noon = Calendar.current.date(byAdding: .hour, value: 12, to: Calendar.current.startOfDay(for: .now))!
        let context = DailyAskContext(
            contentHash: "chash-live-1",
            context: ["day_master": AnyCodableJSON("辛金")],
            contextToken: "tok-daily-9",
            targetDate: noon,
            dailyInterpretation: "五段正文"
        )
        let answerer = LiveDailyAskAnswerer(apiClient: mock, context: context)
        let reply = try await answerer.reply(
            to: "今天适合去谈判吗?",
            history: [DailyAskTurn(role: "user", text: "上一问")]
        )

        XCTAssertEqual(reply.text.isEmpty, false, "mock 默认应答非空")
        let recorded = try XCTUnwrap(mock.recordedDailyAskRequests.last)
        XCTAssertEqual(recorded.contentHash, "chash-live-1")
        XCTAssertEqual(recorded.contextToken, "tok-daily-9", "token 取自上下文快照(daily-fortune 响应签发)")
        XCTAssertEqual(recorded.dailyInterpretation, "五段正文")
        XCTAssertEqual(recorded.history.count, 1)
        XCTAssertEqual(recorded.history[0].role, "user")
        XCTAssertNil(recorded.deviceToken, "作答请求恒不带 device_token(铸造职责在 balance 首查)")
        XCTAssertEqual(reply.balance, 2, "balance 透传(mock 默认 3 自减)")
    }

    @MainActor
    func testLive作答_问题200截断_history末20轮逐轮2000() async throws {
        let mock = MockAPIClient()
        let context = DailyAskContext(
            contentHash: "c", context: [:], contextToken: "t",
            targetDate: .now, dailyInterpretation: "d"
        )
        let answerer = LiveDailyAskAnswerer(apiClient: mock, context: context)
        let longQuestion = String(repeating: "问", count: 350)
        let longHistory = (0..<25).map { DailyAskTurn(role: "user", text: String(repeating: "\($0 % 10)", count: 1) + String(repeating: "字", count: 2100)) }
        _ = try? await answerer.reply(to: longQuestion, history: longHistory)

        let recorded = try XCTUnwrap(mock.recordedDailyAskRequests.last)
        XCTAssertEqual(recorded.question.count, 200, "问题纵深截断 200(服务端超限 422)")
        XCTAssertEqual(recorded.history.count, 20, "history 纵深截末 20 轮")
        XCTAssertTrue(recorded.history.allSatisfy { $0.text.count <= 2000 }, "每轮 ≤2000")
        XCTAssertTrue(recorded.history.contains { $0.text.hasPrefix("5") }, "保留的是末段(第 5 轮仍在,第 0-4 轮被截)")
    }

    // MARK: - C2:AskWalletModel(首查 device_token 置 flag / 单调守卫)

    @MainActor
    func test钱包_refresh首次带deviceToken_成败置flag后不再带() async {
        UserDefaults.standard.removeObject(forKey: "qicompass.ask.mint_attempted.v1")
        defer { UserDefaults.standard.removeObject(forKey: "qicompass.ask.mint_attempted.v1") }

        let mock = MockAPIClient()
        // 注入假 token 供给:模拟器不支持 DeviceCheck,不注入则「首查带
        // token」语义不可测
        let wallet = AskWalletModel(apiClient: mock, tokenProvider: { "dc-token-+/base64==" })
        // 首查:后端拒绝(模拟 DC 拦 402)——已达后端,flag 应置
        mock.askBalanceResponder = { _, _ in
            throw APIError.backendError(code: "ASK_CREDITS_REQUIRED", message: "已铸过", requestId: "t")
        }
        await wallet.refresh()
        XCTAssertEqual(mock.recordedAskBalanceCalls.count, 1)
        XCTAssertEqual(mock.recordedAskBalanceCalls[0].deviceToken, "dc-token-+/base64==",
                       "首次查询附 DeviceCheck token(Mock 层不经 URL 编码,录到注入原值;编码保真由 testQuery编码 用例另行锁定)")
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "qicompass.ask.mint_attempted.v1"), "已达后端(402 拒铸)→ 置已尝试 flag,重发无意义")

        // 二查:不再带 token
        mock.askBalanceResponder = nil
        await wallet.refresh()
        XCTAssertEqual(mock.recordedAskBalanceCalls.count, 2)
        XCTAssertNil(mock.recordedAskBalanceCalls[1].deviceToken, "flag 已置 → 不再附 token")
        XCTAssertEqual(wallet.balance, 3, "mock 默认余额 3")
    }

    @MainActor
    func test钱包_refresh网络失败_不置flag_下次再带token() async {
        UserDefaults.standard.removeObject(forKey: "qicompass.ask.mint_attempted.v1")
        defer { UserDefaults.standard.removeObject(forKey: "qicompass.ask.mint_attempted.v1") }

        let mock = MockAPIClient()
        let wallet = AskWalletModel(apiClient: mock, tokenProvider: { "dc-tok" })
        mock.askBalanceResponder = { _, _ in
            throw APIError.networkError(URLError(.notConnectedToInternet))
        }
        await wallet.refresh()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "qicompass.ask.mint_attempted.v1"), "网络层失败(请求未达后端)不置 flag,下次再试")

        mock.askBalanceResponder = nil
        await wallet.refresh()
        XCTAssertEqual(mock.recordedAskBalanceCalls.count, 2, "第二次查询照常发起")
        XCTAssertEqual(mock.recordedAskBalanceCalls[1].deviceToken, "dc-tok", "flag 未置 → 再次附 token")
    }

    @MainActor
    func test钱包_apply单调守卫_旧回写不回卷() {
        let wallet = AskWalletModel(apiClient: MockAPIClient())
        let base = Date()
        wallet.apply(5, issuedAt: base)
        wallet.apply(3, issuedAt: base.addingTimeInterval(-10))
        XCTAssertEqual(wallet.balance, 5, "更早时点的回写被丢(作答响应 vs refresh 并发乱序)")
        wallet.apply(1, issuedAt: base.addingTimeInterval(10))
        XCTAssertEqual(wallet.balance, 1, "更新时点正常生效")
    }
}
