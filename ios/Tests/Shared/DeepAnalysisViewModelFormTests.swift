import SwiftData
import XCTest
@testable import QiCompass

/// S03 深度解析表单 VM 测试:必选城市校验 + 请求构造(裸钟面 / timezone / 经纬度)。
///
/// 对应 S03/S05 验收:
/// - 未选出生地提交 → 「请选择出生城市」;无任何默认城市
/// - 选中城市后 `birthDatetime` 为出生城市裸钟面(WYSIWYG),timezone/经纬度来自城市记录
/// - S05 自定义地点:timezone 显式必选(城市/自定义地点两分支)
@MainActor
final class DeepAnalysisViewModelFormTests: XCTestCase {

    private var container: ModelContainer!
    private var vm: DeepAnalysisViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let apiClient = MockAPIClient()
        let chartStore = ChartSnapshotStore(context: context)
        let interpretStore = InterpretationCacheStore(context: context)
        let identityResolver = AIIdentityResolver(apiClient: apiClient)
        let counter = DailyReadCounter()
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
}
