import XCTest
@testable import QiCompass

/// DailyImageStore 状态机测试(S3)。
///
/// stub 客户端直接实现窄协议 DailyImageAPIClient(两个方法),
/// 语义对齐 LiveAPIClient:202 以 (json, 202) 元组返回;非 2xx **默认**
/// 由客户端 throw APIError(httpError/backendError)。404 双臂都有覆盖:
/// throw 形态(Live 实际行为)与元组形态(协议允许)都应触发重派。
@MainActor
final class DailyImageStoreTests: XCTestCase {
    // MARK: - fixtures

    private let request = DailyFortuneRequest(
        chartHash: "test_hash_img",
        targetDate: Date(timeIntervalSince1970: 1_789_600_000),
        chartPayload: ChartPayloadDTO(
            dayMaster: "己",
            dayMasterElement: "earth",
            dayMasterStrength: "weak",
            favorableElements: ["火", "土"],
            unfavorableElements: ["水", "金"],
            fourPillars: [
                "year": PillarRefDTO(gan: "庚", zhi: "午"),
                "month": PillarRefDTO(gan: "己", zhi: "卯"),
                "day": PillarRefDTO(gan: "己", zhi: "卯"),
                "hour": PillarRefDTO(gan: "辛", zhi: "未"),
            ]
        )
    )

    /// 1×1 PNG(合法 UIImage 可解,区别于乱 bytes)。
    private static let pngBytes = Data(base64Encoded:(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    ))!

    private var savedInterval: TimeInterval = 0
    private var savedMaxPolls = 0

    override func setUp() {
        super.setUp()
        savedInterval = DailyImageStore.pollIntervalSeconds
        savedMaxPolls = DailyImageStore.maxPolls
        DailyImageStore.pollIntervalSeconds = 0.01
        DailyImageStore.maxPolls = 40
    }

    override func tearDown() {
        DailyImageStore.pollIntervalSeconds = savedInterval
        DailyImageStore.maxPolls = savedMaxPolls
        super.tearDown()
    }

    // MARK: - stub

    /// 可编程 stub:POST 状态序列 + GET content 行为脚本化,全计数。
    private final class StubClient: DailyImageAPIClient, @unchecked Sendable {
        var statusResponses: [DailyImageStatusDTO] = []
        var statusError: Error?
        var statusCalls = 0

        /// 每次 GET content 依序消费;耗尽后重复最后一个。
        var contentResults: [Result<(data: Data, statusCode: Int), Error>] = []
        var contentCalls = 0

        func dailyImageStatus(request: DailyFortuneRequest) async throws -> DailyImageStatusDTO {
            statusCalls += 1
            if let statusError { throw statusError }
            guard !statusResponses.isEmpty else {
                throw APIError.httpError(statusCode: 500, body: "stub 未配置 status")
            }
            let r = statusResponses.removeFirst()
            statusResponses.append(r)  // 重复消费(幂等语义)
            return r
        }

