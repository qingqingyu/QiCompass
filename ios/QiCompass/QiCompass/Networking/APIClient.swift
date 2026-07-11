import Foundation

// MARK: - APIClient Protocol

/// API 客户端协议。协议化便于测试与占位:Mock 让三 Tab 在后端未运行时也有可调用路径。
protocol APIClient: Sendable {
    func health() async throws -> HealthResponse
    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse
    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse
    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse
    func interpret(request: InterpretRequest) async throws -> InterpretResponse
}

// MARK: - Shared JSONCoder

enum APICoder {
    /// 编码:所有 DTO 已有显式 CodingKeys 映射到 snake_case,**不用** convertToSnakeCase
    /// (convertToSnakeCase 会对 CodingKey stringValue 再做一次转换,可能 double-convert)。
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // ISO 8601 with timezone(对齐后端 birth_datetime offset-aware 要求)
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    /// 解码:所有 DTO 已有显式 CodingKeys 映射到 snake_case,**不用** convertFromSnakeCase
    /// (convertFromSnakeCase 会把 JSON 的 snake_case key 转成 camelCase 再查 CodingKey,
    ///  与 CodingKey 的 snake_case stringValue 冲突,导致解码失败)。
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - LiveAPIClient

/// 真实 API 客户端:async/await + URLSession,timeout 15s,显式 throws。
///
/// 不重试(脚手架阶段,重试策略留待各模块 slice)。
/// 返回 DTO,不直接返回 SwiftData @Model;DTO 与 @Model 转换由调用方显式映射。
final class LiveAPIClient: APIClient {
    private let session: URLSession
    private let baseURL: URL
    private let bearerToken: String?

    init(baseURL: URL, bearerToken: String? = nil) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
        self.baseURL = baseURL
        // 脚手架阶段:Bearer Token 暂用传入参数占位(正式 slice 替换为 Keychain)。
        // TODO: 账号 slice 引入 Keychain 封装(需先征得依赖同意)。
        self.bearerToken = bearerToken
    }

