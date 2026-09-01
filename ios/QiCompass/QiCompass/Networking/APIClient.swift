import Foundation

// MARK: - APIClient Protocol

/// API 客户端协议。协议化便于测试与占位:Mock 让三 Tab 在后端未运行时也有可调用路径。
protocol APIClient: Sendable {
    func health() async throws -> HealthResponse
    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse
    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse
    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse
    func interpret(request: InterpretRequest) async throws -> InterpretResponse
    func redeem(request: EntitlementRedeemRequest) async throws -> EntitlementRedeemResponse
    /// Slice 1:登录后批量拉当前 user 的全部 entitlement(跨设备 / 重装 / 退登回登同步)
    func entitlementList() async throws -> EntitlementListResponse
    /// PR2.5:Apple identity_token 换自家 JWT(后端验签 + upsert User + 发 JWT)
    func signIn(request: SignInRequest) async throws -> SignInResponse
    /// PR3.2:拉云端所有命盘(登录用户,全量)
    func syncPull() async throws -> SyncPullResponse
    /// PR3.2:上传本地命盘到云端(全量 UPSERT)
    func syncPush(request: SyncPushRequest) async throws -> SyncPushResponse
}

// MARK: - Shared JSONCoder

enum APICoder {
    /// 编码:所有 DTO 已有显式 CodingKeys 映射到 snake_case,**不用** convertToSnakeCase
    /// (convertToSnakeCase 会对 CodingKey stringValue 再做一次转换,可能 double-convert)。
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // ISO 8601 只作用于仍为 Date 类型的 DTO 字段(如 trueSolarTime)。
        // birth_datetime 是 S02 裸钟面字符串(yyyy-MM-dd'T'HH:mm:ss,无 offset,
        // 时区走 timezone 字段),不经此策略(S04 review 修正过时注释)。
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

/// 真实 API 客户端:async/await + URLSession,timeout 90s,显式 throws。
///
/// timeout 跟后端 AI_TIMEOUT_SECONDS=90 对齐:推理模型(gpt-5.x / claude-sonnet)
/// 生成命书 20-50s,之前 15s 会在后端返回前提前 timeout。
/// 不重试(脚手架阶段,重试策略留待各模块 slice)。
/// 返回 DTO,不直接返回 SwiftData @Model;DTO 与 @Model 转换由调用方显式映射。
final class LiveAPIClient: APIClient {
    private let session: URLSession
    private let baseURL: URL
    // v2 PR2:AccountManager weak 引用,避免 retain cycle(AppEnvironment 持两者)
    // 后端 PR2.5 已接 JWT 验签:Authorization 存在但验签失败会硬 401
    // (无 header 才走 user_local_id 兜底),所以只发自家 JWT,见 AccountManager token 策略
    weak var accountManager: AccountManager?

    init(baseURL: URL) {
        let config = URLSessionConfiguration.default
        // 跟后端 AI_TIMEOUT_SECONDS=90 对齐。推理模型生成命书 20-50s,
        // 15s 会在后端返回前提前 timeout。resource timeout 留 120s 容错。
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
        self.baseURL = baseURL
    }

    /// AppEnvironment 装配 AccountManager 后注入(运行时取 lastKnownJwtToken 加 Authorization header)。
    func setAccountManager(_ manager: AccountManager) {
        accountManager = manager
        AppLogger.networking.info("api.live.accountManager_injected")
    }

