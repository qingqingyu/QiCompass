import SwiftData
import SwiftUI
import XCTest
@testable import QiCompass

/// S03 深度解析表单 VM 测试:必选城市校验 + 请求构造(裸钟面 / timezone / 经纬度)。
/// S04 追加:时辰未知入口状态机(D1)+ 二值半夜三态(D3)+ hour_known 契约字段
/// + payload 存档(decodeIfPresent 老盘兼容)。
///
/// 对应 S03/S05 验收:
/// - 未选出生地提交 → 「请选择出生城市」;无任何默认城市
/// - 选中城市后 `birthDatetime` 为出生城市裸钟面(WYSIWYG),timezone/经纬度来自城市记录
/// - S05 自定义地点:timezone 显式必选(城市/自定义地点两分支)
@MainActor
final class DeepAnalysisViewModelFormTests: XCTestCase {

    private var container: ModelContainer!
    private var vm: DeepAnalysisViewModel!
    private var apiClient: MockAPIClient!
    private var chartStore: ChartSnapshotStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        apiClient = MockAPIClient()
        chartStore = ChartSnapshotStore(context: context)
        let interpretStore = InterpretationCacheStore(context: context)
        let identityResolver = AIIdentityResolver(apiClient: apiClient)
        let counter = DailyReadCounter.makeIsolatedForTesting()
        let reader = CachedInterpretationReader(
            identityResolver: identityResolver,
            cacheStore: interpretStore
        )
        let orchestrator = DeepAnalysisOrchestrator(
            apiClient: apiClient,
            chartStore: chartStore,
            interpretStore: interpretStore,
            counter: counter,
            interpretationReader: reader,
            userLinkStore: UserSnapshotLinkStore(context: context)
        )
        let entitlementStore = EntitlementStore(modelContext: context)
        vm = DeepAnalysisViewModel(
            orchestrator: orchestrator,
            entitlementStore: entitlementStore
        )
    }

    override func tearDownWithError() throws {
        vm = nil
        chartStore = nil
        apiClient = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - 测试夹具

    /// 洛杉矶(GeoNames 5368361 字段的测试替身;id 用真实值便于追溯)
    private static let losAngeles = CityRecord(
        geonameId: 5368361,
        name: "Los Angeles",
        nameZh: "洛杉矶",
        countryCode: "US",
        admin1Name: "加利福尼亚",
        countryNameZh: "美国",
        latitude: 34.0522,
        longitude: -118.2437,
        timezone: "America/Los_Angeles",
        population: 3_898_747,
        isCN: false
    )

    /// 北京(GeoNames 1816670)
    private static let beijing = CityRecord(
        geonameId: 1816670,
        name: "Beijing",
        nameZh: "北京",
        countryCode: "CN",
        admin1Name: nil,
        countryNameZh: "中国",
        latitude: 39.9042,
        longitude: 116.4074,
        timezone: "Asia/Shanghai",
        population: 11_716_620,
        isCN: true
    )

    /// 与 VM 提取逻辑独立的钟面期望值计算(Calendar components,不走 DateFormatter)。
    private static func expectedWall(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!
        )
    }

    // MARK: - 必选校验(砍「北京」默认)

    func testValidateNoPlaceRequiresCity() {
        vm.selectedPlace = nil
        let errors = vm.validateForm()
        XCTAssertTrue(errors.contains("请选择出生城市"), "未选出生地 → 必须拦截: \(errors)")
        XCTAssertTrue(vm.selectedPlace == nil, "无任何默认城市(初始态必须 nil)")
    }

    func testValidatePlaceSelectedPasses() {
        vm.selectedPlace = .city(Self.losAngeles)
        vm.birthDate = Date(timeIntervalSince1970: 580_262_400) // 1988-05-15 前后,早于当下
        let errors = vm.validateForm()
        XCTAssertFalse(errors.contains("请选择出生城市"), errors.description)
    }

    func testValidateCustomPlaceSkipsCityRequirement() {
        vm.selectedPlace = .custom(longitude: 116.41, timezone: "Asia/Shanghai")
        XCTAssertFalse(vm.validateForm().contains("请选择出生城市"))
        // 越界经度仍拦截
        vm.selectedPlace = .custom(longitude: 200, timezone: "Asia/Shanghai")
        XCTAssertTrue(vm.validateForm().contains("经度需在 -180 到 180 之间"))
    }

    // MARK: - 请求构造(S02 契约:裸钟面 + timezone + 物理真值)

    func testBuildRequestExtractsWallClockInPlaceTimezone() throws {
        let birth = Date(timeIntervalSince1970: 580_262_400)
        vm.birthDate = birth
        // S03 拆双绑定:时分取 birthTime;令其= birth 以便断言完整合成钟面(日期+时分同源)
        vm.birthTime = birth
        vm.selectedPlace = .city(Self.losAngeles)

        let request = try vm.buildRequest()

        let laTZ = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(request.birthDatetime, Self.expectedWall(birth, timeZone: laTZ),
                       "birthDatetime 必须是洛杉矶裸钟面(WYSIWYG),非设备时区钟面")
        XCTAssertEqual(request.timezone, "America/Los_Angeles")
        XCTAssertEqual(request.longitude, Self.losAngeles.longitude, accuracy: 1e-9)
        XCTAssertEqual(request.latitude ?? 0, Self.losAngeles.latitude, accuracy: 1e-9)
        XCTAssertEqual(request.placeName, "洛杉矶")
        XCTAssertEqual(request.geonameId, 5368361)
    }

    func testBuildRequestWallClockDiffersAcrossTimezones() throws {
        // 同一绝对时刻,北京与洛杉矶钟面必须不同(防「钟面提取其实用了设备时区」的假绿)
        let birth = Date(timeIntervalSince1970: 580_262_400)
        vm.birthDate = birth
        vm.birthTime = birth // S03:时分锚同源,断言完整合成钟面

        vm.selectedPlace = .city(Self.losAngeles)
        let laWall = try vm.buildRequest().birthDatetime
        vm.selectedPlace = .city(Self.beijing)
        let bjWall = try vm.buildRequest().birthDatetime

        let laTZ = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let bjTZ = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(laWall, Self.expectedWall(birth, timeZone: laTZ))
        XCTAssertEqual(bjWall, Self.expectedWall(birth, timeZone: bjTZ))
        XCTAssertNotEqual(laWall, bjWall)
    }

    func testBuildRequestCustomPlaceUsesExplicitTimezone() throws {
        // S05 自定义地点:timezone 显式必选(不再默认设备时区),物理值=手输经度
        vm.birthDate = Date(timeIntervalSince1970: 580_262_400) // S03 日期必选:buildRequest 前置非空
        vm.selectedPlace = .custom(longitude: 87.62, timezone: "Asia/Urumqi")
        let request = try vm.buildRequest()
        XCTAssertEqual(request.timezone, "Asia/Urumqi")
        XCTAssertEqual(request.longitude, 87.62, accuracy: 1e-9)
        XCTAssertNil(request.latitude)
        XCTAssertEqual(request.placeName, "自定义地点")
        XCTAssertNil(request.geonameId)
    }

    func testBuildRequestCustomPlaceExplicitFields() throws {
        // S05:自定义地点回显 / 时区简写(Etc/GMT-8 = UTC+8 反符号)
        let custom = PlaceSelection.custom(longitude: 117.3, timezone: "Etc/GMT-8")
        XCTAssertEqual(custom.displayLabel, "自定义地点 · GMT+8")
        XCTAssertEqual(custom.timezone, "Etc/GMT-8")
        XCTAssertTrue(custom.isCustomLongitudeValid)
        XCTAssertFalse(PlaceSelection.custom(longitude: 200, timezone: "Etc/GMT-8").isCustomLongitudeValid)
        vm.birthDate = Date(timeIntervalSince1970: 580_262_400) // S03 日期必选:buildRequest 前置非空
        vm.selectedPlace = custom
        let request = try vm.buildRequest()
        XCTAssertEqual(request.timezone, "Etc/GMT-8")
        XCTAssertEqual(request.longitude, 117.3, accuracy: 1e-9)
    }

    func testPlaceCalendarUsesCustomPlaceTimezone() {
        // WYSIWYG 同源:自定义地点表盘 = 其显式时区(与 buildRequest 的 timezone 一致)
        vm.selectedPlace = .custom(longitude: 87.62, timezone: "Asia/Urumqi")
        XCTAssertEqual(vm.placeCalendar.timeZone.identifier, "Asia/Urumqi",
                       "自定义地点表盘必须用显式时区")
    }

    // MARK: - 时辰快捷选挂城市时区(WYSIWYG;S03 起改写时刻绑定)

    func testSetShichenHourWritesTimeBindingOnly() throws {
        vm.selectedPlace = .city(Self.losAngeles)
        vm.setShichenHour(10)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(calendar.component(.hour, from: vm.birthTime), 10,
                       "setShichenHour 后洛杉矶钟面小时必须是指定值(中点小时)")
        XCTAssertEqual(calendar.component(.minute, from: vm.birthTime), 0)
        XCTAssertNil(vm.birthDate, "时辰快捷选只改时刻绑定;日期未选态不得被伪造(S03 拆双绑定)")
    }

    func testPlaceCalendarFallsBackToCurrentWhenNoPlace() {
        vm.selectedPlace = nil
        XCTAssertEqual(vm.placeCalendar.timeZone.identifier, Calendar.current.timeZone.identifier)
    }

    // MARK: - S03 日期必选(D8 默认日期洞修复)

    func testValidateRequiresBirthDateWhenUnselected() {
        // 全新表单不碰日期:日期错误出现;城市未选时两条错误并列展示
        vm.selectedPlace = nil
        let errors = vm.validateForm()
        XCTAssertTrue(errors.contains(L10n.BirthForm.errorDateRequired),
                      "未选择出生日期 → 必须拦截: \(errors)")
        XCTAssertTrue(errors.contains("请选择出生城市"),
                      "日期与城市错误须并列展示: \(errors)")
        XCTAssertEqual(errors.count, 2, "未选日期 + 未选城市 = 恰两条,不混入其他错误: \(errors)")
    }

    func testCalculateWithoutDateBlockedAndNoRequest() {
        // 不碰日期直接提交 → formInvalid,不发起网络请求(lastRequest 不落)
        vm.selectedPlace = .city(Self.losAngeles)
        vm.calculate()
        guard case .formInvalid(let errors) = vm.state else {
            return XCTFail("未选日期提交必须停在 formInvalid,实际: \(vm.state)")
        }
        XCTAssertTrue(errors.contains(L10n.BirthForm.errorDateRequired), errors.description)
        XCTAssertNil(vm.lastRequest, "校验失败不得构造/发出请求")
    }

    func testBuildRequestThrowsWhenDateMissing() {
        // 显式抛错,不静默兜底(错误显式传播)
        vm.selectedPlace = .city(Self.losAngeles)
        XCTAssertThrowsError(try vm.buildRequest(), "birthDate 未选择时 buildRequest 必须抛错")
    }

    func testValidateFutureCombinedDateTimeStillBlocked() {
        // 「不晚于当下」校验保留:按日期+时刻合成值判定
        vm.selectedPlace = .city(Self.beijing)
        vm.birthDate = Date(timeIntervalSince1970: 4_102_244_000) // 2100-01-01 前后,远晚于当下
        vm.setShichenHour(10)
        XCTAssertTrue(vm.validateForm().contains("出生时间不能晚于当下"))
    }

    func testUntouchedTimeKeepsDefaultTimeSemantics() throws {
        // 日期已选 + 时刻未碰 → 正常提交;时刻默认值语义与现状一致(旧默认 instant 的钟面时分)
        let birth = Date(timeIntervalSince1970: 580_262_400)
        vm.birthDate = birth
        vm.selectedPlace = .city(Self.losAngeles)
        let request = try vm.buildRequest()

        let laTZ = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = laTZ
        var expected = calendar.dateComponents([.year, .month, .day], from: birth)
        let defaultTime = calendar.dateComponents([.hour, .minute], from: DeepAnalysisViewModel.defaultBirthTimeAnchor)
        expected.hour = defaultTime.hour
        expected.minute = defaultTime.minute
        expected.second = 0
        XCTAssertEqual(
            request.birthDatetime,
            String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                   expected.year!, expected.month!, expected.day!, expected.hour!, expected.minute!, expected.second!),
            "日期分量取 birthDate、时分分量取默认 birthTime、秒归零(合成语义)"
        )
    }

    // MARK: - S03 确认 sheet / 表单两行的数值一致性(wallBirthDateString / wallBirthTimeString)

    func testConfirmSheetStringsMatchRequestValues() throws {
        vm.birthDate = Date(timeIntervalSince1970: 580_262_400)
        vm.selectedPlace = .city(Self.losAngeles)
        vm.setShichenHour(10) // 时辰快捷选生效 → 10:00

        let request = try vm.buildRequest()
        let dateStr = try XCTUnwrap(vm.wallBirthDateString, "已选日期 → 展示串非 nil")
        let timeStr = vm.wallBirthTimeString

        XCTAssertEqual(timeStr, "10:00", "时辰快捷选中点小时须体现在时刻串")
        XCTAssertTrue(request.birthDatetime.hasPrefix(dateStr),
                      "确认 sheet 日期值与提交值同源: \(request.birthDatetime) vs \(dateStr)")
        XCTAssertTrue(request.birthDatetime.dropFirst(11).hasPrefix(timeStr),
                      "确认 sheet 时刻值与提交值同源: \(request.birthDatetime) vs \(timeStr)")
    }

    func testWallBirthDateStringNilWhenUnselected() {
        XCTAssertNil(vm.wallBirthDateString, "未选择日期 → nil(调用方展示占位,不伪造默认日期)")
        XCTAssertFalse(vm.wallBirthTimeString.isEmpty, "时刻串始终有默认值(默认锚点)")
    }

    // MARK: - S04 时辰未知入口(D1 单一入口)+ 二值半夜问题(D3)

    /// S04 夹具:合法日期 + 洛杉矶城市(两行都齐,只剩时辰未知维度可变)。
    private func filledForm() {
        vm.birthDate = Date(timeIntervalSince1970: 580_262_400) // 1988-05-15 前后,早于当下
        vm.selectedPlace = .city(Self.losAngeles)
    }

    func testHourKnownDefaultsToOldPath() throws {
        // 默认 = 老路径:hourKnown true、lateNight 不传(既有盘行为逐字段不变)
        filledForm()
        XCTAssertTrue(vm.hourKnown, "默认必须 true(老路径),否则存量表单语义漂移")
        XCTAssertNil(vm.lateNightChoice)
        let request = try vm.buildRequest()
        XCTAssertTrue(request.hourKnown)
        XCTAssertNil(request.lateNight)
    }

    func testHourUnknownWithoutChoiceBlockedAndNoRequest() {
        // 勾选「不知道」但三态未选 → formInvalid,不发起请求(不默认「不确定」)
        filledForm()
        vm.setHourKnown(false)
        vm.calculate()
        guard case .formInvalid(let errors) = vm.state else {
            return XCTFail("三态未选提交必须停在 formInvalid,实际: \(vm.state)")
        }
        XCTAssertTrue(errors.contains(L10n.BirthForm.errorLateNightRequired), errors.description)
        XCTAssertNil(vm.lastRequest, "三态未选不得构造/发出请求")
    }

    func testHourUnknownChoiceNoSendsFalseAndNoonPlaceholder() throws {
        // 三态「否」→ hour_known=false + late_night=false;时辰显式 12:00 占位(忽略 birthTime)
        filledForm()
        vm.setShichenHour(10) // 时刻绑定设为 10:00 —— 必须被 flag 否定
        vm.setHourKnown(false)
        vm.lateNightChoice = .no
        let request = try vm.buildRequest()
        XCTAssertFalse(request.hourKnown)
        XCTAssertEqual(request.lateNight, false)
        XCTAssertTrue(request.birthDatetime.hasSuffix("T12:00:00"),
                      "hour_known=false 时时辰部分必须显式 12:00(后端归一同值),实际: \(request.birthDatetime)")
    }

    func testHourUnknownChoiceYesSendsTrue() throws {
        filledForm()
        vm.setHourKnown(false)
        vm.lateNightChoice = .yes
        let request = try vm.buildRequest()
        XCTAssertFalse(request.hourKnown)
        XCTAssertEqual(request.lateNight, true)
        XCTAssertTrue(request.birthDatetime.hasSuffix("T12:00:00"))
    }

    func testHourUnknownChoiceUnsureOmitsLateNightKey() throws {
        // 三态「不确定」→ wire 值 nil 且编码省略 key(encodeIfPresent,契约两可取不传)
        filledForm()
        vm.setHourKnown(false)
        vm.lateNightChoice = .unsure
        let request = try vm.buildRequest()
        XCTAssertNil(request.lateNight)
        let json = try APICoder.encoder.encode(request)
        let jsonStr = String(data: json, encoding: .utf8) ?? ""
        XCTAssertFalse(jsonStr.contains("late_night"),
                       "不确定 → late_night key 必须整体省略,不是显式 null: \(jsonStr)")
        XCTAssertTrue(jsonStr.contains("\"hour_known\":false"), "hour_known 恒显式传: \(jsonStr)")
    }

    func testUncheckHourUnknownRestoresTimeAndResetsChoice() throws {
        // 取消勾选 → 时刻行恢复(birthTime 语义回来)+ 三态答案作废 + 走 hour_known=true 原路径
        filledForm()
        vm.setShichenHour(10)
        vm.setHourKnown(false)
        vm.lateNightChoice = .yes
        vm.setHourKnown(true)
        XCTAssertNil(vm.lateNightChoice, "取消勾选必须重置三态(答案不跨态残留)")
        XCTAssertNil(vm.lateNight)
        let request = try vm.buildRequest()
        XCTAssertTrue(request.hourKnown)
        XCTAssertNil(request.lateNight)
        XCTAssertTrue(request.birthDatetime.hasSuffix("T10:00:00"),
                      "恢复已知路径后时分必须取 birthTime(10:00),实际: \(request.birthDatetime)")
    }

    func testHourUnknownFutureCheckUsesDateGranularity() {
        // 时辰未知时「不晚于当下」按日期粒度:未来日拦截;当日不因 12:00 占位误拦
        filledForm()
        vm.setHourKnown(false)
        vm.lateNightChoice = .no
        vm.birthDate = Date(timeIntervalSince1970: 4_102_244_000) // 2100-01-01 前后
        XCTAssertTrue(vm.validateForm().contains("出生时间不能晚于当下"))

        vm.birthDate = Date() // 当下:时辰未知,当日出生合法(不能拿 12:00 占位当真实时刻比)
        XCTAssertFalse(vm.validateForm().contains("出生时间不能晚于当下"))
    }

    func testConfirmBirthTimeTextCoversAllStates() {
        // 已知 → HH:mm;未知+已答 → 未知(半夜:是/否/不确定);未知未答 → 诚实展示未答
        // 期望值用 L10n 组合(与实现同源不同路:一个走 VM、一个走格式函数),不写死语言字面量
        filledForm()
        vm.setShichenHour(10)
        XCTAssertEqual(vm.confirmBirthTimeText, vm.wallBirthTimeString, "已知路径展示串不变")

        vm.setHourKnown(false)
        vm.lateNightChoice = .yes
        XCTAssertEqual(vm.confirmBirthTimeText, L10n.BirthForm.confirmTimeUnknown(L10n.BirthForm.lateNightYes))

        vm.lateNightChoice = .unsure
        XCTAssertEqual(vm.confirmBirthTimeText, L10n.BirthForm.confirmTimeUnknown(L10n.BirthForm.lateNightUnsure))

        vm.lateNightChoice = nil // 确认 sheet 先于校验可见(onSubmit → sheet → calculate)
        XCTAssertEqual(vm.confirmBirthTimeText, L10n.BirthForm.confirmTimeUnknownNoAnswer)
    }

    // MARK: - S04 ChartSnapshot 存档(hour_known / late_night 入 payload)

    func testUpsertArchivesHourKnownAndLateNight() async throws {
        // 全链路:hour_known=false 请求 → mock 响应(calcRule 回显)→ upsert 注入 late_night
        filledForm()
        vm.setHourKnown(false)
        vm.lateNightChoice = .no
        let request = try vm.buildRequest()

        let response = try await apiClient.calculateBazi(request: request)
        _ = try chartStore.upsert(response: response, request: request)

        let snapshot = try XCTUnwrap(chartStore.get(contentHash: response.contentHash))
        let decoded = try chartStore.decodeResponse(from: snapshot)
        XCTAssertFalse(decoded.isHourKnown, "payload 的 calc_rule_snapshot.hour_known 必须存档 false")
        XCTAssertEqual(decoded.calcRuleSnapshot.hourKnown, false)
        XCTAssertEqual(decoded.lateNight, false, "late_night(后端不回显)必须由 upsert 从 request 注入存档")
    }

    func testLegacyPayloadWithoutNewKeysDecodesAsHourKnown() async throws {
        // 2026-08-15 教训回归:老盘 payload 缺 hour_known/late_night key → 解码不 crash,
        // 且按 hour_known=true 处理(decodeIfPresent ?? true,非 keyNotFound)
        filledForm()
        let request = try vm.buildRequest()
        let response = try await apiClient.calculateBazi(request: request)

        var json = try JSONSerialization.jsonObject(with: APICoder.encoder.encode(response)) as? [String: Any]
        json?.removeValue(forKey: "late_night")
        var calcRule = json?["calc_rule_snapshot"] as? [String: Any]
        calcRule?.removeValue(forKey: "hour_known")
        json?["calc_rule_snapshot"] = calcRule
        let legacyData = try JSONSerialization.data(withJSONObject: XCTUnwrap(json, "mock 响应必须是可变 JSON 对象"))

        let decoded = try APICoder.decoder.decode(BaziResponse.self, from: legacyData)
        XCTAssertTrue(decoded.isHourKnown, "老盘缺 hour_known key → 视为 true")
        XCTAssertNil(decoded.lateNight, "老盘缺 late_night key → nil 不 crash")
    }

    // MARK: - S05 DTO Optional 化(null / 缺字段 / 正常 三态解码)

    /// 单柱 JSON 夹具(zhi=子,供 legacy 生肖兜底断言复用)
    private static let pillarJSON: [String: Any] = [
        "gan_zhi": "甲子", "gan": "甲", "zhi": "子",
        "gan_element": "wood", "zhi_element": "water",
        "hide_gan": ["癸"], "shishen_gan": "比肩", "shishen_zhi": ["正印"],
        "nayin": "海中金", "dishi": "沐浴", "xunkong": "戌亥",
    ]

    /// S02 终态契约形状的响应 JSON(时辰未知 + 年/日柱歧义,显式 null 全量出现)
    private static func hourUnknownResponseJSON(pillars: [String: Any],
                                                includeZodiacKeys: Bool = true) throws -> Data {
        var json: [String: Any] = [
            "content_hash": "s05_hour_unknown",
            "true_solar_time": NSNull(),  // S01:占位真太阳时不漏响应
            "true_solar_offset_minutes": -14.4,
            "pillars": pillars,
            "ming_gong": ["gan_zhi": "甲子", "nayin": "海中金"],
            "shen_gong": ["gan_zhi": "甲子", "nayin": "海中金"],
            "tai_yuan": ["gan_zhi": "甲子", "nayin": "海中金"],
            "element_balance": ["wood": 2, "fire": 1, "earth": 1, "metal": 1, "water": 3],
            "favorable_elements": [],
            "unfavorable_elements": [],
            "day_master_strength": "unknown_hour",
            "tiaoshou_applied": false,
            "shensha": [],
            "shensha_incomplete": true,
            "pillar_ambiguity": ["year": true, "month": false, "day": true],
            "luck_pillars": [],
            "calc_rule_snapshot": [
                "library": "lunar_python", "sect": 1, "zi_hour_rule": "zi_next_day",
                "true_solar_longitude": 116.4, "true_solar_offset_minutes": -14.4,
                "schema_version": 1, "hour_known": false,
                "pillar_ambiguity": ["year": true, "month": false, "day": true],
            ] as [String: Any],
            "ten_god_weights": [String: Any](),
            "useful_god_candidates": [String](),
        ]
        if includeZodiacKeys {
            // S02:年柱歧义 → 生肖系显式 null(不是缺 key)
            json["year_branch_zodiac"] = NSNull()
            json["year_branch_friends"] = NSNull()
            json["year_branch_clash"] = NSNull()
        }
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testHourUnknownResponseDecodesExplicitNulls() throws {
        // 显式 null 全量:hour/day/year 柱 null + 真太阳时 null + 生肖系 null +
        // 歧义标记 + 神煞不完整标注(不变量:pillar_ambiguity.<pos>=true ⟺ 柱 null)
        let data = try Self.hourUnknownResponseJSON(pillars: [
            "year": NSNull(), "month": Self.pillarJSON,
            "day": NSNull(), "hour": NSNull(),
        ])
        let decoded = try APICoder.decoder.decode(BaziResponse.self, from: data)

        XCTAssertNil(decoded.pillars.hour, "hour_known=false → 时柱 null")
        XCTAssertNil(decoded.pillars.day, "日柱歧义 → 日柱 null")
        XCTAssertNil(decoded.pillars.year, "年柱歧义 → 年柱 null")
        XCTAssertEqual(decoded.pillars.month?.ganZhi, "甲子", "无歧义月柱照常解码")
        XCTAssertNil(decoded.trueSolarTime, "时辰未知 → 真太阳时 null(占位一致性)")
        // 显式 null ≠ 缺 key:生肖系原样透传 nil,不被 legacy 兜底覆盖(不猜)
        XCTAssertNil(decoded.yearBranchZodiac)
        XCTAssertNil(decoded.yearBranchFriends)
        XCTAssertNil(decoded.yearBranchClash)
        XCTAssertTrue(decoded.shenshaIncomplete, "神煞按三柱查的完整性标注")
        XCTAssertEqual(decoded.pillarAmbiguity, PillarAmbiguityDTO(year: true, month: false, day: true))
        XCTAssertEqual(decoded.calcRuleSnapshot.pillarAmbiguity, decoded.pillarAmbiguity,
                       "歧义标记进 calc_rule_snapshot(同 hash 可审计)")
        XCTAssertFalse(decoded.isHourKnown)
    }

    func testHourPillarKeyOmittedDecodesAsNil() throws {
        // 缺字段(非显式 null)路径:decodeIfPresent 不 crash
        let data = try Self.hourUnknownResponseJSON(pillars: [
            "year": Self.pillarJSON, "month": Self.pillarJSON, "day": Self.pillarJSON,
            // "hour" key 整体省略
        ])
        let decoded = try APICoder.decoder.decode(BaziResponse.self, from: data)
        XCTAssertNil(decoded.pillars.hour, "缺 hour key → nil(decodeIfPresent)")
        XCTAssertEqual(decoded.pillars.day?.zhi, "子")
    }

    func testLegacyPayloadMissingZodiacKeysFallsBackToYearZhi() throws {
        // 2026-08-15 教训回归:老缓存缺生肖三 key → pillars.year.zhi 查表兜底,
        // 行为与 S05 之前一致(含部分 key 的中间缓存按字段独立兜底)
        let data = try Self.hourUnknownResponseJSON(
            pillars: ["year": Self.pillarJSON, "month": Self.pillarJSON,
                      "day": Self.pillarJSON, "hour": Self.pillarJSON],
            includeZodiacKeys: false
        )
        let decoded = try APICoder.decoder.decode(BaziResponse.self, from: data)
        XCTAssertEqual(decoded.yearBranchZodiac, "Rat", "子 → Rat")
        XCTAssertEqual(decoded.yearBranchFriends, ["Ox", "Dragon", "Monkey"],
                       "六合丑 + 三合辰申(按地支序)")
        XCTAssertEqual(decoded.yearBranchClash, "Horse", "子午冲")
    }

    func testLegacyPayloadPartialZodiacKeysFallbackOnlyMissingOnes() throws {
        // 中间缓存:zodiac 有 key、friends/clash 缺 → 只兜底缺失的两个
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Self.hourUnknownResponseJSON(
                pillars: ["year": Self.pillarJSON, "month": Self.pillarJSON,
                          "day": Self.pillarJSON, "hour": Self.pillarJSON],
                includeZodiacKeys: false
            )) as? [String: Any]
        )
        json["year_branch_zodiac"] = "Rat"  // 只补回 zodiac key
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try APICoder.decoder.decode(BaziResponse.self, from: data)
        XCTAssertEqual(decoded.yearBranchZodiac, "Rat")
        XCTAssertEqual(decoded.yearBranchFriends, ["Ox", "Dragon", "Monkey"], "缺失 key 走兜底")
        XCTAssertEqual(decoded.yearBranchClash, "Horse")
    }

    // MARK: - S05 PromptContextBuilder unknown 分支

    private static let fixturePillar = PillarDTO(
        ganZhi: "甲子", gan: "甲", zhi: "子",
        ganElement: "wood", zhiElement: "water",
        hideGan: ["癸"], shishenGan: "比肩", shishenZhi: ["正印"],
        nayin: "海中金", dishi: "沐浴", xunkong: "戌亥"
    )

    private static func makeResponse(
        pillars: PillarsDTO,
        dayMasterStrength: String? = "balanced",
        trueSolarTime: Date? = Date(timeIntervalSince1970: 580_262_400),
        meta: MetaBlockDTO? = nil,
        hourKnown: Bool = true
    ) -> BaziResponse {
        BaziResponse(
            contentHash: "s05_ctx",
            trueSolarTime: trueSolarTime,
            trueSolarOffsetMinutes: -14.4,
            pillars: pillars,
            mingGong: GanZhiNaYinDTO(ganZhi: "甲子", nayin: "海中金"),
            shenGong: GanZhiNaYinDTO(ganZhi: "甲子", nayin: "海中金"),
            taiYuan: GanZhiNaYinDTO(ganZhi: "甲子", nayin: "海中金"),
            elementBalance: ElementBalanceDTO(wood: 2, fire: 1, earth: 1, metal: 1, water: 3),
            favorableElements: ["水"], unfavorableElements: ["土"],
            dayMasterStrength: dayMasterStrength,
            tiaoshouApplied: false,
            xijiMethod: "扶抑+调候", patternHint: nil,
            shensha: [],
            luckPillars: [],
            currentLuckPillar: nil,
            currentYearPillar: "甲子",
            currentDayPillar: nil, currentHourPillar: nil,
            calcRuleSnapshot: CalcRuleSnapshotDTO(
                library: "lunar_python", sect: 1, ziHourRule: "zi_next_day",
                trueSolarLongitude: 116.4, trueSolarOffsetMinutes: -14.4,
                schemaVersion: 1, hourKnown: hourKnown
            ),
            boundaryWarning: nil,
            yearBranchZodiac: "Rat",
            yearBranchFriends: ["Ox", "Dragon", "Monkey"],
            yearBranchClash: "Horse",
            meta: meta
        )
    }

    private static let fixtureRequest = BaziCalculateRequest(
        birthDatetime: "1988-05-15T12:00:00",
        timezone: "Asia/Shanghai",
        gender: "male",
        longitude: 116.4,
        latitude: 39.9,
        placeName: "北京",
        geonameId: nil,
        ziHourRule: "zi_next_day"
    )

    func testPromptContextBuilderHourUnknownPlaceholders() throws {
        // hour_known=false:全部 7 个 hour_* key(含 hour_nayin)走占位,
        // key 只增不删(REQUIRED ⊆ builder keys 校验恒 PASS)
        let response = Self.makeResponse(pillars: PillarsDTO(
            year: Self.fixturePillar, month: Self.fixturePillar,
            day: Self.fixturePillar, hour: nil
        ), trueSolarTime: nil, hourKnown: false)
        let context = PromptContextBuilder.build(response: response, request: Self.fixtureRequest)

        let hourKeys = ["hour_gan", "hour_zhi", "hour_gan_element", "hour_zhi_element",
                        "hour_shishen_gan", "hour_hide_gan", "hour_nayin"]
        for key in hourKeys {
            let value = try XCTUnwrap(context[key], "hour_known=false 时 \(key) 必须仍在(只增不删)")
            XCTAssertEqual(value.value as? String, PromptContextBuilder.hourUnknownPlaceholder,
                           "\(key) 缺时柱 → 占位值")
        }
        XCTAssertEqual(context["true_solar_time"]?.value as? String,
                       PromptContextBuilder.hourUnknownPlaceholder,
                       "真太阳时 null → 占位(不漏 12:00 假精度)")
        // 未歧义柱照常
        XCTAssertEqual(context["day_gan"]?.value as? String, "甲")
    }

    func testPromptContextBuilderDayAndYearAmbiguityPlaceholders() throws {
        // S02 歧义:day null → day_* 占位;year null → year_* 占位(同理不猜)
        let response = Self.makeResponse(pillars: PillarsDTO(
            year: nil, month: Self.fixturePillar,
            day: nil, hour: Self.fixturePillar
        ), dayMasterStrength: "unknown_hour", hourKnown: false)
        let context = PromptContextBuilder.build(response: response, request: Self.fixtureRequest)

        for key in ["day_gan", "day_zhi", "day_gan_element", "day_shishen_zhi",
                    "day_hide_gan", "day_nayin"] {
            XCTAssertEqual(context[key]?.value as? String,
                           PromptContextBuilder.hourUnknownPlaceholder, "\(key) 日柱歧义 → 占位")
        }
        for key in ["year_gan", "year_zhi", "year_gan_element", "year_zhi_element",
                    "year_shishen_gan", "year_hide_gan", "year_nayin"] {
            XCTAssertEqual(context[key]?.value as? String,
                           PromptContextBuilder.hourUnknownPlaceholder, "\(key) 年柱歧义 → 占位")
        }
    }

    func testPromptContextBuilderFullPillarsUnchanged() throws {
        // 老盘(四柱齐全)context 输出与现状一致(值不走占位)
        let response = Self.makeResponse(pillars: PillarsDTO(
            year: Self.fixturePillar, month: Self.fixturePillar,
            day: Self.fixturePillar, hour: Self.fixturePillar
        ))
        let context = PromptContextBuilder.build(response: response, request: Self.fixtureRequest)
        XCTAssertEqual(context["hour_gan"]?.value as? String, "甲")
        XCTAssertEqual(context["hour_nayin"]?.value as? String, "海中金")
        XCTAssertEqual(context["day_gan_element"]?.value as? String, "木")
        XCTAssertNotEqual(context["true_solar_time"]?.value as? String,
                          PromptContextBuilder.hourUnknownPlaceholder)
    }

    func testBuildV1ChartJSONHourUnknownEmitsNulls() throws {
        // 时柱缺失 → v1 chart 的 pillars.hour / ten_gods.hour_* 为 JSON null;
        // unknown_hour → strength_label「时辰未知」(S06 模板定稿前的诚实标注)
        let meta = MetaBlockDTO(
            locale: "zh-CN", gender: "male",
            birthLocal: "1988-05-15T12:00:00+08:00",
            trueSolarTime: "1988-05-15T11:45:00",
            lateZishiRule: "day_change_at_23", solarTermBoundary: "立夏后"
        )
        let response = Self.makeResponse(
            pillars: PillarsDTO(year: Self.fixturePillar, month: Self.fixturePillar,
                                day: Self.fixturePillar, hour: nil),
            dayMasterStrength: "unknown_hour",
            meta: meta, hourKnown: false
        )
        let jsonString = try PromptContextBuilder.buildV1ChartJSON(response: response)
        let chart = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(jsonString.utf8)) as? [String: Any]
        )
        let pillarsJSON = try XCTUnwrap(chart["pillars"] as? [String: Any])
        XCTAssertTrue(pillarsJSON["hour"] is NSNull, "pillars.hour → JSON null(不猜干支)")
        XCTAssertFalse(pillarsJSON["day"] is NSNull, "日柱在(仅时柱缺)")
        let tenGods = try XCTUnwrap(chart["ten_gods"] as? [String: Any])
        XCTAssertTrue(tenGods["hour_stem"] is NSNull)
        let dayMaster = try XCTUnwrap(chart["day_master"] as? [String: Any])
        XCTAssertEqual(dayMaster["strength_label"] as? String, "时辰未知")
    }

    func testBuildV1ChartJSONDayAmbiguousThrowsExplicitly() throws {
        // 日柱歧义 → 无日主不编造 day_master 轴心字段,显式抛错
        // (S07 付费墙拦在内容页之前;走到这里 = 上游拦截缺口)
        let meta = MetaBlockDTO(
            locale: "zh-CN", gender: "male",
            birthLocal: "1988-05-15T12:00:00+08:00",
            trueSolarTime: "1988-05-15T11:45:00",
            lateZishiRule: "day_change_at_23", solarTermBoundary: "立夏后"
        )
        let response = Self.makeResponse(
            pillars: PillarsDTO(year: Self.fixturePillar, month: Self.fixturePillar,
                                day: nil, hour: nil),
            dayMasterStrength: "unknown_hour",
            meta: meta, hourKnown: false
        )
        XCTAssertThrowsError(try PromptContextBuilder.buildV1ChartJSON(response: response)) { error in
            XCTAssertTrue(error is PromptContextError, "显式错误类型,实际: \(error)")
        }
    }

    // MARK: - S05 表格渲染分支(PillarSlotModel / DualPillarSource 纯数据)

    func testPillarSlotModelResolve() {
        // 渲染分支单一事实源:nil → unknown(留白),有值 → known(照常)
        XCTAssertEqual(PillarSlotModel.resolve(nil), .unknown)
        XCTAssertEqual(PillarSlotModel.resolve(Self.fixturePillar), .known(Self.fixturePillar))
    }

    func testDualPillarSourceFromHourUnknownPair() throws {
        // A 盘无时柱、B 盘四柱全:时柱行 ganA nil(留白)、ganB 有值;其余行两侧完整
        let a = Self.makeResponse(pillars: PillarsDTO(
            year: Self.fixturePillar, month: Self.fixturePillar,
            day: Self.fixturePillar, hour: nil
        ), hourKnown: false)
        let b = Self.makeResponse(pillars: PillarsDTO(
            year: Self.fixturePillar, month: Self.fixturePillar,
            day: Self.fixturePillar, hour: Self.fixturePillar
        ))
        let sources = DualPillarSource.from(a: a, b: b)

        XCTAssertEqual(sources.count, 4)
        let hourRow = try XCTUnwrap(sources.first { $0.position == L10n.Compatibility.dualHourPillar })
        XCTAssertNil(hourRow.ganA, "A 盘时柱未知 → ganA nil(渲染层留白)")
        XCTAssertNil(hourRow.nayinA)
        XCTAssertEqual(hourRow.ganB, "甲", "B 盘照常")
        let dayRow = try XCTUnwrap(sources.first { $0.position == L10n.Compatibility.dualDayPillar })
        XCTAssertEqual(dayRow.ganA, "甲")
        XCTAssertEqual(dayRow.ganB, "甲")
    }

    // MARK: - S05 时辰未知存档(birthSolarTime 回退出生日期锚点)

    func testUpsertHourUnknownArchivesWallClockBirthDate() throws {
        // 真太阳时 null → birthSolarTime 回退 request.birthDatetime 按出生地时区解析
        // (存档字段承载「出生日期」锚点,不存假精度真太阳时,也不存垃圾时间)
        let response = Self.makeResponse(
            pillars: PillarsDTO(year: Self.fixturePillar, month: Self.fixturePillar,
                                day: Self.fixturePillar, hour: nil),
            trueSolarTime: nil, hourKnown: false
        )
        let request = BaziCalculateRequest(
            birthDatetime: "1990-02-04T12:00:00",  // 立春日(节气边界)+ 12:00 占位
            timezone: "Asia/Shanghai",
            gender: "female", longitude: 116.4,
            latitude: nil, placeName: nil, geonameId: nil,
            ziHourRule: "zi_next_day"
        )
        _ = try chartStore.upsert(response: response, request: request)

        let snapshot = try XCTUnwrap(chartStore.get(contentHash: response.contentHash))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let c = cal.dateComponents([.year, .month, .day, .hour], from: snapshot.birthSolarTime)
        XCTAssertEqual(c.year, 1990)
        XCTAssertEqual(c.month, 2)
        XCTAssertEqual(c.day, 4)
        XCTAssertEqual(c.hour, 12, "占位 12:00 钟面如实存档(日期锚点)")

        // payload 回读:hour_known=false + true_solar_time 缺省(decodeIfPresent)
        let decoded = try chartStore.decodeResponse(from: snapshot)
        XCTAssertFalse(decoded.isHourKnown)
        XCTAssertNil(decoded.trueSolarTime)
    }

    // MARK: - S08 生肖屏立春降级路径(D10 年柱歧义 → ZodiacRevealMode 降级不猜)
    //
    // 测试 target 无 ViewInspector:视图分支(ZodiacRevealView 降级态 vs 正常态、
    // Profile 头像三态)单一事实源在 `ZodiacRevealMode.resolve` /
    // `ZodiacAvatarMode.resolve` 纯函数,对齐 `PillarSlotModel` 范式;
    // Q7 完成态边界在 `CompleteOnceGate`(S08 从 view 内联 guard 提取为可测类型)。
    // 降级态 body 求值用 UIHostingController 渲染冒烟兜底 fatalError 路径。

    /// S08 夹具:在 hour_unknown 响应骨架上改写生肖系三 key + hour_known
    /// (三种业务情形共用同一骨架,只差生肖 key 与时柱)。
    private static func s08ResponseJSON(
        pillars: [String: Any],
        zodiac: Any,
        friends: Any,
        clash: Any,
        hourKnown: Bool
    ) throws -> Data {
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Self.hourUnknownResponseJSON(
                pillars: pillars, includeZodiacKeys: false
            )) as? [String: Any]
        )
        json["year_branch_zodiac"] = zodiac
        json["year_branch_friends"] = friends
        json["year_branch_clash"] = clash
        var calcRule = try XCTUnwrap(json["calc_rule_snapshot"] as? [String: Any])
        calcRule["hour_known"] = hourKnown
        json["calc_rule_snapshot"] = calcRule
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testS08RevealModeDegradesOnYearAmbiguousNull() throws {
        // 分支 1/3:立春交界日 + hour_known=false → S02 显式 null 全量(年柱 null +
        // 生肖系 null)→ 降级态。判据用 OnboardingView 传参的同一表达式
        // (`yearBranchZodiac ?? ""`),保证视图路由与测试断言同源。
        let data = try Self.hourUnknownResponseJSON(pillars: [
            "year": NSNull(), "month": Self.pillarJSON,
            "day": NSNull(), "hour": NSNull(),
        ])
        let decoded = try APICoder.decoder.decode(BaziResponse.self, from: data)

        XCTAssertEqual(ZodiacRevealMode.resolve(zodiac: decoded.yearBranchZodiac ?? ""),
                       .yearAmbiguous,
                       "zodiac null → 立春降级态(不展示生肖/人格/好朋友/需磨合)")
        XCTAssertFalse(decoded.isHourKnown)
        // 降级态无生肖内容来源:friends/clash null → 空数组/空串传参,chip 行无从渲染
        XCTAssertEqual(decoded.yearBranchFriends ?? [], [])
        XCTAssertEqual(decoded.yearBranchClash ?? "", "")
        // 有告知句:三 key 中英均已落 xcstrings,当前语言下解析非空
        XCTAssertFalse(L10n.Onboarding.revealYearAmbiguousNotice.isEmpty,
                       "降级态必须有如实告知句(立春交界 + 需时辰)")
        XCTAssertFalse(L10n.Onboarding.revealYearAmbiguousHint.isEmpty,
                       "降级态必须有补时辰轻提示(D7 被迫告知触点)")
        XCTAssertNotEqual(L10n.Onboarding.revealCTADegraded, L10n.Onboarding.revealCTA,
                          "降级态 CTA「继续」必须与正常态 CTA 区分(完成 onboarding 进 App)")
    }

    func testS08RevealModeFullWhenHourUnknownButYearDetermined() throws {
        // 分支 2/3:普通日 + hour_known=false(时柱 null)但年柱确定 → 后端照给生肖
        // (≈99.7% 时辰未知用户)→ 生肖屏照常「哇」时刻(正常路径零变化)。
        let data = try Self.s08ResponseJSON(
            pillars: [
                "year": Self.pillarJSON, "month": Self.pillarJSON,
                "day": Self.pillarJSON, "hour": NSNull(),
            ],
            zodiac: "Rat", friends: ["Ox", "Dragon", "Monkey"], clash: "Horse",
            hourKnown: false
        )
        let decoded = try APICoder.decoder.decode(BaziResponse.self, from: data)

        XCTAssertNil(decoded.pillars.hour, "前置:时辰未知 → 时柱 null")
        XCTAssertFalse(decoded.isHourKnown)
        XCTAssertEqual(decoded.yearBranchZodiac, "Rat", "年柱确定 → 生肖照给(不歧义)")
        XCTAssertEqual(ZodiacRevealMode.resolve(zodiac: decoded.yearBranchZodiac ?? ""),
                       .full,
                       "无时辰但年柱确定 → 生肖屏照常(好朋友/需磨合照常)")
    }

    func testS08RevealModeFullForHourKnownLichunDay() throws {
        // 分支 3/3:立春交界日 + hour_known=true → 时辰可判侧,后端恒给生肖
        // → 完全现状行为(四柱全 + 生肖照给,与 S08 之前逐字段一致)。
        let data = try Self.s08ResponseJSON(
            pillars: [
                "year": Self.pillarJSON, "month": Self.pillarJSON,
                "day": Self.pillarJSON, "hour": Self.pillarJSON,
            ],
            zodiac: "Snake", friends: ["Ox", "Rooster"], clash: "Pig",
            hourKnown: true
        )
        let decoded = try APICoder.decoder.decode(BaziResponse.self, from: data)

        XCTAssertEqual(decoded.pillars.hour?.ganZhi, "甲子", "前置:有时辰 → 四柱全")
        XCTAssertTrue(decoded.isHourKnown)
        XCTAssertEqual(ZodiacRevealMode.resolve(zodiac: decoded.yearBranchZodiac ?? ""),
                       .full,
                       "有时辰用户(含立春日)生肖屏完全现状行为")
    }

    func testS08RevealModeResolveKnownZodiacsFullAndUnknownNeverFull() {
        // resolve 边界:12 生肖全部 → full;nil/空串/未知名 → yearAmbiguous
        // (未知名不进 full 态是安全不变量:full 态直接调 personalityText/animalChar,
        // 未知值 fatalError,降级态必须先拦)。未知串 → 降级 = 不猜也不 crash。
        let allZodiacs = ["Rat", "Ox", "Tiger", "Rabbit", "Dragon", "Snake",
                          "Horse", "Goat", "Monkey", "Rooster", "Dog", "Pig"]
        for zodiac in allZodiacs {
            XCTAssertEqual(ZodiacRevealMode.resolve(zodiac: zodiac), .full, "\(zodiac) → full")
        }
        XCTAssertEqual(ZodiacRevealMode.resolve(zodiac: nil), .yearAmbiguous)
        XCTAssertEqual(ZodiacRevealMode.resolve(zodiac: ""), .yearAmbiguous,
                       "OnboardingView 对 null 的传参是空串 → 必须降级")
        XCTAssertEqual(ZodiacRevealMode.resolve(zodiac: "Unicorn"), .yearAmbiguous,
                       "表外生肖名 → 降级不猜,绝不进 full 触发 fatalError")
    }

    func testS08AvatarModeThreeStates() {
        // Profile 命主卡/账号头像三态(纯函数判定,不 crash 不猜):
        // hidden = 无命盘/decode 失败;inkDot = 有盘但年柱歧义 → 通用墨点;
        // zodiac = 正常生肖印章图。
        XCTAssertEqual(ZodiacAvatarMode.resolve(hasChart: false, zodiac: nil), .hidden)
        XCTAssertEqual(ZodiacAvatarMode.resolve(hasChart: false, zodiac: "Rat"), .hidden,
                       "无命盘 → 不因生肖字段残值复活头像(头像位留空)")
        XCTAssertEqual(ZodiacAvatarMode.resolve(hasChart: true, zodiac: nil), .inkDot,
                       "立春歧义 → 墨点(不猜属相,命主卡不再整体隐藏)")
        XCTAssertEqual(ZodiacAvatarMode.resolve(hasChart: true, zodiac: ""), .inkDot)
        XCTAssertEqual(ZodiacAvatarMode.resolve(hasChart: true, zodiac: "Unicorn"), .inkDot,
                       "表外名 → 墨点,不拼 asset 名猜图")
        XCTAssertEqual(ZodiacAvatarMode.resolve(hasChart: true, zodiac: "Rat"),
                       .zodiac("Zodiac_Rat"), "正常态 asset 名拼接(与 ZodiacRevealView 同族)")
    }

    func testS08ProfileInkDotSurvivesArchiveRoundtrip() throws {
        // Profile 降级数据链:立春歧义响应 → upsert 存档 → 回读 payload,
        // 生肖必须仍为 nil(存档往返不得经 legacy 年支兜底把 null 洗成猜测生肖——
        // 年柱同 null,兜底不可达),resolve → inkDot(墨点表达,不 crash 不猜)。
        let data = try Self.hourUnknownResponseJSON(pillars: [
            "year": NSNull(), "month": Self.pillarJSON,
            "day": NSNull(), "hour": NSNull(),
        ])
        let response = try APICoder.decoder.decode(BaziResponse.self, from: data)
        let request = BaziCalculateRequest(
            birthDatetime: "1990-02-04T12:00:00",  // 立春日 + 12:00 占位
            timezone: "Asia/Shanghai",
            gender: "female", longitude: 116.4,
            latitude: nil, placeName: nil, geonameId: nil,
            ziHourRule: "zi_next_day"
        )
        _ = try chartStore.upsert(response: response, request: request)

        let snapshot = try XCTUnwrap(chartStore.get(contentHash: response.contentHash))
        let decoded = try chartStore.decodeResponse(from: snapshot)
        XCTAssertNil(decoded.yearBranchZodiac,
                     "存档往返后歧义 null 必须保持 nil(兜底只对「缺 key 且年支在」生效)")
        XCTAssertEqual(ZodiacAvatarMode.resolve(hasChart: true, zodiac: decoded.yearBranchZodiac),
                       .inkDot,
                       "Profile 对 zodiac=null → 通用墨点(不猜不 crash)")
    }

    func testS08CompleteOnceGateSingleShot() {
        // Q7 状态边界:降级态 CTA「继续」与正常态 CTA 走同一闸门——
        // 首次点击放行 onComplete,重渲染/重复点击不再触发(不因降级态重复触发)。
        var gate = CompleteOnceGate()
        var fired = 0
        XCTAssertTrue(gate.fire { fired += 1 }, "首次放行返回 true")
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(gate.fire { fired += 1 }, "已落闩 → 拦截返回 false")
        XCTAssertFalse(gate.fire { fired += 1 })
        XCTAssertEqual(fired, 1, "onComplete 恰好触发一次(hasSeenOnboarding 不重复置位)")
        XCTAssertTrue(gate.hasTriggered, "落闩状态可读(断言/日志用)")
    }

    func testS08ZodiacKeysOmittedWithNullYearPillarDecodesAsNil() throws {
        // S08 往返缺口回归:生肖 key 缺失 + 年柱 null(encodeIfPresent 存档往返产物)
        // → 三字段解为 nil(年柱歧义透传,不猜),**不抛错**——否则立春歧义盘存档后
        // Profile/深度解析回读全部 decode 失败(修复前该形状抛 dataCorrupted)。
        let data = try Self.hourUnknownResponseJSON(pillars: [
            "year": NSNull(), "month": Self.pillarJSON,
            "day": NSNull(), "hour": NSNull(),
        ], includeZodiacKeys: false)
        let decoded = try APICoder.decoder.decode(BaziResponse.self, from: data)
        XCTAssertNil(decoded.yearBranchZodiac)
        XCTAssertNil(decoded.yearBranchFriends)
        XCTAssertNil(decoded.yearBranchClash)
        XCTAssertEqual(ZodiacRevealMode.resolve(zodiac: decoded.yearBranchZodiac ?? ""),
                       .yearAmbiguous)
    }

    func testS08ZodiacKeysMissingWithUnknownYearZhiStillThrows() throws {
        // 真 corruption 仍显式抛错:年柱在但年支不在兜底表(非法地支),
        // 不静默给 nil 掩盖(CLAUDE.md 错误显式传播)。
        var pillar = Self.pillarJSON
        pillar["zhi"] = "奇"  // 表外地支
        let data = try Self.hourUnknownResponseJSON(pillars: [
            "year": pillar, "month": Self.pillarJSON,
            "day": Self.pillarJSON, "hour": Self.pillarJSON,
        ], includeZodiacKeys: false)
        XCTAssertThrowsError(try APICoder.decoder.decode(BaziResponse.self, from: data)) { error in
            XCTAssertTrue(error is DecodingError, "兜底不可达 = 显式 DecodingError,实际: \(error)")
        }
    }

    func testS08DegradedRevealViewRendersWithoutCrash() {
        // 渲染冒烟:zodiac 空串 → 降级分支 body 求值不触发 fatalError
        // (animalChar/personalityText 对未知值 fatalError,降级态必须根本不走不到;
        // 正常态渲染已有主路径兜底,此处只兜 S08 新增分支)。
        let vc = UIHostingController(rootView: ZodiacRevealView(
            zodiac: "",
            mainLabel: "—",
            subLabel: "坤造(女) · —年(1990)",
            friendZodiacs: [],
            clashZodiac: "",
            onComplete: {}
        ))
        let size = vc.view.sizeThatFits(CGSize(width: 390, height: 844))
        XCTAssertGreaterThan(size.height, 0, "降级态 body 求值须产出可布局内容(不 crash)")
    }

    func testS08InkDotAvatarEnsoRenderSmoke() {
        // 墨点头像渲染冒烟:inkDot 态用 EnsoView(animated: false 静态直出),
        // ImageRenderer/列表复用场景不依赖 onAppear 入场动画。
        let vc = UIHostingController(rootView: EnsoView(size: 64, animated: false))
        let size = vc.view.sizeThatFits(CGSize(width: 100, height: 100))
        XCTAssertGreaterThan(size.height, 0, "EnsoView 静态渲染须可布局(不 crash)")
    }
}
