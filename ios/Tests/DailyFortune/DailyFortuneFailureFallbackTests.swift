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
///   归 false,Retry 手动兜底
/// - **手动重试失败不调度静默重试**(用户正看着,再静默转圈只会困惑)
/// - **引擎模板表**:十神 10 键三语全量非空(防词表漂移丢键)+ fallback 非空
@MainActor
final class DailyFortuneFailureFallbackTests: XCTestCase {

    private var container: ModelContainer!
    private var chartStore: ChartSnapshotStore!
    private var dailyStore: DailyFortuneSnapshotStore!
    private var api: FailingInterpretAPIClient!
    private var vm: DailyFortuneViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        chartStore = ChartSnapshotStore(context: context)
        dailyStore = DailyFortuneSnapshotStore(context: context)
        api = FailingInterpretAPIClient()
        let interpretStore = InterpretationCacheStore(context: context)
        let reader = CachedInterpretationReader(
            identityResolver: AIIdentityResolver(apiClient: api),
            cacheStore: interpretStore
        )
        let orchestrator = DailyFortuneOrchestrator(
            apiClient: api,
            dailyStore: dailyStore,
            interpretStore: interpretStore,
            chartStore: chartStore,
            counter: DailyReadCounter.makeIsolatedForTesting(),
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
    private static func makeResponse(hash: String) -> BaziResponse {
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
            favorableElements: ["木", "水"],
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

    private static func isOkFree(_ state: DailyFortuneViewState) -> Bool {
        if case .ready(_, .okFree, _) = state { return true }
        return false
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
        XCTAssertTrue(Self.isFailed(vm.state), "终态保持 .failed(模板文案 + 手动 Retry)")
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

        // 用户手点 Retry:状态先转 .fetching 再落 .failed(轮询计数区分
        // 「手动这次已真实发起」与前置终态——前置终态 calls 恒为 2)
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
        for (key, value) in EngineReadingTemplates.zh {
            XCTAssertGreaterThan(value.count, 20, "zh[\(key)] 文案过短,疑似占位")
        }
        // 查表 miss → fallback 非空且不 crash(错误显式传播:miss 记日志,不静默)
        let fallback = EngineReadingTemplates.text(for: "不存在的十神")
        XCTAssertFalse(fallback.isEmpty, "查表 miss 必须给非空 fallback")
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

    func setInterpretFailFirst(_ n: Int) { failFirst = n }
    func interpretAttempts() -> Int { attempts }

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
            tomorrowPreview: TomorrowPreviewDTO(dayPillar: "丁丑", dayRelation: "正印", dayChong: nil),
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1
            )
        )
    }

    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        attempts += 1
        if attempts <= failFirst {
            throw APIError.networkError(URLError(.timedOut))
        }
        return InterpretResponse(
            interpretation: "静默重试成功后的解读文本(mock)。",
            promptVersion: 3,
            cached: false,
            generatedAt: .now,
            provider: "anthropic",
            model: "claude-test",
            language: AppLanguage.currentWire
        )
    }

    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        throw FlakyTestError.unexpectedCall
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