    func health() async throws -> HealthResponse {
        // GET 无 body
        let (data, _) = try await send(
            .health,
            body: nil as EmptyBody?,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
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

    func redeem(request: EntitlementRedeemRequest) async throws -> EntitlementRedeemResponse {
        let (data, _) = try await send(.entitlementRedeem, body: request)
        return try decode(data, as: EntitlementRedeemResponse.self, endpoint: .entitlementRedeem)
    }

    // Slice 1:GET /api/entitlement/list — 登录后批量拉 entitlement,跨设备同步用
    func entitlementList() async throws -> EntitlementListResponse {
        let (data, _) = try await send(.entitlementList, body: nil as EmptyBody?)
        return try decode(data, as: EntitlementListResponse.self, endpoint: .entitlementList)
    }

    // PR2.5:Apple identity_token → 自家 JWT(后端验签 + upsert User + 发 access_token)
    func signIn(request: SignInRequest) async throws -> SignInResponse {
        let (data, _) = try await send(.authSignIn, body: request)
        return try decode(data, as: SignInResponse.self, endpoint: .authSignIn)
    }

    // PR3.2:拉云端命盘
    func syncPull() async throws -> SyncPullResponse {
        let (data, _) = try await send(.syncPull, body: EmptyBody())
        return try decode(data, as: SyncPullResponse.self, endpoint: .syncPull)
    }

    // PR3.2:上传本地命盘到云端
    func syncPush(request: SyncPushRequest) async throws -> SyncPushResponse {
        let (data, _) = try await send(.syncPush, body: request)
        return try decode(data, as: SyncPushResponse.self, endpoint: .syncPush)
    }

    // MARK: - Internal

    private struct EmptyBody: Codable {}

    /// 统一发送:编码 body → 构造 URLRequest → 发送 → 检查 HTTP 状态。
    /// 错误显式传播:网络错误 / HTTP 错误 / 后端结构化错误 全部 throw,不吞。
    ///
    /// 日志策略(用户规则 2 + 3):start/ok 都打 info,所有 fail 打 error。
    /// 一个 send 调用对应一对 start/ok 或 start/fail,不会缺漏。
    private func send<Body: Codable>(
        _ endpoint: APIEndpoint,
        body: Body?,
        cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
    ) async throws -> (Data, HTTPURLResponse) {
        let url = endpoint.url(base: baseURL)
        var req = URLRequest(url: url)
        req.cachePolicy = cachePolicy
        req.httpMethod = endpoint.method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // v2 PR2:从 AccountManager 取 lastKnownJwtToken(只承载自家 JWT,已登录且 exchange 成功时注入)
        // 用 nonisolated(unsafe) 属性避免 main actor 切换(APIClient.send 可能在 background 线程)
        // 后端会验签:过期 / 非法 token 硬 401,无 header 才走 user_local_id 兜底
        if let token = accountManager?.lastKnownJwtToken {
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
        // 规则 3:第三方接口调起日志(每个 endpoint 进入网络栈前打)
        AppLogger.networking.info("api.call.start endpoint=\(endpoint.path, privacy: .public) method=\(endpoint.method, privacy: .public)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError {
            let elapsed = start.duration(to: .now)
            let elapsedMs = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            AppLogger.networking.error("network failed endpoint=\(endpoint.path, privacy: .public) elapsed_ms=\(elapsedMs, privacy: .public) error=\(String(describing: urlError), privacy: .public)")
            throw APIError.networkError(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            // 非预期:URLSession 返回非 HTTP 响应(理论上不会发生,但显式报错)
            AppLogger.networking.error("api.cast_http_failed endpoint=\(endpoint.path, privacy: .public) response_type=\(String(describing: type(of: response)), privacy: .public)")
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
            AppLogger.networking.error("http error endpoint=\(endpoint.path, privacy: .public) status=\(http.statusCode) body=\(bodyString?.prefix(200) ?? "nil", privacy: .public)")
            throw APIError.httpError(statusCode: http.statusCode, body: bodyString)
        }

        let elapsed = start.duration(to: .now)
        let elapsedMs = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        // 规则 3:第三方接口成功返回日志(含 elapsed 便于排查慢请求)
        AppLogger.networking.info("api.call.ok endpoint=\(endpoint.path, privacy: .public) status=\(http.statusCode) elapsed_ms=\(elapsedMs, privacy: .public)")
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
        AppLogger.networking.debug("mock.health 调起")
        try? await Task.sleep(nanoseconds: 200_000_000)
        return HealthResponse(
            status: "ok",
            lunarPythonVersion: "1.4.8-mock",
            model: "bazi-calculate-v1-mock",
            aiProvider: "anthropic",
            aiModel: "mock-anthropic-model"
        )
    }

    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        AppLogger.networking.debug("mock.calculateBazi 调起 birth_datetime=\(request.birthDatetime, privacy: .public) tz=\(request.timezone, privacy: .public)")
        try? await Task.sleep(nanoseconds: 300_000_000)
        return try Self.mockBaziResponse(for: request)
    }

    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse {
        AppLogger.networking.debug("mock.compatibility 调起 personAHash=\(request.personAHash.prefix(12), privacy: .public) personBProvided=\(String(describing: request.personB != nil), privacy: .public)")
        try? await Task.sleep(nanoseconds: 300_000_000)
        return try Self.mockCompatibilityResponse(for: request)
    }

    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse {
        AppLogger.networking.debug("mock.dailyFortune 调起 chart_hash=\(request.chartHash.prefix(12), privacy: .public) target_date=\(request.targetDate.description, privacy: .public)")
        try? await Task.sleep(nanoseconds: 300_000_000)
        return Self.mockDailyFortuneResponse(for: request)
    }



    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        AppLogger.networking.debug("mock.interpret 调起 content_hash=\(request.contentHash.prefix(12), privacy: .public) module=\(request.module, privacy: .public)")
        try? await Task.sleep(nanoseconds: 400_000_000)
        return InterpretResponse(
            interpretation: "[Mock 命书占位] 此命造五行流转,日主得令,喜忌已由后端确定性规则引擎判定。此为脚手架阶段 Mock 文本,正式解读由后端 AI provider 生成。",
            promptVersion: 1,
            cached: false,
            generatedAt: .now,
            provider: "anthropic",
            model: "mock-anthropic-model",
            language: AppLanguage.current  // i18n:mock 跟随系统语言,演示双语能力
        )
    }

    func redeem(request: EntitlementRedeemRequest) async throws -> EntitlementRedeemResponse {
        AppLogger.networking.debug("mock.redeem 调起 tx=\(request.transactionId, privacy: .public) product=\(request.productId, privacy: .public)")
        try? await Task.sleep(nanoseconds: 300_000_000)
        // Mock 永远返回成功(M3b 接真 SDK 时,真实流程在 PurchaseManager 里实现)
        return EntitlementRedeemResponse(
            entitled: true,
            transactionId: request.transactionId,
            purchasedAt: .now,
            originalPurchaseDate: .now
        )
    }

    // Slice 1:Mock 返空列表(Mock 模式后端不存在,SyncManager 跳过同步)
    func entitlementList() async throws -> EntitlementListResponse {
        AppLogger.networking.debug("mock.entitlementList 返空")
        try? await Task.sleep(nanoseconds: 100_000_000)
        return EntitlementListResponse(entitlements: [])
    }

    // PR2.5:Mock sign-in 返 fake JWT(测试用,不真调后端 /api/auth/sign-in)
    func signIn(request: SignInRequest) async throws -> SignInResponse {
        AppLogger.networking.debug("mock.signIn 调起 token_prefix=\(request.identityToken.prefix(20), privacy: .public)")
        try? await Task.sleep(nanoseconds: 200_000_000)
        return SignInResponse(
            accessToken: "mock.jwt.\(UUID().uuidString.prefix(8))",
            tokenType: "Bearer",
            userId: "mock-user-\(UUID().uuidString.prefix(8))",
            expiresAt: "2099-12-31T00:00:00+00:00"
        )
    }

    // PR3.2:Mock sync 返空(Mock 模式下后端不存在,返空让 SyncManager 跳过合并)
    func syncPull() async throws -> SyncPullResponse {
        AppLogger.networking.debug("mock.syncPull 返空 charts")
        try? await Task.sleep(nanoseconds: 100_000_000)
        return SyncPullResponse(userId: "mock-user", charts: [])
    }

    func syncPush(request: SyncPushRequest) async throws -> SyncPushResponse {
        AppLogger.networking.debug("mock.syncPush 调起 count=\(request.charts.count, privacy: .public)")
        try? await Task.sleep(nanoseconds: 100_000_000)
        return SyncPushResponse(
            userId: "mock-user",
            upsertedCount: request.charts.count,
            totalCount: request.charts.count
        )
    }

    /// mock helper:裸钟面字符串 → Date(设备时区解释;仅 mock 展示,
    /// 真实钟面→绝对时刻解释在后端 zoneinfo,S02 契约)。
    private static func mockWallDate(_ wall: String) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.date(from: wall)
    }

    /// S03 起 throws:钟面字符串解析失败显式抛错(错误显式传播),不再 `?? .now` 静默兜底——
    /// birthDate Optional 化后字符串由 VM combinedBirthDate 保证非空合成,解析失败=上游 bug,须暴露。
    private static func mockBaziResponse(for req: BaziCalculateRequest) throws -> BaziResponse {
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
            trueSolarLongitude: req.longitude, trueSolarOffsetMinutes: -14.4,
            schemaVersion: 1, birthTimezone: req.timezone,
            // S04 契约镜像:后端 calc_rule_snapshot 恒回 hour_known,mock 同步回显
            hourKnown: req.hourKnown
        )
        // mock 真太阳时 = 钟面字符串解析回 Date(naive → 设备时区解释,仅 mock 展示用);
        // 解析失败显式抛错(错误显式传播,禁止 .now 静默兜底)
        guard let mockSolarDate = Self.mockWallDate(req.birthDatetime) else {
            throw UserFacingError.generic(message: "mock 真太阳时解析失败(钟面字符串非法): \(req.birthDatetime)")
        }
        // contentHash 用确定性输入拼 itself(String.hashValue 每进程随机种子,跨启动会变)
        return BaziResponse(
            contentHash: "mock_\(req.birthDatetime)_\(req.timezone)_\(req.longitude)",
            trueSolarTime: mockSolarDate,
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
            boundaryWarning: nil,
            yearBranchZodiac: "Rat",  // mock 主盘 pillar.zhi=子 → Rat(对齐 mock 数据)
            yearBranchFriends: ["Ox", "Dragon", "Monkey"],  // 子:六合丑 + 三合申辰
            yearBranchClash: "Horse"  // 子午冲
        )
    }

