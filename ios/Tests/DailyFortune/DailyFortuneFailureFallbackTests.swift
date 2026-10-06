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
        orchestrator = DailyFortuneOrchestrator(
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
    /// R1 测试注入:非 nil 时 translate 抛此错(STALE_SOURCE 等翻译失败面)。
    private var translateError: APIError?
    private var translateCalls = 0

    func setInterpretFailFirst(_ n: Int) { failFirst = n }
    func setInterpretText(_ text: String) { interpretText = text }
    func setTranslateError(_ error: APIError?) { translateError = error }
    func interpretAttempts() -> Int { attempts }
    func translateAttempts() -> Int { translateCalls }

    func translate(request: TranslateRequest) async throws -> InterpretResponse {
        translateCalls += 1
        if let translateError {
            throw translateError
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