    func health() async throws -> HealthResponse {
        // GET 无 body
        let (data, _) = try await send(.health, body: nil as EmptyBody?)
        return try decode(data, as: HealthResponse.self, endpoint: .health)
    }

    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        let (data, _) = try await send(.baziCalculate, body: request)
        return try decode(data, as: BaziResponse.self, endpoint: .baziCalculate)
    }

    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse {
        let (data, _) = try await send(.compatibility, body: request)
        return try decode(data, as: CompatibilityResponse.self, endpoint: .compatibility)
    }

    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse {
        let (data, _) = try await send(.dailyFortune, body: request)
        return try decode(data, as: DailyFortuneResponse.self, endpoint: .dailyFortune)
    }

    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        let (data, _) = try await send(.interpret, body: request)
        return try decode(data, as: InterpretResponse.self, endpoint: .interpret)
    }

    // MARK: - Internal

    private struct EmptyBody: Codable {}

    /// 统一发送:编码 body → 构造 URLRequest → 发送 → 检查 HTTP 状态。
    /// 错误显式传播:网络错误 / HTTP 错误 / 后端结构化错误 全部 throw,不吞。
    private func send<Body: Codable>(
        _ endpoint: APIEndpoint,
        body: Body?
    ) async throws -> (Data, HTTPURLResponse) {
        let url = baseURL.appendingPathComponent(endpoint.path)
        var req = URLRequest(url: url)
        req.httpMethod = endpoint.method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = bearerToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body {
            do {
                req.httpBody = try APICoder.encoder.encode(body)
            } catch {
                AppLogger.networking.error("encode failed endpoint=\(endpoint.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
                throw APIError.encodingError(error)
            }
        }

        let start = ContinuousClock().now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError {
            let elapsed = start.duration(to: .now)
            AppLogger.networking.error("network failed endpoint=\(endpoint.path, privacy: .public) elapsed=\(elapsed) error=\(urlError.localizedDescription, privacy: .public)")
            throw APIError.networkError(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.httpError(statusCode: -1, body: nil)
        }

        if !(200..<300).contains(http.statusCode) {
            // 尝试解码后端 {error:{...}} 结构,失败则原样返回 body 字符串
            if let errorResponse = try? APICoder.decoder.decode(ErrorResponseDTO.self, from: data) {
                let body = errorResponse.error
                AppLogger.networking.error("backend error endpoint=\(endpoint.path, privacy: .public) status=\(http.statusCode) code=\(body.code, privacy: .public) request_id=\(body.requestId ?? "nil", privacy: .public)")
                throw APIError.backendError(
                    code: body.code,
                    message: body.message,
                    requestId: body.requestId
                )
            }
            let bodyString = String(data: data, encoding: .utf8)
            AppLogger.networking.error("http error endpoint=\(endpoint.path, privacy: .public) status=\(http.statusCode) body=\(bodyString ?? "nil", privacy: .public)")
            throw APIError.httpError(statusCode: http.statusCode, body: bodyString)
        }

        return (data, http)
    }

    /// 统一解码:失败 throw .decodingError,携带原始 error。
    private func decode<T: Decodable>(_ data: Data, as type: T.Type, endpoint: APIEndpoint) throws -> T {
        do {
            return try APICoder.decoder.decode(T.self, from: data)
        } catch {
            AppLogger.networking.error("decode failed endpoint=\(endpoint.path, privacy: .public) error=\(String(describing: error), privacy: .public)")
            throw APIError.decodingError(error)
        }
    }
}

// MARK: - MockAPIClient

/// Mock API 客户端:返回占位数据,让三 Tab 在后端未运行时有可调用路径。
/// Debug 默认用 Mock,可手动切换 LiveAPIClient 验证真实链路。
final class MockAPIClient: APIClient {
    func health() async throws -> HealthResponse {
        try? await Task.sleep(nanoseconds: 200_000_000)
        return HealthResponse(status: "ok", lunarPythonVersion: "1.4.8-mock", model: "bazi-calculate-v1-mock")
    }

    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        try? await Task.sleep(nanoseconds: 300_000_000)
        return Self.mockBaziResponse(for: request)
    }

    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse {
        try? await Task.sleep(nanoseconds: 300_000_000)
        // stub:后端未实现,Mock 返回最小占位
        throw APIError.backendError(
            code: "NOT_IMPLEMENTED",
            message: "合盘端点尚未实现(后端 stub)",
            requestId: nil
        )
    }

    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse {
        try? await Task.sleep(nanoseconds: 300_000_000)
        throw APIError.backendError(
            code: "NOT_IMPLEMENTED",
            message: "每日运势端点尚未实现(后端 stub)",
            requestId: nil
        )
    }

    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        try? await Task.sleep(nanoseconds: 400_000_000)
        return InterpretResponse(
            interpretation: "[Mock 命书占位] 此命造五行流转,日主得令,喜忌已由后端确定性规则引擎判定。此为脚手架阶段 Mock 文本,正式解读由后端调用 Claude 生成。",
            promptVersion: 1,
            cached: false,
            generatedAt: .now
        )
    }

    private static func mockBaziResponse(for req: BaziCalculateRequest) -> BaziResponse {
        let pillar = PillarDTO(
            ganZhi: "甲子", gan: "甲", zhi: "子",
            ganElement: "wood", zhiElement: "water",
            hideGan: ["癸"], shishenGan: "比肩", shishenZhi: ["正印"],
            nayin: "海中金", dishi: "沐浴", xunkong: "戌亥"
        )
        let pillars = PillarsDTO(year: pillar, month: pillar, day: pillar, hour: pillar)
        let ganzhi = GanZhiNaYinDTO(ganZhi: "甲子", nayin: "海中金")
        let balance = ElementBalanceDTO(wood: 2, fire: 1, earth: 1, metal: 1, water: 3)
        let calcRule = CalcRuleSnapshotDTO(
            library: "lunar_python", sect: 1, ziHourRule: req.ziHourRule,
            trueSolarLongitude: 116.4, trueSolarOffsetMinutes: -14.4, schemaVersion: 1
        )
        return BaziResponse(
            contentHash: "mock_\(req.birthDatetime.timeIntervalSince1970)",
            trueSolarTime: req.birthDatetime,
            trueSolarOffsetMinutes: -14.4,
            pillars: pillars,
            mingGong: ganzhi, shenGong: ganzhi, taiYuan: ganzhi,
            elementBalance: balance,
            favorableElements: ["木", "水"], unfavorableElements: ["土"],
            dayMasterStrength: "balanced", tiaoshouApplied: false,
            xijiMethod: "扶抑+调候", patternHint: nil,
            shensha: [],
            luckPillars: [LuckPillarDTO(ganZhi: "甲子", startYear: 1990, endYear: 1999, startAge: 1, endAge: 10)],
            currentLuckPillar: nil, currentYearPillar: nil, currentDayPillar: nil, currentHourPillar: nil,
            calcRuleSnapshot: calcRule,
            boundaryWarning: nil
        )
    }
}