    /// 合盘 mock:模式 A 不返 personBChart(B 从本地存档渲染);模式 B 返 personBChart(后端现排)。
    /// 双盘定性评估固定为「互补佳 / 同气 / 六合 / 无冲无刑」,3 年流年同步表固定。
    /// S03 起 throws:personB 钟面解析失败显式抛错(对齐 mockBaziResponse,禁止 .now 静默兜底)。
    private static func mockCompatibilityResponse(
        for req: CompatibilityRequest
    ) throws -> CompatibilityResponse {
        let calcRule = CalcRuleSnapshotDTO(
            library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
            trueSolarLongitude: 116.4, trueSolarOffsetMinutes: -14.4, schemaVersion: 1
        )

        // 模式 B:构造一个独立的 B 盘响应(供客户端隐式落地 + UI 渲染)
        let personBChart: BaziResponse?
        if let personB = req.personB {
            // 钟面字符串解析失败显式抛错(错误显式传播,禁止 .now 静默兜底)
            guard let personBSolarTime = Self.mockWallDate(personB.birthDatetime) else {
                throw UserFacingError.generic(message: "mock 合盘 B 盘真太阳时解析失败(钟面字符串非法): \(personB.birthDatetime)")
            }
            let pillar = PillarDTO(
                ganZhi: "丙午", gan: "丙", zhi: "午",
                ganElement: "fire", zhiElement: "fire",
                hideGan: ["丁", "己"], shishenGan: "食神", shishenZhi: ["劫财", "伤官"],
                nayin: "天河水", dishi: "帝旺", xunkong: "寅卯"
            )
            let pillars = PillarsDTO(year: pillar, month: pillar, day: pillar, hour: pillar)
            let ganzhi = GanZhiNaYinDTO(ganZhi: "丙午", nayin: "天河水")
            let balance = ElementBalanceDTO(wood: 1, fire: 3, earth: 1, metal: 1, water: 2)
            personBChart = BaziResponse(
                contentHash: "mock_b_\(req.personB?.birthDatetime ?? "nil")_\(req.personB?.timezone ?? "")",
                trueSolarTime: personBSolarTime,
                trueSolarOffsetMinutes: -14.4,
                pillars: pillars,
                mingGong: ganzhi, shenGong: ganzhi, taiYuan: ganzhi,
                elementBalance: balance,
                favorableElements: ["火", "土"], unfavorableElements: ["水"],
                dayMasterStrength: "strong", tiaoshouApplied: false,
                xijiMethod: "扶抑", patternHint: nil,
                shensha: [],
                luckPillars: [LuckPillarDTO(ganZhi: "丙午", startYear: 2000, endYear: 2009, startAge: 10, endAge: 19)],
                currentLuckPillar: nil, currentYearPillar: nil, currentDayPillar: nil, currentHourPillar: nil,
                calcRuleSnapshot: calcRule,
                boundaryWarning: nil,
                yearBranchZodiac: "Horse",  // mock B 盘 pillar.zhi=午 → Horse(对齐 mock 数据)
                yearBranchFriends: ["Goat", "Tiger", "Dog"],  // 午:六合未 + 三合寅戌
                yearBranchClash: "Rat"  // 子午冲
            )
        } else {
            personBChart = nil
        }

        let assessment = QualitativeAssessmentDTO(
            fiveElements: "互补佳",
            dayMasterRelation: "同气",
            zodiacMatch: "六合",
            branchHarmony: "无冲无刑"
        )

        let currentYear = Calendar.current.component(.year, from: .now)
        let synced: [SyncedFortuneDTO] = (0..<3).map { offset in
            SyncedFortuneDTO(
                year: currentYear + offset,
                personA: "甲子运 \(currentYear + offset)年",
                personB: "丙午运 \(currentYear + offset)年",
                sync: offset == 0 ? "同步走强" : (offset == 1 ? "运势分化" : "难以定性")
            )
        }

        // 合盘 hash:简单用 personAHash + (personBHash ?? personB?.birthDatetime) + context 拼接
        let bKey = req.personBHash ?? "tmp_\(req.personB?.birthDatetime ?? "nil")"
        let compatibilityHash = "mock_compat_\(req.personAHash)_\(bKey)_\(req.context)"

        return CompatibilityResponse(
            compatibilityHash: compatibilityHash,
            personAChart: nil,
            personBChart: personBChart,
            qualitativeAssessment: assessment,
            syncedFortune: synced,
            calcRuleSnapshot: calcRule
        )
    }