        func dailyImageContent(chartHash: String, targetDate: String) async throws -> (data: Data, statusCode: Int) {
            contentCalls += 1
            let idx = min(contentCalls - 1, contentResults.count - 1)
            guard !contentResults.isEmpty else {
                throw APIError.httpError(statusCode: 500, body: "stub 未配置 content")
            }
            switch contentResults[idx] {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
    }

    // MARK: - 用例

    func test_miss_then_ready_immediately() async {
        let stub = StubClient()
        stub.statusResponses = [.init(status: "ready", error: nil)]
        stub.contentResults = [.success((Self.pngBytes, 200))]
        let store = DailyImageStore(client: stub)

        await store.load(request: request)

        guard case .ready(let image) = store.state else {
            return XCTFail("期望 ready,实际 \(store.state)")
        }
        XCTAssertFalse(image.size == .zero)
        XCTAssertEqual(stub.statusCalls, 1)
        XCTAssertEqual(stub.contentCalls, 1)
    }

    func test_cache_hit_skips_network() async {
        let stub = StubClient()
        stub.statusResponses = [.init(status: "ready", error: nil)]
        stub.contentResults = [.success((Self.pngBytes, 200))]
        let store = DailyImageStore(client: stub)

        await store.load(request: request)
        XCTAssertEqual(stub.statusCalls, 1)

        // 第二次(同 store 同 key):NSCache 命中,零网络
        await store.load(request: request)
        XCTAssertEqual(stub.statusCalls, 1)
        XCTAssertEqual(stub.contentCalls, 1)
        guard case .ready = store.state else { return XCTFail("期望 ready") }
    }

    func test_generating_polls_until_ready() async {
        let stub = StubClient()
        stub.statusResponses = [.init(status: "generating", error: nil)]
        stub.contentResults = [
            .success((Self.jsonStatus("generating"), 202)),
            .success((Self.jsonStatus("generating"), 202)),
            .success((Self.pngBytes, 200)),
        ]
        let store = DailyImageStore(client: stub)

        await store.load(request: request)

        guard case .ready = store.state else { return XCTFail("期望轮询后 ready,实际 \(store.state)") }
        XCTAssertEqual(stub.contentCalls, 3)
    }

    func test_409_failed_surfaces_backend_error_message() async {
        let stub = StubClient()
        stub.statusResponses = [.init(status: "generating", error: nil)]
        stub.contentResults = [
            .failure(APIError.httpError(
                statusCode: 409,
                body: #"{"status":"failed","error":"生图上游 HTTP 500"}"#
            ))
        ]
        let store = DailyImageStore(client: stub)

        await store.load(request: request)

        guard case .failed(let message) = store.state else {
            return XCTFail("期望 failed,实际 \(store.state)")
        }
        XCTAssertTrue(message.contains("生图上游"), "应透出后端 error_message,实际 \(message)")
    }

    func test_429_limit_surfaces_code() async {
        let stub = StubClient()
        stub.statusError = APIError.backendError(
            code: "DAILY_IMAGE_LIMIT",
            message: "当日生图量已达上限(200),明日再试",
            requestId: nil
        )
        let store = DailyImageStore(client: stub)

        await store.load(request: request)

        guard case .failed(let message) = store.state else {
            return XCTFail("期望 failed,实际 \(store.state)")
        }
        XCTAssertTrue(message.contains("DAILY_IMAGE_LIMIT"), "应含后端 code,实际 \(message)")
    }

    func test_poll_exhaustion_fails_with_timeout() async {
        let stub = StubClient()
        stub.statusResponses = [.init(status: "generating", error: nil)]
        stub.contentResults = [.success((Self.jsonStatus("generating"), 202))]
        DailyImageStore.maxPolls = 3
        let store = DailyImageStore(client: stub)

        await store.load(request: request)

        guard case .failed(let message) = store.state else {
            return XCTFail("期望 failed,实际 \(store.state)")
        }
        XCTAssertTrue(message.contains("生成超时"), "应提示轮询超时,实际 \(message)")
        XCTAssertFalse(message.contains("HTTP"), "超时文案不应带伪 HTTP 状态码,实际 \(message)")
        XCTAssertEqual(stub.contentCalls, 3)
    }

    /// Live 客户端实际形态:非 2xx throw → 404 以 APIError.httpError 冒出,
    /// Store 需折回重派分支(否则该分支对 Live 永不可达)。
    func test_404_thrown_mid_poll_redispatches_then_ready() async {
        let stub = StubClient()
        // 首次 POST:generating;404 后重 POST:仍 generating → 继续轮询 → 200
        stub.statusResponses = [.init(status: "generating", error: nil)]
        stub.contentResults = [
            .failure(APIError.httpError(
                statusCode: 404, body: Self.jsonString("missing")
            )),                                            // Live 形态 throw 404 → 触发重派(POST 第 2 次)
            .success((Self.jsonStatus("generating"), 202)),
            .success((Self.pngBytes, 200)),
        ]
        let store = DailyImageStore(client: stub)

        await store.load(request: request)

        guard case .ready = store.state else { return XCTFail("期望重派后 ready,实际 \(store.state)") }
        XCTAssertEqual(stub.statusCalls, 2, "404 应触发一次重派 POST")
        XCTAssertEqual(stub.contentCalls, 3)
    }

    /// 协议允许的元组 404(宽容臂):同样走重派。
    func test_404_tuple_mid_poll_redispatches_then_ready() async {
        let stub = StubClient()
        stub.statusResponses = [.init(status: "generating", error: nil)]
        stub.contentResults = [
            .success((Self.jsonStatus("missing"), 404)),   // 元组 404 → 重派(POST 第 2 次)
            .success((Self.pngBytes, 200)),
        ]
        let store = DailyImageStore(client: stub)

        await store.load(request: request)

        guard case .ready = store.state else { return XCTFail("期望重派后 ready,实际 \(store.state)") }
        XCTAssertEqual(stub.statusCalls, 2, "404 应触发一次重派 POST")
        XCTAssertEqual(stub.contentCalls, 2)
    }

    /// 网络在飞时被取消(URLSession 表达为 URLError.cancelled,被 Live 包成
    /// APIError.networkError):保持 loading,不算失败(与 CancellationError 同语义)。
    func test_urlsession_cancellation_keeps_loading() async {
        let stub = StubClient()
        stub.statusResponses = [.init(status: "generating", error: nil)]
        stub.contentResults = [
            .failure(APIError.networkError(URLError(.cancelled)))
        ]
        let store = DailyImageStore(client: stub)

        await store.load(request: request)

        guard case .loading = store.state else {
            return XCTFail("网络取消应保持 loading,实际 \(store.state)")
        }
    }

    func test_unknown_status_fails_explicitly() async {
        let stub = StubClient()
        stub.statusResponses = [.init(status: "??? genie says ???", error: nil)]
        let store = DailyImageStore(client: stub)

        await store.load(request: request)

        guard case .failed(let message) = store.state else {
            return XCTFail("期望 failed,实际 \(store.state)")
        }
        XCTAssertTrue(message.contains("未知插画状态"), "契约漂移应显式暴露,实际 \(message)")
    }

    func test_date_string_format() {
        // 用本地时区构造当日日期:被测 formatter 按设备时区输出(与
        // DailyFortuneRequest.isoDateFormatter 同口径),断言只验证格式本身,
        // 不依赖跑测机器的时区(显式 UTC 构造会在负时区机器上挂)。
        var comp = DateComponents()
        comp.year = 2026; comp.month = 8; comp.day = 31
        let date = Calendar.current.date(from: comp)!
        XCTAssertEqual(DailyImageStore.dateString(date), "2026-08-31")
    }

    /// `{"status":"..."}` JSON body(202/404 响应体形态,对齐后端)。
    private static func jsonStatus(_ status: String) -> Data {
        jsonString(status).data(using: .utf8)!
    }

    private static func jsonString(_ status: String) -> String {
        #"{"status":"\#(status)"}"#
    }
}
