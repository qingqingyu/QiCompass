import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import QiCompass

/// S09 每日运势时辰未知 iOS 半边测试(docs/时辰未知-slices/S09 item 5 + 6)。
///
/// 覆盖 slice 验收:
/// - **日柱歧义全拦(D5)**:VM 拦在阶段 1 之前 → daily-fortune 排盘与 interpret
///   两类请求都**不发起**(路径断言:RecordingDailyAPIClient 调用计数 = 0),
///   不产生任何本地快照;generateInterpretation 纵深防御第二把锁
/// - **无时辰·日柱确定降级生成**:照常走两阶段链路,interpret context 携带
///   `day_master_strength == "unknown_hour"`(后端 S09 切降级模板的分支信号),
///   REQUIRED 17 键全量在(S05「key 只增不删」契约)
/// - **有时辰回归**:链路与 context 与现状一致(strength/favorable 非 unknown 语义)
/// - **历史/缓存(S09 item 6)**:无时辰盘(S01 分叉后的新 content_hash)的
///   日粒度快照 upsert / fresh 判据 / 7 天历史重建照常,缺柱不 crash
@MainActor
final class DailyFortuneHourUnknownGateTests: XCTestCase {

    private var container: ModelContainer!
    private var chartStore: ChartSnapshotStore!
    private var dailyStore: DailyFortuneSnapshotStore!
    private var api: RecordingDailyAPIClient!
    private var vm: DailyFortuneViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        chartStore = ChartSnapshotStore(context: context)
        dailyStore = DailyFortuneSnapshotStore(context: context)
        api = RecordingDailyAPIClient()
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
            counter: DailyReadCounter(),
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