    /// 每日运势 mock:生成 12 时辰固定数据 + 当日柱。
    /// 用 Calendar 算 target_date 对应的日柱(避免依赖后端 mock 数据完整)。
    private static func mockDailyFortuneResponse(
        for req: DailyFortuneRequest
    ) -> DailyFortuneResponse {
        let dayStem = "甲"
        let dayBranch = "子"
        let dayPillar = "\(dayStem)\(dayBranch)"

        let hourNames = ["子", "丑", "寅", "卯", "辰", "巳",
                          "午", "未", "申", "酉", "戌", "亥"]
        let timeRanges = ["23:00-01:00", "01:00-03:00", "03:00-05:00",
                           "05:00-07:00", "07:00-09:00", "09:00-11:00",
                           "11:00-13:00", "13:00-15:00", "15:00-17:00",
                           "17:00-19:00", "19:00-21:00", "21:00-23:00"]
        let relations = ["比肩", "劫财", "食神", "伤官", "偏财", "正财",
                          "七杀", "正官", "偏印", "正印", "比肩", "劫财"]
        let stems = ["甲", "乙", "丙", "丁", "戊", "己",
                      "庚", "辛", "壬", "癸", "甲", "乙"]

        let hourPillars: [HourPillarDTO] = (0..<12).map { idx in
            HourPillarDTO(
                hour: hourNames[idx],
                timeRange: timeRanges[idx],
                pillar: "\(stems[idx])\(hourNames[idx])",
                relation: relations[idx],
                chong: nil,
                chongTargets: [],
            )
        }

        let tomorrow = TomorrowPreviewDTO(
            dayPillar: "乙丑", dayRelation: "劫财", dayChong: nil,
        )
        let calcRule = CalcRuleSnapshotDTO(
            library: "lunar_python 1.4.8 (mock)", sect: 1,
            ziHourRule: "client_decided",
            trueSolarLongitude: 0, trueSolarOffsetMinutes: 0,
            schemaVersion: 1,
        )
        return DailyFortuneResponse(
            dayPillar: dayPillar,
            dayRelationToDayMaster: "比肩",
            dayChong: "午",
            dayChongTargets: [],
            hourPillars: hourPillars,
            currentHourIndex: nil,
            lunarDate: "六月廿八(mock)",
            huangliYi: ["祭祀", "祈福", "求嗣", "开光"],
            huangliJi: ["嫁娶", "栽种"],
            tomorrowPreview: tomorrow,
            calcRuleSnapshot: calcRule,
        )
    }
}
