import SwiftData
import XCTest
@testable import QiCompass

/// S03 深度解析表单 VM 测试:必选城市校验 + 请求构造(裸钟面 / timezone / 经纬度)。
///
/// 对应 S03 验收:
/// - 未选城市提交 → 「请选择出生城市」;无任何默认城市
/// - 选中城市后 `birthDatetime` 为出生城市裸钟面(WYSIWYG),timezone/经纬度来自城市记录
/// - 手动经度过渡路径:timezone=设备时区(S05 升级前过渡)
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
        vm.useManualLongitude = false
        vm.selectedPlace = nil
        let errors = vm.validateForm()
        XCTAssertTrue(errors.contains("请选择出生城市"), "未选城市且未开手动经度 → 必须拦截: \(errors)")
        XCTAssertTrue(vm.selectedPlace == nil, "无任何默认城市(初始态必须 nil)")
    }

    func testValidatePlaceSelectedPasses() {
        vm.selectedPlace = Self.losAngeles
        vm.birthDate = Date(timeIntervalSince1970: 580_262_400) // 1988-05-15 前后,早于当下
        let errors = vm.validateForm()
        XCTAssertFalse(errors.contains("请选择出生城市"), errors.description)
    }

    func testValidateManualLongitudeSkipsCityRequirement() {
        vm.useManualLongitude = true
        vm.manualLongitude = 116.41
        XCTAssertFalse(vm.validateForm().contains("请选择出生城市"))
        // 越界经度仍拦截
        vm.manualLongitude = 200
        XCTAssertTrue(vm.validateForm().contains("经度需在 -180 到 180 之间"))
    }

    // MARK: - 请求构造(S02 契约:裸钟面 + timezone + 物理真值)

    func testBuildRequestExtractsWallClockInPlaceTimezone() throws {
        let birth = Date(timeIntervalSince1970: 580_262_400)
        vm.birthDate = birth
        vm.selectedPlace = Self.losAngeles

        let request = vm.buildRequest()

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

        vm.selectedPlace = Self.losAngeles
        let laWall = vm.buildRequest().birthDatetime
        vm.selectedPlace = Self.beijing
        let bjWall = vm.buildRequest().birthDatetime

        let laTZ = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let bjTZ = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(laWall, Self.expectedWall(birth, timeZone: laTZ))
        XCTAssertEqual(bjWall, Self.expectedWall(birth, timeZone: bjTZ))
        XCTAssertNotEqual(laWall, bjWall)
    }

    func testBuildRequestManualLongitudeUsesDeviceTimezone() {
        // 手动经度过渡路径(S05 升级前):timezone=设备时区,物理值=手动经度
        vm.useManualLongitude = true
        vm.manualLongitude = 87.62
        let request = vm.buildRequest()
        XCTAssertEqual(request.timezone, TimeZone.current.identifier)
        XCTAssertEqual(request.longitude, 87.62, accuracy: 1e-9)
        XCTAssertNil(request.latitude)
        XCTAssertNil(request.placeName)
        XCTAssertNil(request.geonameId)
    }

    // MARK: - 时辰快捷选挂城市时区(WYSIWYG)

    func testSetShichenHourUsesPlaceCalendar() throws {
        vm.selectedPlace = Self.losAngeles
        vm.setShichenHour(10)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let hour = calendar.component(.hour, from: vm.birthDate)
        XCTAssertEqual(hour, 10, "setShichenHour 后洛杉矶钟面小时必须是指定值")
        XCTAssertEqual(calendar.component(.minute, from: vm.birthDate), 0)
    }

    func testPlaceCalendarFallsBackToCurrentWhenNoPlace() {
        vm.selectedPlace = nil
        XCTAssertEqual(vm.placeCalendar.timeZone.identifier, Calendar.current.timeZone.identifier)
    }
}
