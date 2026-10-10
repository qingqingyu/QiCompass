import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import QiCompass

/// 2026-09-24 失败降级拍板(slice 1)VM 半边测试:
/// - **自动失败 → 一次静默重试**:进入即自动生成(09-07 拍板)失败后,保持
///   `.failed`(UI 显示引擎模板文案)+ `isSilentRetrying=true`,延迟后重发
///   interpret;重试成功转 `.okFree`
/// - **静默重试也失败 → 终态**:不再循环(恰好 2 次调用),`isSilentRetrying`
///   归 false,恢复交还给用户下拉刷新(2026-10-06 起 Retry 按钮已移除)
/// - **手动重试失败不调度静默重试**(用户正看着,再静默转圈只会困惑)
/// - **引擎模板表**:十神 10 键三语全量非空(防词表漂移丢键)+ fallback 非空
@MainActor
final class DailyFortuneFailureFallbackTests: XCTestCase {

    private var container: ModelContainer!
    private var chartStore: ChartSnapshotStore!
    private var dailyStore: DailyFortuneSnapshotStore!
    private var interpretStore: InterpretationCacheStore!
    private var orchestrator: DailyFortuneOrchestrator!
    private var api: FailingInterpretAPIClient!
    /// L5 门控测试用(耗尽共享池;隔离 suite)
    private var counter: DailyReadCounter!
    private var vm: DailyFortuneViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        chartStore = ChartSnapshotStore(context: context)
        dailyStore = DailyFortuneSnapshotStore(context: context)
        api = FailingInterpretAPIClient()
        interpretStore = InterpretationCacheStore(context: context)
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: api),
            cacheStore: interpretStore
        )
        counter = DailyReadCounter.makeIsolatedForTesting()
        orchestrator = DailyFortuneOrchestrator(
            apiClient: api,
            dailyStore: dailyStore,
            interpretStore: interpretStore,
            chartStore: chartStore,
            counter: counter,
            interpretationReader: reader
        )
        vm = DailyFortuneViewModel(
            orchestrator: orchestrator,
            chartStore: chartStore,
            dailyStore: dailyStore
        )
    }

    override func tearDownWithError() throws {
        vm = nil
        api = nil
        orchestrator = nil
        interpretStore = nil
        dailyStore = nil
        chartStore = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - 测试夹具

    private static func makePillar() -> PillarDTO {
        PillarDTO(
            ganZhi: "甲子", gan: "甲", zhi: "子",
            ganElement: "wood", zhiElement: "water",
            hideGan: ["癸"], shishenGan: "比肩", shishenZhi: ["正印"],
            nayin: "海中金", dishi: "沐浴", xunkong: "戌亥"
        )
    }

    /// 已知时辰的完整盘(本文只测 interpret 失败链路,排盘侧固定走 happy path)。
    /// favorableElements 可注入(重签 payload 重建用例:模拟规则演化翻转喜忌)。
    private static func makeResponse(
        hash: String, favorableElements: [String] = ["木", "水"]
    ) -> BaziResponse {
        let pillar = makePillar()
        let ganzhi = GanZhiNaYinDTO(ganZhi: "甲子", nayin: "海中金")
        return BaziResponse(
            contentHash: hash,
            trueSolarTime: nil,
            trueSolarOffsetMinutes: 0,
            pillars: PillarsDTO(
                year: pillar, month: pillar, day: pillar, hour: pillar
            ),
            mingGong: ganzhi, shenGong: ganzhi, taiYuan: ganzhi,
            elementBalance: ElementBalanceDTO(wood: 2, fire: 1, earth: 1, metal: 1, water: 3),
            favorableElements: favorableElements,
            unfavorableElements: ["土"],
            dayMasterStrength: "balanced",
            tiaoshouApplied: false,
            xijiMethod: "扶抑+调候", patternHint: nil,
            shensha: [], luckPillars: [],
            currentLuckPillar: nil, currentYearPillar: nil,
            currentDayPillar: nil, currentHourPillar: nil,
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1, birthTimezone: "Asia/Shanghai",
                hourKnown: true, pillarAmbiguity: nil
            ),
            boundaryWarning: nil,
            yearBranchZodiac: "Rat",
            yearBranchFriends: ["Ox"], yearBranchClash: "Horse"
        )
    }

    @discardableResult
    private func seedChart(hash: String) throws -> BaziResponse {
        let response = Self.makeResponse(hash: hash)
        let request = BaziCalculateRequest(
            birthDatetime: "1990-03-15T12:00:00",
            timezone: "Asia/Shanghai",
            gender: "male",
            longitude: 116.4074,
            latitude: 39.9042,
            placeName: "北京",
            geonameId: 1816670,
            ziHourRule: "zi_next_day",
            hourKnown: true
        )
        _ = try chartStore.upsert(response: response, request: request)
        return response
    }

    /// 轮询等待(VM 全异步 Task,与 HourUnknownGateTests 同款手法)。
    /// 闭包可 async(轮询 actor 双打的计数)。
    private func waitFor(
        _ match: @escaping () async -> Bool, timeout: TimeInterval = 8
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await match() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return await match()
    }

    private static func isFailed(_ state: DailyFortuneViewState) -> Bool {
        if case .ready(_, .failed, _) = state { return true }
        return false
    }

    private static func isContextTokenExpired(_ state: DailyFortuneViewState) -> Bool {
        if case .ready(_, .contextTokenExpired, _) = state { return true }
        return false
    }

    private static func isOkFree(_ state: DailyFortuneViewState) -> Bool {
        if case .ready(_, .okFree, _) = state { return true }
        return false
    }

    // MARK: - 2026-10-07 P0 收口补丁:老快照无 token 不得命中缓存

    /// 独立每日响应夹具(默认无 token = 模拟 security 收口前老后端产物)。
    private static func makeDailyResponse(contextToken: String?) -> DailyFortuneResponse {
        DailyFortuneResponse(
            dayPillar: "丙子",
            dayRelationToDayMaster: "偏印",
            dayChong: nil,
            dayChongTargets: [],
            hourPillars: [
                HourPillarDTO(
                    hour: "子", timeRange: "23:00-01:00",
                    pillar: "甲子", relation: "偏印", chong: nil, chongTargets: []
                )
            ],
            currentHourIndex: nil,
            lunarDate: "七月初十",
            huangliYi: ["出行"],
            huangliJi: ["动土"],
            tomorrowPreview: TomorrowPreviewDTO(
                dayPillar: "丁丑", dayRelation: "正印", dayChong: nil
            ),
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1
            ),
            contextToken: contextToken
        )
    }

    func test老快照无token_视为miss_落穿后端重签并覆盖自愈() async throws {
        try seedChart(hash: "daily_token_refresh")
        let businessDate = Date.now
        // 预置「security 收口前」的当日快照:新鲜(cachedUntil 未过)但无 token
        try dailyStore.upsert(
            chartHash: "daily_token_refresh",
            targetDate: businessDate,
            response: Self.makeDailyResponse(contextToken: nil),
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: businessDate)
        )
        await api.setDailyFortuneToken("v1.newly-signed-token")

        let (response, fromCache) = try await orchestrator.runDeterministic(
            chartHash: "daily_token_refresh",
            ziHourRule: "zi_next_day",
            businessDate: businessDate
        )
        XCTAssertFalse(fromCache, "无 token 快照必须视为 miss 落穿后端(否则 interpret 阶段 403 全天死锁)")
        XCTAssertEqual(response.contextToken, "v1.newly-signed-token")
        let calls = await api.dailyFortuneAttempts()
        XCTAssertEqual(calls, 1, "恰好一次后端调用(重签)")

        // 覆盖自愈:快照已带上新 token,后续命中走正常路径
        let refreshed = try dailyStore.getCachedIfFresh(
            chartHash: "daily_token_refresh", targetDate: businessDate
        )
        XCTAssertEqual(refreshed?.contextToken, "v1.newly-signed-token")

        let (_, cachedSecond) = try await orchestrator.runDeterministic(
            chartHash: "daily_token_refresh",
            ziHourRule: "zi_next_day",
            businessDate: businessDate
        )
        XCTAssertTrue(cachedSecond, "token 就位后恢复正常缓存命中")
        let callsAfterSecond = await api.dailyFortuneAttempts()
        XCTAssertEqual(callsAfterSecond, 1, "命中后不得再打后端")
    }

    // MARK: - 老盘自动重签(附八拍板②;2026-10-10 起仅失效期 403 重签重试,
    // 加载期 ensure 已删:「有入参却缺 token」的快照在生产不可达——token
    // 上线 10-07 早于补存排盘入参 10-08)

    /// 加载期不再重签(行为锁定):无 token 老盘(理论不可达防御面)→ 零
    /// 排盘调用直发 daily 请求,token 缺席由后端 403 → 失效期重签兜底
    /// (下一条用例);mock 后端不校验 token 时首调即成功。
    func test老盘无chartToken_加载期不重签_直发请求() async throws {
        try seedChart(hash: "daily_resign_a")
        await api.setDailyFortuneToken("daily-t1")

        let (response, fromCache) = try await orchestrator.runDeterministic(
            chartHash: "daily_resign_a",
            ziHourRule: "zi_next_day",
            businessDate: Date.now
        )
        XCTAssertFalse(fromCache)
        XCTAssertEqual(response.contextToken, "daily-t1")
        let calcCalls = await api.calculateAttempts()
        XCTAssertEqual(calcCalls, 0, "加载期重签已删,不得白发排盘请求")
        let requests = await api.recordedDailyFortuneRequests()
        XCTAssertNil(
            requests.first?.contextToken,
            "快照无 token → 首调直发(nil);403 兜底走失效期重签"
        )
    }

    /// 失效期:chart token 在档但被服务端拒(403)→ 静默重签 chart token 后
    /// 恰好重试一次成功;重试的 chartPayload 随新 token **一并重建**
    /// (2026-10-10 外评 #6:规则演化下同 hash 派生字段可能已变,新 token
    /// 签的是新 payload,只换 token 不换 payload 唯一一次重试必再 403)。
    func test每日token被拒403_静默重签后重试一次且payload重建() async throws {
        // chart 快照带「已死」token
        var seeded = Self.makeResponse(hash: "daily_resign_b")
        seeded.contextTokens = ["payload": "old-dead"]
        let request = BaziCalculateRequest(
            birthDatetime: "1990-03-15T12:00:00",
            timezone: "Asia/Shanghai",
            gender: "male",
            longitude: 116.4074,
            latitude: 39.9042,
            placeName: "北京",
            geonameId: 1816670,
            ziHourRule: "zi_next_day",
            hourKnown: true
        )
        _ = try chartStore.upsert(response: seeded, request: request)
        // 重签应答:同 hash + 新 token + **喜忌结论翻转**(模拟规则演化:
        // contentHash 只含出生信息,派生字段可变)
        var fresh = Self.makeResponse(hash: "daily_resign_b", favorableElements: ["火", "土"])
        fresh.contextTokens = ["payload": "np2"]
        await api.setCannedCalculate(fresh)
        await api.setDailyFortuneToken("daily-t2")
        await api.setDailyFortuneError(
            APIError.backendError(
                code: "CONTEXT_TOKEN_INVALID", message: "token 失效",
                requestId: nil),
            times: 1)

        let (response, _) = try await orchestrator.runDeterministic(
            chartHash: "daily_resign_b",
            ziHourRule: "zi_next_day",
            businessDate: Date.now
        )
        XCTAssertEqual(response.contextToken, "daily-t2")
        let calls = await api.dailyFortuneAttempts()
        XCTAssertEqual(calls, 2, "首调 403 → 静默重签 → 恰好重试一次")
        let requests = await api.recordedDailyFortuneRequests()
        XCTAssertEqual(requests[0].contextToken, "old-dead", "首调用快照里的旧 token")
        XCTAssertEqual(requests[1].contextToken, "np2", "重试携带重签后的新 chart token")
        XCTAssertEqual(
            requests[1].chartPayload.favorableElements, ["火", "土"],
            "重试的 chartPayload 必须随重签 response 重建(而非沿用旧快照派生字段)"
        )
    }

    func test有token快照_正常命中_不打后端() async throws {
        try seedChart(hash: "daily_token_hit")
        let businessDate = Date.now
        try dailyStore.upsert(
            chartHash: "daily_token_hit",
            targetDate: businessDate,
            response: Self.makeDailyResponse(contextToken: "v1.existing-token"),
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: businessDate)
        )
        let (response, fromCache) = try await orchestrator.runDeterministic(
            chartHash: "daily_token_hit",
            ziHourRule: "zi_next_day",
            businessDate: businessDate
        )
        XCTAssertTrue(fromCache, "带 token 的正常快照照常命中")
        XCTAssertEqual(response.contextToken, "v1.existing-token")
        let calls = await api.dailyFortuneAttempts()
        XCTAssertEqual(calls, 0, "缓存命中不得打后端")
    }

    /// 2026-10-08 外评 #5 回归:「token 在但已失效」(如 JWT_SECRET_KEY 轮换)
    /// 的快照照样复用 → interpret 403 → 死循环到当天结束。修复 = 403 时清快照
    /// token,落回「无 token 视同 miss」重签路径自愈(b921223 nil 补丁的姊妹)。
    func test解读403凭证失效_清快照失效token_下次进入重签自愈() async throws {
        try seedChart(hash: "daily_token_stale")
        // 播种用 VM 同款业务日(startOfDay 截断;直接用 Date.now 会因含时分秒
        // 与 VM 的 selectedDate 不等,快照 miss 落穿,测不到「复用坏 token」路径)
        let businessDate = BusinessDateCalculator.businessDate(
            now: .now, ziHourRule: "zi_next_day"
        )
        try dailyStore.upsert(
            chartHash: "daily_token_stale",
            targetDate: businessDate,
            response: Self.makeDailyResponse(contextToken: "v1.rotated-secret-token"),
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: businessDate)
        )
        await api.setInterpretError(APIError.backendError(
            code: "CONTEXT_TOKEN_INVALID",
            message: "解读凭证已失效",
            requestId: nil
        ))
        vm.silentRetryDelay = 0.05

        vm.onAppear(currentChartHash: "daily_token_stale", ziHourRule: "zi_next_day")

        // 403 → .contextTokenExpired 独立态(不走 failed 静默重试循环)
        let expired = await waitFor { Self.isContextTokenExpired(self.vm.state) }
        XCTAssertTrue(expired, "凭证失效必须落 .contextTokenExpired,实际:\(vm.state)")

        // 失效 token 已清:快照本身仍新鲜(日粒度 cachedUntil 未过),但 token 归空
        let snapshot = try dailyStore.getCachedIfFresh(
            chartHash: "daily_token_stale", targetDate: businessDate
        )
        XCTAssertNotNil(snapshot, "快照日粒度新鲜度不受 token 清除影响")
        XCTAssertNil(snapshot?.contextToken, "403 后必须清快照失效 token(否则当天每次进入都复用坏 token)")

        // 自愈闭环:后端恢复正常(错误清空 + 可重签)→ 下次 runDeterministic
        // 视同 miss 落穿重签(不再复用坏 token 再 403)
        await api.setInterpretError(nil)
        await api.setDailyFortuneToken("v1.fresh-token")
        let (response, fromCache) = try await orchestrator.runDeterministic(
            chartHash: "daily_token_stale",
            ziHourRule: "zi_next_day",
            businessDate: businessDate
        )
        XCTAssertFalse(fromCache, "token 清空后必须落穿后端重签(死锁出口)")
        XCTAssertEqual(response.contextToken, "v1.fresh-token")
        let refreshed = try dailyStore.getCachedIfFresh(
            chartHash: "daily_token_stale", targetDate: businessDate
        )
        XCTAssertEqual(refreshed?.contextToken, "v1.fresh-token", "重签 token 覆盖自愈")
    }

    // MARK: - 自动失败 → 一次静默重试 → 成功

    func test自动解读失败_保持failed置重试标记_静默重试成功转okFree() async throws {
        try seedChart(hash: "fallback_retry_success")
        await api.setInterpretFailFirst(1)  // 第 1 次失败,之后成功
        vm.silentRetryDelay = 0.05

        vm.onAppear(currentChartHash: "fallback_retry_success", ziHourRule: "zi_next_day")

        // 第一跳:自动生成失败 → .failed(模板文案态)+ 静默重试已调度
        let failed = await waitFor { Self.isFailed(self.vm.state) }
        XCTAssertTrue(failed, "自动解读失败必须落 .failed,实际:\(vm.state)")
        XCTAssertTrue(vm.isSilentRetrying, "失败即调度静默重试,标记应为 true")

        // 第二跳:静默重试(第 2 次 interpret)成功 → .okFree,标记归位
        let ok = await waitFor { Self.isOkFree(self.vm.state) }
        XCTAssertTrue(ok, "静默重试成功必须转 .okFree,实际:\(vm.state)")
        XCTAssertFalse(vm.isSilentRetrying, "成功后重试标记必须归 false")

        let calls = await api.interpretAttempts()
        XCTAssertEqual(calls, 2, "恰好两次:自动 1 次 + 静默重试 1 次,不得更多")
    }

    // MARK: - 静默重试也失败 → 终态,不循环

    func test静默重试也失败_停在failed_恰好两次不循环() async throws {
        try seedChart(hash: "fallback_retry_exhausted")
        await api.setInterpretFailFirst(.max)  // 永远失败
        vm.silentRetryDelay = 0.05

        vm.onAppear(currentChartHash: "fallback_retry_exhausted", ziHourRule: "zi_next_day")

        // 等到「重试也失败」终态:.failed 且标记归位(重试已执行完)
        let settled = await waitFor {
            Self.isFailed(self.vm.state) && !self.vm.isSilentRetrying
        }
        XCTAssertTrue(settled, "静默重试失败后应停在 .failed 且标记归 false,实际:\(vm.state) retrying=\(vm.isSilentRetrying)")

        // 一次为限:延迟 ≫ 0.05s 后仍恰好 2 次,证明没有第三轮调度
        try? await Task.sleep(nanoseconds: 400_000_000)
        let calls = await api.interpretAttempts()
        XCTAssertEqual(calls, 2, "静默重试一次为限,不得循环重试")
        XCTAssertTrue(Self.isFailed(vm.state), "终态保持 .failed(模板文案,恢复靠下拉刷新)")
    }

    // MARK: - 手动重试失败:不调度静默重试

    func test手动重试失败_不再调度静默重试() async throws {
        try seedChart(hash: "fallback_manual_fail")
        await api.setInterpretFailFirst(.max)  // 永远失败
        vm.silentRetryDelay = 0.05

        vm.onAppear(currentChartHash: "fallback_manual_fail", ziHourRule: "zi_next_day")

        // 先走到「自动失败 + 静默重试失败」终态(上一用例路径):恰好 2 次
        let settled = await waitFor {
            Self.isFailed(self.vm.state) && !self.vm.isSilentRetrying
        }
        XCTAssertTrue(settled, "前置:应已到自动+静默重试双双失败的终态,实际:\(vm.state)")

        // 手动触发(.manual,入口=.idle CTA 同一 API;Retry 按钮 2026-10-06
        // 已移除,此处直调 VM 契约):状态先转 .fetching 再落 .failed(轮询
        // 计数区分「手动这次已真实发起」与前置终态——前置终态 calls 恒为 2)
        vm.generateInterpretation(currentChartHash: "fallback_manual_fail")
        let manualFailed = await waitFor {
            let calls = await self.api.interpretAttempts()
            return Self.isFailed(self.vm.state) && !self.vm.isSilentRetrying && calls >= 3
        }
        XCTAssertTrue(manualFailed, "手动重试失败应回到 .failed,实际:\(vm.state)")

        try? await Task.sleep(nanoseconds: 400_000_000)
        let final = await api.interpretAttempts()
        XCTAssertEqual(final, 3, "自动 1 + 静默 1 + 手动 1 = 恰好 3 次;手动失败后不得再调度静默重试")
        XCTAssertFalse(vm.isSilentRetrying, "手动路径不置静默重试标记")
    }

    // MARK: - #7 世代号守卫 vs 已扣次数(2026-10-07 外评)

    /// refresh() 直连 runFullPipeline、不经 load() 的 interpretTask 取消——
    /// 解读在飞时下拉刷新会推进世代号,已扣次数的成功结果按世代失配自弃
    /// = 白扣(次数恰好耗尽时达限卡还会盖住刚付费的内容)。修复:同业务日
    /// 的迟到成功照常落地(取当前 response;跨业务日/换盘照旧自弃)。
    /// 预扣 9 次 → G1 消耗最后 1 次 → 刷新管线尾部次数耗尽且无跨语言源,
    /// 不再自动起链(不会取消在飞的 G1),迟到落地成为唯一归宿。
    func test解读在飞时下拉刷新_同日迟到成功不丢弃() async throws {
        try seedChart(hash: "late_land")
        for _ in 0..<9 { _ = counter.tryConsume(module: "daily_fortune") }
        // G1 挂起 700ms:制造「在飞窗口内刷新」的确定性时序
        await api.setInterpretGate { try? await Task.sleep(nanoseconds: 700_000_000) }

        vm.onAppear(currentChartHash: "late_land", ziHourRule: "zi_next_day")
        let g1Started = await waitFor {
            await self.api.interpretAttempts() >= 1
        }
        XCTAssertTrue(g1Started, "前置:G1 解读已发起(挂起中)")

        await vm.refresh(currentChartHash: "late_land", ziHourRule: "zi_next_day")

        let ok = await waitFor { Self.isOkFree(self.vm.state) }
        XCTAssertTrue(ok, "同日迟到成功必须落地(已扣次数不丢),实际:\(vm.state)")
        if case .ready(_, .okFree(let text, _), _) = vm.state {
            XCTAssertEqual(text, "静默重试成功后的解读文本(mock)。", "落地的必须是 G1 的结果")
        }
        // 迟到落地后不得再补发(丢弃重扣是修复前的次生病灶)
        try? await Task.sleep(nanoseconds: 400_000_000)
        let calls = await api.interpretAttempts()
        XCTAssertEqual(calls, 1, "已扣次数的结果不得被丢弃后重扣,实际 interpret=\(calls)")
    }

    // MARK: - L5 门控(2026-10-07 review 修复)

    /// 次数耗尽 + 切语言:存在可翻译的跨语言源 → 仍自动触发(翻译不耗次数,
    /// 守住 L5/F3「次数耗尽时也不再出现『当天一段新语言解读都没有』」拍板)。
    /// 修复前 VM 侧 remainingReads > 0 一刀切,耗尽 + 切语言 = 当天无解读。
    /// 反向:无源时维持原门槛,不发起注定 dailyLimitReached 的空调用。
    func test次数耗尽切语言_有跨语言源自动翻译_无源维持门槛() async throws {
        // 目标语言 zh-hant(与 zh 源行不同 → 同语言 miss + 跨语言命中;
        // 生效语言读启动快照,双写 = 模拟「重启后 zh-hant 生效」)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
            UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        }

        let hash = "l5_gate_translate"
        try seedChart(hash: hash)
        let businessDate = BusinessDateCalculator.businessDate(now: .now, ziHourRule: "zi_next_day")
        // zh 源行(合法 v4 五段;身份与 FailingInterpretAPIClient 的 health 一致)
        try interpretStore.upsert(
            contentHash: hash,
            module: "daily_fortune",
            promptVersion: 4,
            targetDate: businessDate,
            language: "zh",
            provider: "anthropic",
            model: "claude-test",
            interpretation: #"{"headline":"静心开局","work":"先做要紧的事。","relationships":"话留三分。","energy":"按自己的节奏。","reminder":"量力而行。"}"#,
            generatedAt: .now
        )
        await api.setTranslateText(#"{"headline":"靜心開局","work":"先做要緊的事。","relationships":"話留三分。","energy":"按自己的節奏。","reminder":"量力而行。"}"#)

        // 耗尽共享池(全局 10 次)
        while counter.tryConsume(module: "test_drain") {}
        XCTAssertEqual(vm.remainingReads, 0, "前置:共享池已耗尽")

        vm.onAppear(currentChartHash: hash, ziHourRule: "zi_next_day")

        let ok = await waitFor { Self.isOkFree(self.vm.state) }
        XCTAssertTrue(ok, "有可翻译跨语言源:必须自动翻译出当日解读(非达限卡),实际:\(vm.state)")
        let translateCalls = await api.translateAttempts()
        XCTAssertEqual(translateCalls, 1, "必须恰好一次翻译调用")
        let interpretCalls = await api.interpretAttempts()
        XCTAssertEqual(interpretCalls, 0, "不得走生成路径(耗次数);修复前被 remainingReads>0 门槛拦死,当天无解读")
        XCTAssertEqual(vm.remainingReads, 0, "翻译不消耗次数")
    }

    /// L5 反向:耗尽 + **无**跨语言源 → 维持原门槛(.idle,达限卡由 UI 渲染),
    /// 不发起注定 dailyLimitReached 的空调用与 spinner 闪动。
    /// 独立用例(onAppear 在 .ready 态短路防切 Tab 闪 loading,复用同 VM
    /// 无法二次进管线)。
    func test次数耗尽无源_维持idle门槛不发空调用() async throws {
        let hash = "l5_gate_nosource"
        try seedChart(hash: hash)
        // 耗尽共享池,不种任何解读行(无同语言缓存亦无跨语言源)
        while counter.tryConsume(module: "test_drain") {}
        XCTAssertEqual(vm.remainingReads, 0, "前置:共享池已耗尽")

        vm.onAppear(currentChartHash: hash, ziHourRule: "zi_next_day")

        let settled = await waitFor {
            if case .ready(_, .idle, _) = self.vm.state { return true }
            return false
        }
        XCTAssertTrue(settled, "耗尽 + 无源必须落 .ready(.idle)(达限卡),实际:\(vm.state)")
        // 若误触发自动链,给足发作时间再断言零调用
        try? await Task.sleep(nanoseconds: 400_000_000)
        let interpretCalls = await api.interpretAttempts()
        XCTAssertEqual(interpretCalls, 0, "无源时不得发起 interpret(不发起注定 dailyLimitReached 的空调用)")
        let translateCalls = await api.translateAttempts()
        XCTAssertEqual(translateCalls, 0, "无源时不得发起翻译")
    }

    // MARK: - 引擎模板表完整性(防三语词表漂移丢键)

    func test引擎模板表_十神10键三语全量非空() {
        let relations = [
            "比肩", "劫财", "食神", "伤官", "偏财",
            "正财", "七杀", "正官", "偏印", "正印",
        ]
        for relation in relations {
            XCTAssertNotNil(EngineReadingTemplates.zh[relation], "zh 表缺 \(relation)")
            XCTAssertNotNil(EngineReadingTemplates.hant[relation], "hant 表缺 \(relation)")
            XCTAssertNotNil(EngineReadingTemplates.en[relation], "en 表缺 \(relation)")
        }
        XCTAssertEqual(Set(EngineReadingTemplates.zh.keys), Set(relations), "zh 表键集必须恰为十神 10 键")
        XCTAssertEqual(Set(EngineReadingTemplates.hant.keys), Set(relations), "hant 表键集必须恰为十神 10 键")
        XCTAssertEqual(Set(EngineReadingTemplates.en.keys), Set(relations), "en 表键集必须恰为十神 10 键")
        // S6(2026-09-30)起模板五段化(与 v4 正常态同构):五字段全非空
        for (key, value) in EngineReadingTemplates.zh {
            XCTAssertFalse(value.headline.isEmpty, "zh[\(key)] headline 空,疑似占位")
            XCTAssertGreaterThan(value.work.count, 6, "zh[\(key)] work 过短,疑似占位")
            XCTAssertGreaterThan(value.relationships.count, 6, "zh[\(key)] relationships 过短,疑似占位")
            XCTAssertGreaterThan(value.energy.count, 6, "zh[\(key)] energy 过短,疑似占位")
            XCTAssertFalse(value.reminder.isEmpty, "zh[\(key)] reminder 空,疑似占位")
        }
        // 查表 miss → fallback 五段非空且不 crash(错误显式传播:miss 记日志,不静默)
        let fallback = EngineReadingTemplates.insight(for: "不存在的十神")
        XCTAssertFalse(fallback.headline.isEmpty, "查表 miss 必须给非空 fallback")
        XCTAssertFalse(fallback.reminder.isEmpty, "查表 miss 必须给非空 fallback")
    }

    // MARK: - DailyInsight.parse(v4 JSON 五段契约;S6 2026-09-30)

    /// v4 输出契约的解析行为锁死:成功/围栏/缺键/空值/非 JSON(=v3 散文快照)
    /// /非字符串值/宽容多余键。离线兜底与 .okFree 都靠它分辨新旧格式。
    func testDailyInsightParse_五键齐全成功() {
        let json = #"{"headline":"偏官当值的一天","work":"接下难事。","relationships":"对事不对人。","energy":"紧绷是常态。","reminder":"量力而行。"}"#
        let insight = DailyInsight.parse(json)
        XCTAssertEqual(insight?.headline, "偏官当值的一天")
        XCTAssertEqual(insight?.reminder, "量力而行。")
    }

    func testDailyInsightParse_剥json围栏() {
        let fenced = """
        ```json
        {"headline":"h","work":"w","relationships":"r","energy":"e","reminder":"m"}
        ```
        """
        XCTAssertNotNil(DailyInsight.parse(fenced), "LLM 违约带围栏也应解析成功")
    }

    func testDailyInsightParse_缺键返回nil() {
        let missing = #"{"headline":"h","work":"w","relationships":"r","energy":"e"}"#
        XCTAssertNil(DailyInsight.parse(missing), "缺 reminder 必须整体降级,不半渲染")
    }

    func testDailyInsightParse_空串值返回nil() {
        let emptyWork = #"{"headline":"h","work":"","relationships":"r","energy":"e","reminder":"m"}"#
        XCTAssertNil(DailyInsight.parse(emptyWork), "空串视为缺失,整体降级")
    }

    func testDailyInsightParse_v3散文返回nil() {
        let prose = "流日与你的日主同根同气,是自立自守的一天。今天适合按自己的节奏推进。"
        XCTAssertNil(DailyInsight.parse(prose), "v3 散文快照必须解析失败(离线兜底走原渲染)")
    }

    func testDailyInsightParse_非字符串值返回nil() {
        let nonString = #"{"headline":"h","work":"w","relationships":"r","energy":"e","reminder":null}"#
        XCTAssertNil(DailyInsight.parse(nonString), "null 值视为缺失,不静默跳过该字段")
    }

    func testDailyInsightParse_宽容多余键() {
        let extra = #"{"headline":"h","work":"w","relationships":"r","energy":"e","reminder":"m","future_field":"x"}"#
        XCTAssertNotNil(DailyInsight.parse(extra), "多余键不阻断(向后兼容前向演进)")
        XCTAssertEqual(DailyInsight.parse(extra)?.work, "w")
    }

    // MARK: - S6 缓存毒化自愈(2026-09-30 review 修复)

    func testDailyInsightLooksLikeJSON_三分支() {
        XCTAssertTrue(DailyInsight.looksLikeJSON(#"{"headline":"h"}"#), "裸 JSON 对象为 JSON 形态")
        XCTAssertTrue(DailyInsight.looksLikeJSON("```json\n{\"headline\":\"h\"}\n```"), "围栏包裹为 JSON 形态")
        XCTAssertFalse(DailyInsight.looksLikeJSON("流日与你的日主同根同气,是自立自守的一天。"), "v3 散文不是 JSON 形态")
        XCTAssertFalse(DailyInsight.looksLikeJSON("  \n  "), "纯空白不是 JSON 形态")
        XCTAssertTrue(
            DailyInsight.looksLikeJSON(#"{"headline": "静心开局", "work": "先做要紧的。", "relatio"#),
            "畸形半截 JSON 仍属 JSON 形态(走引擎模板不裸奔)"
        )
    }

    /// v3 散文缓存行命中 → 不返回,绕过本地缓存重新生成 v4;
    /// 生成后的 v4 行再命中 → 走缓存零网络调用(缓存毒化自愈回归)。
    func test本地缓存不满足v4契约_绕过落穿重新生成() async throws {
        let hash = "review-cache-poison-001"
        let response = try seedChart(hash: hash)
        let fixedDate = Date(timeIntervalSince1970: 1_783_000_000)

        // 预置同键 v3 散文缓存行(身份与 FailingInterpretAPIClient 的 health 一致;
        // language 用 currentWire——reader 按 AppLanguage.currentWire 过滤,硬编码
        // "zh" 在 en-locale 模拟器上会因语言维度 miss 而空转通过)
        try interpretStore.upsert(
            contentHash: hash,
            module: "daily_fortune",
            promptVersion: 3,
            targetDate: fixedDate,
            language: AppLanguage.currentWire,
            provider: "anthropic",
            model: "claude-test",
            interpretation: "流日与你的日主同根同气,是自立自守的一天。",
            generatedAt: .now
        )

        await api.setInterpretText(#"{"headline":"静心开局","work":"先做要紧的。","relationships":"话留三分。","energy":"按自己的节奏。","reminder":"量力而行。"}"#)
        let dailyResponse = DailyFortuneResponse(
            dayPillar: "丙子",
            dayRelationToDayMaster: "偏印",
            dayChong: nil,
            dayChongTargets: [],
            hourPillars: [],
            currentHourIndex: nil,
            lunarDate: "七月初十",
            huangliYi: ["出行"],
            huangliJi: ["动土"],
            tomorrowPreview: TomorrowPreviewDTO(dayPillar: "丁丑", dayRelation: "正印", dayChong: nil),
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1
            )
        )
        // runInterpretation 的 updateInterpretation 需要已存在的 daily 快照行
        try dailyStore.upsert(
            chartHash: hash,
            targetDate: fixedDate,
            response: dailyResponse,
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: fixedDate)
        )

        let resp = try await orchestrator.runInterpretation(
            chartHash: hash,
            chartPayload: ChartPayloadDTO.from(baziResponse: response),
            dailyResponse: dailyResponse,
            businessDate: fixedDate
        )
        let attemptsAfterFirst = await api.interpretAttempts()
        XCTAssertEqual(attemptsAfterFirst, 1, "v3 散文缓存行应被绕过,重新调网络生成")
        XCTAssertFalse(resp.cached, "落穿生成的是新响应")
        XCTAssertEqual(DailyInsight.parse(resp.interpretation)?.headline, "静心开局", "新响应必须是合法 v4 五段")

        // 第二次:新生成的 v4 行命中本地缓存,零网络调用
        let resp2 = try await orchestrator.runInterpretation(
            chartHash: hash,
            chartPayload: ChartPayloadDTO.from(baziResponse: response),
            dailyResponse: dailyResponse,
            businessDate: fixedDate
        )
        let attemptsAfterSecond = await api.interpretAttempts()
        XCTAssertEqual(attemptsAfterSecond, attemptsAfterFirst, "合法 v4 行应命中本地缓存,不再调网络")
        XCTAssertTrue(resp2.cached, "第二次应命中缓存")
        XCTAssertEqual(resp2.interpretation, resp.interpretation)
    }

    /// prefetch 读路径(cachedInterpretationIfFresh)的毒化自愈:v3 散文行 →
    /// 返回 nil 视为无缓存(交给自动生成链路),且不把坏文本同步进 daily 快照。
    func testPrefetch读路径_毒化行返回nil且不同步快照() async throws {
        let hash = "review-cache-poison-002"
        try seedChart(hash: hash)
        let fixedDate = Date(timeIntervalSince1970: 1_783_000_000)

        // 预置同键 v3 散文缓存行(身份与 FailingInterpretAPIClient 的 health 一致;
        // language 用 currentWire,理由同上——硬编码会在 en-locale 模拟器空转)
        try interpretStore.upsert(
            contentHash: hash,
            module: "daily_fortune",
            promptVersion: 3,
            targetDate: fixedDate,
            language: AppLanguage.currentWire,
            provider: "anthropic",
            model: "claude-test",
            interpretation: "流日与你的日主同根同气,是自立自守的一天。",
            generatedAt: .now
        )

        // 预置 daily 快照行(interpretation 留空):guard 返回 nil 应发生在
        // updateInterpretation 之前——快照不得被坏文本污染
        let dailyResponse = DailyFortuneResponse(
            dayPillar: "丙子",
            dayRelationToDayMaster: "偏印",
            dayChong: nil,
            dayChongTargets: [],
            hourPillars: [],
            currentHourIndex: nil,
            lunarDate: "七月初十",
            huangliYi: ["出行"],
            huangliJi: ["动土"],
            tomorrowPreview: TomorrowPreviewDTO(dayPillar: "丁丑", dayRelation: "正印", dayChong: nil),
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1
            )
        )
        try dailyStore.upsert(
            chartHash: hash,
            targetDate: fixedDate,
            response: dailyResponse,
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: fixedDate)
        )

        let result = try await orchestrator.cachedInterpretationIfFresh(
            chartHash: hash,
            targetDate: fixedDate
        )
        XCTAssertNil(result, "毒化行应返回 nil,让 VM 走自动生成链路")

        let snapshot = try dailyStore.get(chartHash: hash, targetDate: fixedDate)
        XCTAssertEqual(
            snapshot?.interpretation, "",
            "毒化行不得经 updateInterpretation 同步进 daily 快照"
        )
    }

    // MARK: - R1 翻译 STALE_SOURCE 落穿生成(2026-10-02 review)

    /// 翻译遇 409 STALE_SOURCE(原文版本过期 / 逐字核验 miss)→ 不得上抛死等:
    /// 落穿到生成路径,且豁免次数(语言切换引起,与深度解析 L4 同口径)。
    /// 不回落会让重试反复撞同一个 409,当天永远拿不到新语言解读。
    func test翻译STALE_SOURCE_落穿生成且豁免次数() async throws {
        // 目标语言 = zh-hant(与 zh 原文行不同,触发跨语言翻译探测;
        // 生效语言读启动快照,双写 = 模拟「重启后 zh-hant 生效」)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.launchSnapshotDefaultsKey)
        defer {
            UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
            UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        }

        let hash = "review-daily-stale-001"
        let response = try seedChart(hash: hash)
        let fixedDate = Date(timeIntervalSince1970: 1_783_000_000)
        let v4Text = #"{"headline":"静心开局","work":"先做要紧的。","relationships":"话留三分。","energy":"按自己的节奏。","reminder":"量力而行。"}"#

        // 简体原文行(身份与 health 一致;language zh ≠ 当前 zh-hant 才会被
        // 跨语言探测命中;v4 五段契约可解析,不当毒化行过滤)
        try interpretStore.upsert(
            contentHash: hash,
            module: "daily_fortune",
            promptVersion: 1,
            targetDate: fixedDate,
            language: "zh",
            provider: "anthropic",
            model: "claude-test",
            interpretation: v4Text,
            generatedAt: .now
        )
        await api.setInterpretText(v4Text)
        await api.setTranslateError(
            APIError.backendError(code: "STALE_SOURCE", message: "原文 prompt_version 已过期", requestId: nil)
        )

        let dailyResponse = DailyFortuneResponse(
            dayPillar: "丙子",
            dayRelationToDayMaster: "偏印",
            dayChong: nil,
            dayChongTargets: [],
            hourPillars: [],
            currentHourIndex: nil,
            lunarDate: "七月初十",
            huangliYi: ["出行"],
            huangliJi: ["动土"],
            tomorrowPreview: TomorrowPreviewDTO(dayPillar: "丁丑", dayRelation: "正印", dayChong: nil),
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1
            )
        )
        // runInterpretation 的 updateInterpretation 需要已存在的 daily 快照行
        try dailyStore.upsert(
            chartHash: hash,
            targetDate: fixedDate,
            response: dailyResponse,
            interpretation: "",
            cachedUntil: BusinessDateCalculator.cachedUntil(forBusinessDate: fixedDate)
        )

        let readsBefore = orchestrator.remainingReads()
        let resp = try await orchestrator.runInterpretation(
            chartHash: hash,
            chartPayload: ChartPayloadDTO.from(baziResponse: response),
            dailyResponse: dailyResponse,
            businessDate: fixedDate
        )

        let translateCalls = await api.translateAttempts()
        XCTAssertEqual(translateCalls, 1, "必须先尝试过一次翻译(跨语言原文存在)")
        let interpretCalls = await api.interpretAttempts()
        XCTAssertEqual(interpretCalls, 1, "STALE 后必须落穿网络生成,不得停在失败态")
        XCTAssertFalse(resp.cached, "落穿生成的是新响应")
        XCTAssertEqual(
            DailyInsight.parse(resp.interpretation)?.headline, "静心开局",
            "落穿生成的必须是合法 v4 五段"
        )
        XCTAssertEqual(
            orchestrator.remainingReads(), readsBefore,
            "STALE 降级生成必须豁免次数(R1:语言切换引起,非用户过错)"
        )
    }

    // MARK: - #4(2026-10-07 review):旧刷新管线世代号守卫

    /// refresh() 直连 runFullPipeline、不经 load() 的 determinantTask 取消——
    /// A 盘下拉刷新挂起窗口内切 B 盘,A 旧管线晚返回时:①不得把 UI 写回 A 的
    /// .ready;②不得为 A 自动扣一次解读(修复前:旧管线凭局部 .idle 触发
    /// generateInterpretation,interpret 计数多 1 且用户界面闪回旧盘)。
    func test旧刷新管线_切盘后晚返回_不覆写新盘不代扣旧盘() async throws {
        _ = try seedChart(hash: "gen_a")
        _ = try seedChart(hash: "gen_b")

        // A 先就绪(首刷无门)
        vm.onAppear(currentChartHash: "gen_a", ziHourRule: "zi_next_day")
        let aReady = await waitFor { Self.isOkFree(self.vm.state) }
        XCTAssertTrue(aReady, "前置:A 盘必须先就绪(自动解读落 .okFree)")

        // A 下拉刷新挂起在 dailyFortune(refresh 直连 runFullPipeline,切盘后
        // 不会被 determinantTask 取消——正是旧管线的复活通道)
        let gate = ChartGate()
        await api.setDailyFortuneGate { chartHash in
            if chartHash == "gen_a" { await gate.wait() }
        }
        Task { await self.vm.refresh(currentChartHash: "gen_a", ziHourRule: "zi_next_day") }

        // 挂起窗口内切 B 盘(View 同款:hash 变化先置 .empty 脱离旧态再 onAppear)
        vm.state = .empty
        vm.onAppear(currentChartHash: "gen_b", ziHourRule: "zi_next_day")
        let bReady = await waitFor {
            let calls = await self.api.interpretAttempts()
            return Self.isOkFree(self.vm.state) && calls >= 1
        }
        XCTAssertTrue(bReady, "B 新管线必须独立落成(.okFree + 自动解读)")

        // 放行 A 旧管线:世代失配 → 整体自弃(不写 .ready、不自动解读)
        gate.fulfill()
        try? await Task.sleep(nanoseconds: 800_000_000)

        // A 的解读恰好 1 次(首次 onAppear 的自动解读)——旧刷新管线晚返回
        // 不得再为 A 代扣一次(修复前:旧管线凭局部 .idle 再触发,gen_a 计 2)
        let interpretHashes = await api.recordedInterpretHashes()
        XCTAssertEqual(
            interpretHashes.filter { $0 == "gen_a" }.count, 1,
            "A 旧管线不得为旧盘自动扣解读,实际序列:\(interpretHashes)"
        )
        XCTAssertEqual(
            interpretHashes.filter { $0 == "gen_b" }.count, 1,
            "B 新管线自动解读恰好一次,实际序列:\(interpretHashes)"
        )
        XCTAssertTrue(Self.isOkFree(vm.state), "A 晚返回不得把 UI 覆写回旧盘/非就绪态,实际:\(vm.state)")
    }
}