    /// 构造指定时辰状态的 BaziResponse(纯构造不落档;seedChart 落档复用本函数,
    /// R3 测试直调 ChartPayloadDTO.from 时也用它)。`strength` 为双层 Optional:
    /// 外层 nil = 按 S01 契约默认逻辑(已知盘 "balanced" / 无时辰盘 "unknown_hour");
    /// `.some(nil)` = 显式构造 nil(异常存档,R3「不伪装 special_pattern」用例)。
    private static func makeResponse(
        hash: String,
        hourKnown: Bool,
        dayPresent: Bool = true,
        strength: String?? = nil
    ) -> BaziResponse {
        let pillar = makePillar()
        let ganzhi = GanZhiNaYinDTO(ganZhi: "甲子", nayin: "海中金")
        return BaziResponse(
            contentHash: hash,
            trueSolarTime: nil,
            trueSolarOffsetMinutes: 0,
            pillars: PillarsDTO(
                year: pillar, month: pillar,
                day: dayPresent ? pillar : nil,
                hour: hourKnown ? pillar : nil
            ),
            mingGong: ganzhi, shenGong: ganzhi, taiYuan: ganzhi,
            elementBalance: ElementBalanceDTO(wood: 2, fire: 1, earth: 1, metal: 1, water: 3),
            // S01 契约:时辰未知 → 喜忌留空 + strength="unknown_hour"(后端
            // S09 按此字段切降级模板);有日柱的已知盘保持正常语义
            favorableElements: hourKnown ? ["木", "水"] : [],
            unfavorableElements: hourKnown ? ["土"] : [],
            dayMasterStrength: strength ?? (hourKnown ? "balanced" : "unknown_hour"),
            tiaoshouApplied: false,
            xijiMethod: "扶抑+调候", patternHint: nil,
            shensha: [], luckPillars: [],
            currentLuckPillar: nil, currentYearPillar: nil,
            currentDayPillar: nil, currentHourPillar: nil,
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: 0,
                schemaVersion: 1, birthTimezone: "Asia/Shanghai",
                hourKnown: hourKnown,
                pillarAmbiguity: dayPresent ? nil : PillarAmbiguityDTO(day: true)
            ),
            boundaryWarning: nil,
            yearBranchZodiac: "Rat",
            yearBranchFriends: ["Ox"], yearBranchClash: "Horse"
        )
    }

    /// 落档一张指定时辰状态的命盘。hourKnown=false 且 dayPresent=true 即
    /// 「时辰未知·日柱确定」;dayPresent=false 即日柱歧义(S01 契约:
    /// 无时辰盘喜忌留空 + day_master_strength="unknown_hour")。
    @discardableResult
    private func seedChart(
        hash: String,
        hourKnown: Bool,
        dayPresent: Bool = true
    ) throws -> BaziResponse {
        let response = Self.makeResponse(hash: hash, hourKnown: hourKnown, dayPresent: dayPresent)
        let request = BaziCalculateRequest(
            birthDatetime: "1990-03-15T12:00:00",
            timezone: "Asia/Shanghai",
            gender: "male",
            longitude: 116.4074,
            latitude: 39.9042,
            placeName: "北京",
            geonameId: 1816670,
            ziHourRule: "zi_next_day",
            hourKnown: hourKnown
        )
        _ = try chartStore.upsert(response: response, request: request)
        return response
    }

    /// 轮询等待 VM 的 async Task 落到期望状态(load/generateInterpretation 都是 Task)。
    private func waitForState(
        _ match: @escaping (DailyFortuneViewState) -> Bool,
        timeout: TimeInterval = 8
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if match(vm.state) { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return match(vm.state)
    }

    // MARK: - 日柱歧义:全拦 + 两类请求都不发起(D5 / slice 验收核心)

    func test日柱歧义_VM全拦_两类请求零发起_零快照() async throws {
        try seedChart(hash: "s09_day_ambiguous", hourKnown: false, dayPresent: false)

        vm.onAppear(currentChartHash: "s09_day_ambiguous", ziHourRule: "zi_next_day")

        let settled = await waitForState { $0 == .hourAmbiguousBlocked }
        XCTAssertTrue(settled, "日柱歧义盘必须进 .hourAmbiguousBlocked 拦截态,实际:\(vm.state)")

        // 路径断言:daily-fortune 排盘与 interpret 都不发起
        let dailyCalls = await api.dailyFortuneCallCount()
        let interpretCalls = await api.interpretCallCount()
        XCTAssertEqual(dailyCalls, 0, "拦截态不得发起 daily-fortune 排盘请求")
        XCTAssertEqual(interpretCalls, 0, "拦截态不得发起 interpret 请求")

        // 阶段 1 从未运行 → 本地日快照零写入
        XCTAssertNil(
            try dailyStore.get(chartHash: "s09_day_ambiguous", targetDate: vm.selectedDate),
            "拦截态不得产生任何 DailyFortuneSnapshot"
        )
        XCTAssertEqual(vm.hourGate, .dayAmbiguous, "判据复用 S07 HourUnknownGate(单一事实源)")
    }

    func test日柱歧义_generateInterpretation纵深防御_仍零请求() async throws {
        try seedChart(hash: "s09_day_ambiguous_2", hourKnown: false, dayPresent: false)
        vm.onAppear(currentChartHash: "s09_day_ambiguous_2", ziHourRule: "zi_next_day")
        _ = await waitForState { $0 == .hourAmbiguousBlocked }

        // 防御性直点「今日解读」(正常 UI 在拦截态无此按钮):VM 第二把锁拒绝
        vm.generateInterpretation(currentChartHash: "s09_day_ambiguous_2")
        try? await Task.sleep(nanoseconds: 300_000_000)  // 给 Task 调度留窗口

        let interpretCalls = await api.interpretCallCount()
        XCTAssertEqual(interpretCalls, 0, "纵深防御:拦截盘 generateInterpretation 不得发起 interpret")
        XCTAssertEqual(vm.state, .hourAmbiguousBlocked, "拦截态纹丝不动,不得被改写")
    }

    // MARK: - 无时辰·日柱确定:降级生成照常(context 链路打通)

    func test无时辰日柱在_照常生成_降级信号进interpret上下文() async throws {
        try seedChart(hash: "s09_hour_unknown", hourKnown: false, dayPresent: true)

        vm.onAppear(currentChartHash: "s09_hour_unknown", ziHourRule: "zi_next_day")

        let ready = await waitForState {
            if case .ready = $0 { return true }
            return false
        }
        XCTAssertTrue(ready, "日柱确定的无时辰用户照常进 ready(后端降级模板),实际:\(vm.state)")
        let dailyCalls = await api.dailyFortuneCallCount()
        XCTAssertEqual(dailyCalls, 1, "确定性排盘照常发起(免费降级成立)")
        XCTAssertEqual(vm.hourGate, .hourUnknownDayDetermined,
                       "末尾静默提示位判据(S10 接线成可点击)")

        // AI 阶段:照常发起,context 携带 unknown_hour 降级信号
        vm.generateInterpretation(currentChartHash: "s09_hour_unknown")
        let interpreted = await waitForState {
            if case .ready(_, let interp, _) = $0 {
                if case .okFree = interp { return true }
            }
            return false
        }
        XCTAssertTrue(interpreted, "降级版解读照常生成,实际:\(vm.state)")

        let interpretCalls = await api.interpretCallCount()
        let lastRequest = await api.lastInterpretRequest()
        let request = try XCTUnwrap(lastRequest, "interpret 必须被调用一次")
        XCTAssertEqual(interpretCalls, 1)
        XCTAssertEqual(request.module, "daily_fortune")
        XCTAssertEqual(request.contentHash, "s09_hour_unknown")
        XCTAssertEqual(request.context["day_master_strength"]?.value as? String, "unknown_hour",
                       "后端 S09 切降级模板的分支信号必须原样进 context")
        XCTAssertEqual(request.context["day_master"]?.value as? String, "甲",
                       "日柱在 → 日主保留(降级叙事轴)")
        XCTAssertEqual(request.context["favorable_elements"]?.value as? String, "",
                       "S01 契约:无时辰盘喜忌留空(REQUIRED 对 unknown_hour 免检)")
    }

    func test无时辰日柱在_builder17键全量_缺柱不缺key() throws {
        // S05「key 只增不删」:REQUIRED ⊆ builder keys 校验恒 PASS——
        // 即使缺时柱,17 个 context key 一个不少(值可为占位/空)
        let bazi = try seedChart(hash: "s09_ctx_keys", hourKnown: false, dayPresent: true)
        let payload = ChartPayloadDTO.from(baziResponse: bazi)
        let context = PromptContextBuilder.buildDailyFortune(
            chartPayload: payload,
            response: RecordingDailyAPIClient.fixtureResponse,
            businessDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let requiredKeys = [
            "day_master", "day_master_element", "day_master_strength",
            "favorable_elements", "unfavorable_elements",
            "date", "lunar_date",
            "day_pillar", "day_stem", "day_stem_element",
            "day_branch", "day_branch_element",
            "day_relation", "day_chong",
            "hour_pillars_with_relations",
            "huangli_yi", "huangli_ji",
        ]
        for key in requiredKeys {
            XCTAssertNotNil(context[key], "daily_fortune REQUIRED key \(key) 缺柱盘也必须在")
        }
        XCTAssertEqual(context["day_master_strength"]?.value as? String, "unknown_hour")
    }

    // MARK: - R3:ChartPayloadDTO.from 显式处理(S05 修订版 item 4,2026-09-01 review)

    func testR3_无时辰盘_strength透传unknown_hour_四柱缺hour键() {
        // unknown_hour 就是 unknown_hour:禁止 `?? "special_pattern"` 伪装成从格盘(假精度)
        let bazi = Self.makeResponse(hash: "r3_hour_unknown", hourKnown: false, dayPresent: true)
        let payload = ChartPayloadDTO.from(baziResponse: bazi)

        XCTAssertEqual(payload.dayMasterStrength, "unknown_hour",
                       "无时辰盘 strength 必须透传(后端按它切降级模板),不得伪装 special_pattern")
        XCTAssertEqual(payload.dayMaster, "甲", "日柱在 → 日主保留(降级叙事轴)")
        XCTAssertEqual(payload.dayMasterElement, "wood")
        XCTAssertEqual(payload.favorableElements, [], "S01 契约:无时辰盘喜忌留空")
        XCTAssertEqual(payload.unfavorableElements, [])
        XCTAssertEqual(Set(payload.fourPillars.keys), ["year", "month", "day"],
                       "hour 缺失 → four_pillars 不下发 hour 键(显式缺失,不猜)")
        XCTAssertEqual(payload.fourPillars["day"]?.gan, "甲")
    }

    func testR3_日柱歧义盘_缺day键_dayMaster空串_strength透传() {
        let bazi = Self.makeResponse(hash: "r3_day_ambiguous", hourKnown: false, dayPresent: false)
        let payload = ChartPayloadDTO.from(baziResponse: bazi)

        XCTAssertEqual(payload.dayMasterStrength, "unknown_hour", "歧义盘同样透传,不伪装从格")
        XCTAssertEqual(payload.dayMaster, "", "无日主 → 空串 + 显式日志(不猜),上游 S09/S11 拦截")
        XCTAssertEqual(Set(payload.fourPillars.keys), ["year", "month"], "day/hour 键均省略")
    }

    func testR3_异常存档strength为nil_不伪装special_pattern_显式降级unknown_hour() {
        // 引擎恒输出五值之一,nil 只出现在防御位/异常存档——错误显式传播惯例:
        // 显式 warning + 诚实安全值 unknown_hour(旺衰未判定),不伪装成任何已判定结论
        let bazi = Self.makeResponse(hash: "r3_nil_strength", hourKnown: true, strength: .some(nil))
        XCTAssertNil(bazi.dayMasterStrength, "夹具自检:双层 Optional 注入 nil 生效")

        let payload = ChartPayloadDTO.from(baziResponse: bazi)
        XCTAssertEqual(payload.dayMasterStrength, "unknown_hour",
                       "nil strength → 诚实降级 unknown_hour(旺衰未判定),绝不伪装 special_pattern")
        XCTAssertEqual(Set(payload.fourPillars.keys), ["year", "month", "day", "hour"],
                       "柱齐全的异常存档四柱照常下发")
    }

    func testR3_有时辰盘_逐字段与现状一致() {
        // 回归:老路径(四柱齐全 + strength="balanced")输出逐字段不变
        let bazi = Self.makeResponse(hash: "r3_known_hour", hourKnown: true, dayPresent: true)
        let payload = ChartPayloadDTO.from(baziResponse: bazi)

        XCTAssertEqual(payload.dayMaster, "甲")
        XCTAssertEqual(payload.dayMasterElement, "wood")
        XCTAssertEqual(payload.dayMasterStrength, "balanced")
        XCTAssertEqual(payload.favorableElements, ["木", "水"])
        XCTAssertEqual(payload.unfavorableElements, ["土"])
        XCTAssertEqual(Set(payload.fourPillars.keys), ["year", "month", "day", "hour"])
        XCTAssertEqual(payload.fourPillars["hour"]?.gan, "甲")
        XCTAssertEqual(payload.fourPillars["hour"]?.zhi, "子")
        XCTAssertNil(payload.luckPillars, "daily-fortune 路径不带扩展字段")
        XCTAssertNil(payload.calcRuleSnapshot)
    }

    // MARK: - R5:onboarding 落地每日运势 Tab(S07 修订版新验收;二期终态下仅日柱歧义类零请求)

    func testR5_RootTabView默认落地Tab为每日运势() {
        // S07 前提守护:无时辰用户第一眼落在每日运势 Tab(2026-08-01 决策 #17,
        // 冷启动默认;onboarding CTA 2026-08-31 拍板改落 deepAnalysis,默认不动)
        XCTAssertEqual(RootTabView.defaultTab, .dailyFortune)
    }

    func testR5_日柱确定无时辰盘_dailyFortune请求体契约合法_不会422() async throws {
        // 「不 422」落在请求体上断言:strength ∈ 后端 Literal(five 值之一)、
        // day_master 非空、four_pillars 含 day 缺 hour——后端 53180a1 契约无 key 校验
        try seedChart(hash: "r5_day_determined", hourKnown: false, dayPresent: true)

        vm.onAppear(currentChartHash: "r5_day_determined", ziHourRule: "zi_next_day")
        let ready = await waitForState {
            if case .ready = $0 { return true }
            return false
        }
        XCTAssertTrue(ready, "日柱确定的无时辰用户走降级生成(S09),实际:\(vm.state)")

        let lastRequest = await api.lastDailyFortuneRequest()
        let request = try XCTUnwrap(lastRequest, "daily-fortune 排盘请求必须已发出")
        let payload = request.chartPayload
        XCTAssertEqual(payload.dayMasterStrength, "unknown_hour", "后端 Literal 五值之一(降级信号)")
        XCTAssertEqual(payload.dayMaster, "甲", "日主非空(REQUIRED day_master)")
        XCTAssertEqual(payload.dayMasterElement, "wood", "五行英文 key(REQUIRED day_master_element)")
        XCTAssertEqual(Set(payload.fourPillars.keys), ["year", "month", "day"],
                       "hour 键省略是契约允许的显式缺失(S01),非 422 形态")
    }

    func testR5_日柱歧义落地每日运势Tab_视图渲染拦截页_零网络请求_不白屏不crash() async throws {
        // 走完 onboarding(chart 已存档 + link 已建)→ 落地默认 Tab(每日运势)。
        // 视图级路径断言:task → resolveCurrentChart → onAppear → runFullPipeline
        // 在阶段 1 之前拦截;整条链零网络请求(daily-fortune / interpret 计数 = 0),
        // 渲染非白屏(快照含多色内容),宿主布局全程不 crash。
        let env = AppEnvironment(
            modelContainer: container,
            apiClient: api,
            useMockClient: false
        )
        try seedChart(hash: "r5_landing_ambiguous", hourKnown: false, dayPresent: false)
        _ = try env.userSnapshotLinkStore.upsert(
            userId: UserIdentity.userLocalId,
            snapshotHash: "r5_landing_ambiguous",
            alias: "我自己"
        )

        let host = UIHostingController(rootView: DailyFortuneView().environmentObject(env))
        let window = UIWindow(frame: CGRect(origin: .zero, size: CGSize(width: 393, height: 852)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        defer { host.view.removeFromSuperview() }

        // 拦截链路全本地(ms 级),留 1.5s 让 .task → runFullPipeline → .hourAmbiguousBlocked 落定
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // 不白屏:渲染快照必须含多色内容(纯背景色 = 白屏;导航标题「每日运势」
        // + 朱印 + 拦截文案都是墨色系内容)
        let png = try XCTUnwrap(Self.snapshotPng(host.view), "拦截页快照渲染失败")
        let distinctColors = try Self.distinctSampledColors(png: png)
        XCTAssertGreaterThanOrEqual(distinctColors, 3,
                                    "落地屏渲染内容不足(\(distinctColors) 色)——疑似白屏")

        // 零网络请求:两类请求都不发起(ChartPayloadDTO.from 后的网关在阶段 1 之前)
        let dailyCalls = await api.dailyFortuneCallCount()
        let interpretCalls = await api.interpretCallCount()
        XCTAssertEqual(dailyCalls, 0, "日柱歧义盘落地每日运势 Tab 不得发起 daily-fortune 排盘请求")
        XCTAssertEqual(interpretCalls, 0, "日柱歧义盘落地每日运势 Tab 不得发起 interpret 请求")
    }

    // MARK: - 视图级落地断言 helper(R5「不白屏」检测,PaywallLayoutTests 同款手法)

    /// 离屏渲染快照(需要 window 参与,否则 SwiftUI 不跑 layout)。
    private static func snapshotPng(_ view: UIView) -> Data? {
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        return renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }.pngData()
    }

    /// 采样像素统计去重色数(量化 4bit/通道;纯背景屏 = 1 色,含文字内容 ≥ 3 色)。
    /// 「不白屏」的粗判据:白屏只有背景色,拦截页有浓墨标题 + 灰说明 + 朱印多色。
    private static func distinctSampledColors(png: Data) throws -> Int {
        guard let cg = UIImage(data: png)?.cgImage else {
            throw NSError(
                domain: "DailyFortuneHourUnknownGateTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "快照 PNG 解码失败"]
            )
        }
        let width = cg.width
        let height = cg.height
        guard width > 0, height > 0 else {
            throw NSError(
                domain: "DailyFortuneHourUnknownGateTests", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "快照尺寸为 0"]
            )
        }
        var bitmap = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(
            data: &bitmap, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(
                domain: "DailyFortuneHourUnknownGateTests", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "位图上下文创建失败"]
            )
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var colors = Set<UInt32>()
        let totalPixels = width * height
        let stride = max(1, totalPixels / 20_000)  // 采样约 2 万像素
        var pixel = 0
        while pixel < totalPixels {
            let offset = pixel * 4
            if offset + 2 < bitmap.count {
                let r = UInt32(bitmap[offset] >> 4)
                let g = UInt32(bitmap[offset + 1] >> 4)
                let b = UInt32(bitmap[offset + 2] >> 4)
                colors.insert(r << 8 | g << 4 | b)
            }
            pixel += stride
        }
        return colors.count
    }

    // MARK: - 有时辰:回归(链路与现状一致)

    func test有时辰_回归_排盘与interpret照常_上下文正常语义() async throws {
        try seedChart(hash: "s09_known_hour", hourKnown: true)

        vm.onAppear(currentChartHash: "s09_known_hour", ziHourRule: "zi_next_day")

        let ready = await waitForState {
            if case .ready = $0 { return true }
            return false
        }
        XCTAssertTrue(ready, "有时辰用户与现状完全一致,实际:\(vm.state)")
        XCTAssertEqual(vm.hourGate, .hourKnown, "零拦截,末尾提示位不显示")

        vm.generateInterpretation(currentChartHash: "s09_known_hour")
        let interpreted = await waitForState {
            if case .ready(_, let interp, _) = $0 {
                if case .okFree = interp { return true }
            }
            return false
        }
        XCTAssertTrue(interpreted, "有时辰解读照常,实际:\(vm.state)")

        let lastRequest = await api.lastInterpretRequest()
        let request = try XCTUnwrap(lastRequest)
        XCTAssertEqual(request.context["day_master_strength"]?.value as? String, "balanced",
                       "正常 context 不带 unknown_hour(后端主模板)")
        XCTAssertEqual(request.context["favorable_elements"]?.value as? String, "木, 水")
    }

    // MARK: - 历史/缓存(S09 item 6:S01 hash 分叉语义自动适配,验证)

    func test历史回看_无时辰盘_快照缓存与重建照常不crash() throws {
        // S01 分叉后的新 content_hash 对日粒度缓存是普通 key:upsert /
        // fresh 判据 / 7 天历史 / response(from:) 重建对降级内容照常工作
        let hash = "s09_hist_hour_unknown"
        let today = Calendar.current.startOfDay(for: .now)
        for offset in 0..<3 {
            try dailyStore.upsert(
                chartHash: hash,
                targetDate: today.addingTimeInterval(Double(-offset) * 86_400),
                response: RecordingDailyAPIClient.fixtureResponse,
                interpretation: "降级版解读 \(offset)",
                cachedUntil: .now.addingTimeInterval(3600)
            )
        }

        // fresh 判据照常(24h/日粒度语义不因缺柱变化)
        let fresh = try XCTUnwrap(
            dailyStore.getCachedIfFresh(chartHash: hash, targetDate: today),
            "无时辰盘当日快照 fresh 判据照常命中"
        )
        XCTAssertEqual(fresh.interpretation, "降级版解读 0")

        // 7 天历史照常返回降级内容
        let history = try vm.loadHistory(chartHash: hash)
        XCTAssertEqual(history.count, 3, "历史回看对无时辰盘照常(降级内容)")

        // 重建(历史回看显示路径):12 时辰条/明日预告 decode 不因缺柱 crash
        let restored = try dailyStore.response(from: history[0])
        XCTAssertEqual(restored.dayPillar, "丙子")
        XCTAssertEqual(restored.dayRelationToDayMaster, "偏印")
        XCTAssertEqual(restored.hourPillars.count, 1)
        XCTAssertEqual(restored.tomorrowPreview.dayPillar, "丁丑")
    }
}

// MARK: - Test Double

private enum DailyTestError: Error {
    case unexpectedCall
}

/// 记录型 API 双打:只实现每日运势链路需要的三个端点(health / dailyFortune /
/// interpret),其余端点被调即抛错(证明拦截态零请求的负向哨兵)。
private actor RecordingDailyAPIClient: APIClient {
    private var dailyFortuneRequests: [DailyFortuneRequest] = []
    private var interpretRequests: [InterpretRequest] = []

    func dailyFortuneCallCount() -> Int { dailyFortuneRequests.count }
    func interpretCallCount() -> Int { interpretRequests.count }
    func lastInterpretRequest() -> InterpretRequest? { interpretRequests.last }
    func lastDailyFortuneRequest() -> DailyFortuneRequest? { dailyFortuneRequests.last }

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
        dailyFortuneRequests.append(request)
        return Self.fixtureResponse
    }

    func interpret(request: InterpretRequest) async throws -> InterpretResponse {
        interpretRequests.append(request)
        return InterpretResponse(
            interpretation: "降级版运势解读(mock):今日流日与你的日主呈偏印关系。",
            promptVersion: 3,
            cached: false,
            generatedAt: .now,
            provider: "anthropic",
            model: "claude-test",
            language: AppLanguage.current
        )
    }

    /// 降级链路可复用的确定性响应夹具(日柱/关系/12 时辰条/黄历全量;
    /// 无时辰盘的流日本身与出生时辰无关)。
    static let fixtureResponse = DailyFortuneResponse(
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

    func calculateBazi(request: BaziCalculateRequest) async throws -> BaziResponse {
        throw DailyTestError.unexpectedCall
    }
    func compatibility(request: CompatibilityRequest) async throws -> CompatibilityResponse {
        throw DailyTestError.unexpectedCall
    }
    func dailyImageStatus(request: DailyFortuneRequest) async throws -> DailyImageStatusDTO {
        throw DailyTestError.unexpectedCall
    }
    func dailyImageContent(chartHash: String, targetDate: String) async throws -> (data: Data, statusCode: Int) {
        throw DailyTestError.unexpectedCall
    }
    func redeem(request: EntitlementRedeemRequest) async throws -> EntitlementRedeemResponse {
        throw DailyTestError.unexpectedCall
    }
    func entitlementList() async throws -> EntitlementListResponse {
        throw DailyTestError.unexpectedCall
    }
    func signIn(request: SignInRequest) async throws -> SignInResponse {
        throw DailyTestError.unexpectedCall
    }
    func syncPull() async throws -> SyncPullResponse {
        throw DailyTestError.unexpectedCall
    }
    func syncPush(request: SyncPushRequest) async throws -> SyncPushResponse {
        throw DailyTestError.unexpectedCall
    }
}
