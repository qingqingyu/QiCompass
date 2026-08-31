import SwiftUI
import UIKit

// MARK: - DTO

/// S3:插画状态端点响应(POST /api/bazi/daily-fortune/image)。
/// `{"status": "ready"|"generating", "error": String?}`
struct DailyImageStatusDTO: Codable, Equatable {
    let status: String
    let error: String?
}

// MARK: - 窄协议(测试注入点)

protocol DailyImageAPIClient: Sendable {
    func dailyImageStatus(request: DailyFortuneRequest) async throws -> DailyImageStatusDTO
    func dailyImageContent(chartHash: String, targetDate: String) async throws -> (data: Data, statusCode: Int)
}

/// 适配层:任何 APIClient(Live/Mock)自动获得 DailyImageAPIClient 能力。
/// 不用 `extension APIClient: DailyImageAPIClient {}` 的协议间空一致性——
/// 编译器不接受其驱动的 any→any 存在类型转换(实测 Swift 5.x 报
/// "argument type 'any APIClient' does not conform"),闭包包装最稳。
struct AnyDailyImageAPIClient: DailyImageAPIClient {
    private let _status: @Sendable (DailyFortuneRequest) async throws -> DailyImageStatusDTO
    private let _content: @Sendable (String, String) async throws -> (data: Data, statusCode: Int)

    init(_ client: any APIClient) {
        self._status = { request in
            try await client.dailyImageStatus(request: request)
        }
        self._content = { chartHash, targetDate in
            try await client.dailyImageContent(chartHash: chartHash, targetDate: targetDate)
        }
    }

    func dailyImageStatus(request: DailyFortuneRequest) async throws -> DailyImageStatusDTO {
        try await _status(request)
    }

    func dailyImageContent(chartHash: String, targetDate: String) async throws -> (data: Data, statusCode: Int) {
        try await _content(chartHash, targetDate)
    }
}

// MARK: - 轮询超时错误

/// 轮询耗尽(非 HTTP 语义,不用 `APIError.httpError` 伪造 statusCode,
/// 否则用户文案会出现「HTTP 0: …」技术噪音)。
private struct ImageTimeoutError: LocalizedError {
    let maxPolls: Int

    var errorDescription: String? {
        "生成超时(\(maxPolls) 次轮询未就绪),请稍后重试"
    }
}

// MARK: - DailyImageStore

/// 每日运势插画加载器(S3,2026-08-30「一幅图」)。
///
/// 流程:NSCache 命中 → ready;否则 POST 状态端点(后端幂等:ready 直返 /
/// miss 派发生成)→ ready 则 GET content 取 PNG;generating 则 5s 间隔轮询
/// GET content(200 成图 / 202 继续 / 404 重派一次 / 409 failed·stale),
/// 上限 40 次(200s > 后端实测 181s 上界)。
///
/// 错误显式传播:任何失败落 `.failed(message)` 携原始信息——409 body 带
/// 后端 error_message(限额/上游错误),解析不出则透 APIError 描述,
/// 不静默换占位图(S0 静态样图已随 S3 退场)。
///
/// 取消语义:调用方 `.task {}` 挂载即得自动取消;轮询每 tick 查
/// `Task.isCancelled` 及时退出,取消保持 loading 态(非失败)——包括
/// 网络在飞时被取消(URLSession 以 `URLError.cancelled` 冒出,被
/// LiveAPIClient 包成 `APIError.networkError`,与 `CancellationError`
/// 分开判)。
@MainActor
final class DailyImageStore: ObservableObject {
    // MARK: 状态

    enum HeroImageState: Equatable {
        case loading
        case ready(UIImage)
        case failed(String)

        static func == (lhs: HeroImageState, rhs: HeroImageState) -> Bool {
            switch (lhs, rhs) {
            case (.loading, .loading): return true
            case let (.ready(a), .ready(b)): return a === b
            case let (.failed(a), .failed(b)): return a == b
            default: return false
            }
        }
    }

    @Published private(set) var state: HeroImageState = .loading

    // MARK: 节奏参数(测试注入加速)

    /// 轮询间隔(秒)。
    static var pollIntervalSeconds: TimeInterval = 5
    /// 轮询上限:40 × 5s = 200s(> 后端实测 181s 上界)。
    static var maxPolls = 40

    // MARK: 依赖

    private let client: DailyImageAPIClient
    /// "chartHash|yyyy-MM-dd" → UIImage 内存缓存(当日重复进出页秒回)。
    private let imageCache = NSCache<NSString, UIImage>()

    init(client: DailyImageAPIClient) {
        self.client = client
    }

    // MARK: - 加载