/// #4 交错回归夹具:挂起指定调用直到 fulfill(NSLock 串行化,测试线程
/// fulfill、double 的 actor 上下文 await)。
private final class ChartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock(); defer { lock.unlock() }
            if released {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    func fulfill() {
        lock.lock(); defer { lock.unlock() }
        released = true
        continuation?.resume()
        continuation = nil
    }
}

// MARK: - Test Double

private enum FlakyTestError: Error {
    case unexpectedCall
}

/// 失败注入双打:interpret 前 `failFirst` 次抛错(之后成功,测试可重设);
/// dailyFortune / health 恒成功;其余端点被调即抛错(负向哨兵)。
private actor FailingInterpretAPIClient: APIClient {
    private var failFirst: Int = 0
    private var attempts = 0
    private var interpretText: String = "静默重试成功后的解读文本(mock)。"
    /// 2026-10-08 外评 #5 回归:非 nil 时 interpret 抛此错(凭证失效 403 面)。
    private var interpretError: APIError?
    func setInterpretError(_ error: APIError?) { interpretError = error }
    /// R1 测试注入:非 nil 时 translate 抛此错(STALE_SOURCE 等翻译失败面)。
    private var translateError: APIError?
    /// L5 测试注入:非 nil 时 translate 返回该文本(合法 v4 五段 = 译文成功)。
    private var translateText: String?
    private var translateCalls = 0

    func setInterpretFailFirst(_ n: Int) { failFirst = n }
    func setInterpretText(_ text: String) { interpretText = text }
    func setTranslateError(_ error: APIError?) { translateError = error }
    func setTranslateText(_ text: String?) { translateText = text }
    func interpretAttempts() -> Int { attempts }
    func translateAttempts() -> Int { translateCalls }
    /// #4(2026-10-07)交错回归:非 nil 时 dailyFortune 按 chartHash 挂起。
    private var dailyFortuneGate: (@Sendable (_ chartHash: String) async -> Void)?
    /// #7(2026-10-07)迟到落地回归:非 nil 时 interpret 返回前挂起(控制在飞窗口)。
    private var interpretGate: (@Sendable () async -> Void)?
    func setInterpretGate(_ gate: (@Sendable () async -> Void)?) {
        interpretGate = gate
    }
    /// interpret 请求的 contentHash 序列(#4 断言"只代扣新盘"用)。
    private var interpretHashes: [String] = []
    func setDailyFortuneGate(_ gate: (@Sendable (String) async -> Void)?) {
        dailyFortuneGate = gate
    }
    func recordedInterpretHashes() -> [String] { interpretHashes }
    /// 2026-10-07 无 token 快照回归:dailyFortune 调用计数 + 可注入 token。
    private var dailyFortuneCalls = 0
    private var dailyFortuneToken: String?
    func setDailyFortuneToken(_ token: String?) { dailyFortuneToken = token }
    func dailyFortuneAttempts() -> Int { dailyFortuneCalls }
    /// 拍板②老盘重签回归(2026-10-09):前 N 次 dailyFortune 抛此错
    /// (403 CONTEXT_TOKEN_* 面);calculateBazi 可注入重签应答;两者均计数/录请求。
    private var dailyFortuneError: APIError?
    private var dailyFortuneErrorTimes = 0
    private var dailyFortuneErrorsThrown = 0
    private var dailyFortuneRequests: [DailyFortuneRequest] = []
    private var cannedCalculate: BaziResponse?
    private var calculateCalls = 0
    func setDailyFortuneError(_ error: APIError?, times: Int = 1) {
        dailyFortuneError = error
        dailyFortuneErrorTimes = times
        dailyFortuneErrorsThrown = 0
    }
    func setCannedCalculate(_ response: BaziResponse?) {
        cannedCalculate = response
    }
    func calculateAttempts() -> Int { calculateCalls }
    func recordedDailyFortuneRequests() -> [DailyFortuneRequest] {
        dailyFortuneRequests
    }

    func translate(request: TranslateRequest) async throws -> InterpretResponse {
        translateCalls += 1
        if let translateError {
            throw translateError
        }
        if let translateText {
            return InterpretResponse(
                interpretation: translateText,
                promptVersion: 4,
                cached: false,
                generatedAt: .now,
                provider: "anthropic",
                model: "claude-test",
                language: AppLanguage.currentWire,
                translatedFrom: request.sourceLanguage
            )
        }
        // 未注入错误时的默认:走协议扩展同款显式哨兵(不应被静默路由到 interpret)
        throw APIError.backendError(
            code: "TRANSLATE_UNSUPPORTED",
            message: "该 APIClient 实现未支持 translate(测试替身默认实现)",
            requestId: nil
        )
    }

    func health() async throws -> HealthResponse {
        HealthResponse(
            status: "ok",
            lunarPythonVersion: "1.4.8",
            model: "bazi-calculate-v1",
            aiProvider: "anthropic",
            aiModel: "claude-test"
        )
    }

    func dailyFortune(request: DailyFortuneRequest) async throws -> DailyFortuneResponse {
        dailyFortuneCalls += 1
        dailyFortuneRequests.append(request)
        if let dailyFortuneError, dailyFortuneErrorsThrown < dailyFortuneErrorTimes {
            dailyFortuneErrorsThrown += 1
            throw dailyFortuneError
        }
        if let dailyFortuneGate {
            await dailyFortuneGate(request.chartHash)
        }
        return DailyFortuneResponse(
            dayPillar: "丙子",
            dayRelationToDayMaster: "偏印",
            dayChong: nil,
            dayChongTargets: [],
            hourPillars: [
                HourPillarDTO(
                    hour: "子", timeRange: "23:00-01:00",
                    pillar: "甲子", relation: "偏印", chong: nil, chongTargets: []
                )
            ],
            currentHourIndex: nil,
            lunarDate: "七月初十",
            huangliYi: ["出行"],
            huangliJi: ["动土"],
            tomorrowPreview: TomorrowPreviewDTO(dayPillar: "丁丑", dayRelation: "正印", dayChong: nil),
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1
            ),
            contextToken: dailyFortuneToken
        )
    }

    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        attempts += 1
        interpretHashes.append(request.contentHash)
        if let interpretError {
            throw interpretError
        }
        if attempts <= failFirst {
            throw APIError.networkError(URLError(.timedOut))
        }
        if let interpretGate {
            await interpretGate()
        }
        return InterpretResponse(
            interpretation: interpretText,
            promptVersion: 4,
            cached: false,
            generatedAt: .now,
            provider: "anthropic",
            model: "claude-test",
            language: AppLanguage.currentWire
        )
    }

    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        // 拍板②重签回归:未注入 canned 应答时维持「意外调用即抛」护栏
        calculateCalls += 1
        guard let cannedCalculate else { throw FlakyTestError.unexpectedCall }
        return cannedCalculate
    }
    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse {
        throw FlakyTestError.unexpectedCall
    }
    func redeem(request: EntitlementRedeemRequest) async throws -> EntitlementRedeemResponse {
        throw FlakyTestError.unexpectedCall
    }
    func entitlementList() async throws -> EntitlementListResponse {
        throw FlakyTestError.unexpectedCall
    }
    func signIn(request: SignInRequest) async throws -> SignInResponse {
        throw FlakyTestError.unexpectedCall
    }
    func syncPull() async throws -> SyncPullResponse {
        throw FlakyTestError.unexpectedCall
    }
    func syncPush(request: SyncPushRequest) async throws -> SyncPushResponse {
        throw FlakyTestError.unexpectedCall
    }
}