    /// 加载插画。幂等入口由视图层 `.task(id:)` 控制;内部先查内存缓存。
    func load(request: DailyFortuneRequest) async {
        let targetDate = Self.dateString(request.targetDate)
        let cacheKey = "\(request.chartHash)|\(targetDate)" as NSString

        state = .loading
        if let cached = imageCache.object(forKey: cacheKey) {
            state = .ready(cached)
            return
        }

        do {
            // 1) POST 状态(后端幂等:ready 直返 / miss 顺带派发生成)
            let status = try await client.dailyImageStatus(request: request)
            switch status.status {
            case "ready":
                try await fetchContent(request: request, cacheKey: cacheKey)
            case "generating":
                try await pollUntilReady(request: request, cacheKey: cacheKey)
            default:
                // 后端契约只有 ready/generating;其他值属契约漂移,显式暴露
                state = .failed("未知插画状态: \(status.status)")
            }
        } catch is CancellationError {
            // Task.sleep 处取消:保持 loading(视图随 task 重挂恢复),不属失败
        } catch APIError.networkError(let urlError) where urlError.code == .cancelled {
            // 网络在飞时取消(URLSession 把 Task 取消表达为 URLError.cancelled):
            // 与 CancellationError 同语义处理——否则旧 task 的取消会在新 task 置
            // .loading 后落地,把新一轮加载闪成上一轮的「失败」。
        } catch {
            state = .failed(Self.failureMessage(for: error))
            AppLogger.networking.error(
                "daily.image.load_failed chart_hash=\(request.chartHash, privacy: .public) date=\(targetDate, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - 内部

    /// targetDate 字符串键(yyyy-MM-dd,en_US_POSIX,与 GET query 及
    /// DailyFortuneRequest.isoDateFormatter 同口径)。DateFormatter 创建昂贵,
    /// static 复用(@MainActor 隔离下无并发问题)。
    private static let dateStringFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dateString(_ date: Date) -> String {
        dateStringFormatter.string(from: date)
    }

    private func fetchContent(request: DailyFortuneRequest, cacheKey: NSString) async throws {
        let (data, statusCode) = try await client.dailyImageContent(
            chartHash: request.chartHash, targetDate: Self.dateString(request.targetDate)
        )
        guard statusCode == 200 else {
            throw APIError.httpError(
                statusCode: statusCode,
                body: String(data: data, encoding: .utf8),
            )
        }
        try cacheAndPublish(pngData: data, cacheKey: cacheKey)
    }

    private func pollUntilReady(request: DailyFortuneRequest, cacheKey: NSString) async throws {
        let targetDate = Self.dateString(request.targetDate)
        for _ in 0..<Self.maxPolls {
            if Task.isCancelled { throw CancellationError() }
            try await Task.sleep(nanoseconds: UInt64(Self.pollIntervalSeconds * 1_000_000_000))

            let (data, statusCode) = try await getContentTolerating404(
                chartHash: request.chartHash, targetDate: targetDate
            )
            switch statusCode {
            case 200:
                try cacheAndPublish(pngData: data, cacheKey: cacheKey)
                return
            case 202:
                continue  // 仍在生成
            case 404:
                // 行被后端自愈删除(文件丢失)等:重派一次(幂等 POST)再继续
                let status = try await client.dailyImageStatus(request: request)
                if status.status == "ready" {
                    try await fetchContent(request: request, cacheKey: cacheKey)
                    return
                }
                continue
            default:
                // 409 failed/stale、429 限额、5xx:body 带 error_message
                throw APIError.httpError(
                    statusCode: statusCode,
                    body: String(data: data, encoding: .utf8),
                )
            }
        }
        throw ImageTimeoutError(maxPolls: Self.maxPolls)
    }

    /// GET content 并把 **throw 形态的 404** 折回 `(body, 404)` 元组。
    ///
    /// Live 客户端契约:非 2xx 一律 throw(`APIError.httpError`),202 以元组
    /// 返回;后端 404(无行 / 文件丢失自愈删行)属轮询可自愈分支,必须在此
    /// 显式折回,否则 `pollUntilReady` 的重派分支对 Live 永不可达。
    /// 其余 throw(409/429/5xx/网络错误)原样上抛。
    private func getContentTolerating404(
        chartHash: String, targetDate: String
    ) async throws -> (data: Data, statusCode: Int) {
        do {
            return try await client.dailyImageContent(chartHash: chartHash, targetDate: targetDate)
        } catch APIError.httpError(let statusCode, let body) where statusCode == 404 {
            return (body?.data(using: .utf8) ?? Data(), 404)
        }
    }

    /// PNG bytes → UIImage → 缓存 + 发布;解不开即显式抛错。
    private func cacheAndPublish(pngData: Data, cacheKey: NSString) throws {
        guard let image = UIImage(data: pngData) else {
            throw APIError.decodingError(
                NSError(
                    domain: "DailyImageStore", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "插画 bytes 非 UIImage 可解 (\(pngData.count) bytes)"]
                )
            )
        }
        imageCache.setObject(image, forKey: cacheKey)
        state = .ready(image)
    }

    // MARK: - 错误文案

    /// 提取用户可读信息:轮询超时透专用文案;后端 409 body JSON 带 error
    /// 字段;解析不出则透 APIError 的 errorDescription(含 HTTP 状态码),
    /// 不静默泛化。
    private static func failureMessage(for error: Error) -> String {
        if let timeout = error as? ImageTimeoutError {
            return timeout.errorDescription ?? "插画加载失败"
        }
        if let api = error as? APIError {
            if case let .httpError(_, body) = api,
               let body,
               let data = body.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String: String].self, from: data),
               let message = decoded["error"] {
                return message
            }
            return api.errorDescription ?? "插画加载失败"
        }
        return "插画加载失败:\(String(describing: error))"
    }
}
