import SwiftData
import XCTest
@testable import QiCompass

/// 2026-08-16 深度解析直读存档改造测试:
/// - `DeepAnalysisViewModel.loadArchivedChart`:.ready + lastRequest 就绪 +
///   InterpretState 从 .idle 起步(β 点击触发)+ **不触发** onChartArchived
/// - `ChartSnapshot.archivedDisplayRequest`:城市盘 / 自定义地点盘 / 老快照(无时区)三形态映射
/// - upsert → get → decodeResponse → archivedDisplayRequest 往返一致(payload 不丢 identity)
@MainActor
final class DeepAnalysisArchiveLoadTests: XCTestCase {

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
        chartStore = nil
        apiClient = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - 测试夹具

    /// 与实现独立的钟面期望值计算(Calendar components,不走 DateFormatter;
    /// 对齐 DeepAnalysisViewModelFormTests.expectedWall 范式)。
    private static func wallString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!
        )
    }

    /// 北京城市盘请求(与 FormTests.beijing 同源字段)。
    private static func beijingRequest() -> BaziCalculateRequest {
        BaziCalculateRequest(
            birthDatetime: "2000-05-20T10:30:00",
            timezone: "Asia/Shanghai",
            gender: "male",
            longitude: 116.4074,
            latitude: 39.9042,
            placeName: "北京",
            geonameId: 1816670,
            ziHourRule: "zi_next_day"
        )
    }

    // MARK: - loadArchivedChart

    func testLoadArchivedChartSetsReadyAndLastRequest() async throws {
        var archivedFired = false
        vm.onChartArchived = { archivedFired = true }

        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)

        vm.loadArchivedChart(response: response, request: request)

        guard case .ready(let ready, let interpret) = vm.state else {
            return XCTFail("loadArchivedChart 后必须 .ready,实际 \(vm.state)")
        }
        XCTAssertEqual(ready.contentHash, response.contentHash)
        XCTAssertEqual(interpret, .idle, "AI 命书必须从 .idle 起步(β 点击触发,决策 #4)")
        XCTAssertEqual(vm.lastRequest, request, "InterpretationSection/付费墙依赖 lastRequest")
        XCTAssertFalse(
            archivedFired,
            "直读存档非新建存档,不应触发 onChartArchived(否则误消费 pendingReturnTab 切 Tab)"
        )
    }

    // MARK: - archivedDisplayRequest(城市盘)

    func testArchivedDisplayRequestCitySnapshotRoundtrip() async throws {
        let request = Self.beijingRequest()
        let response = try await apiClient.calculateBazi(request: request)
        _ = try chartStore.upsert(response: response, request: request)

        let snapshot = try XCTUnwrap(chartStore.get(contentHash: response.contentHash))
        let decoded = try chartStore.decodeResponse(from: snapshot)
        XCTAssertEqual(decoded.contentHash, response.contentHash, "payload 往返不得丢 identity")

        let rebuilt = snapshot.archivedDisplayRequest
        XCTAssertEqual(rebuilt.gender, "male")
        XCTAssertEqual(rebuilt.placeName, "北京")
        XCTAssertEqual(rebuilt.timezone, "Asia/Shanghai")
        XCTAssertEqual(rebuilt.longitude, 116.4074, accuracy: 1e-9)
        XCTAssertEqual(rebuilt.latitude ?? 0, 39.9042, accuracy: 1e-9)
        XCTAssertEqual(rebuilt.ziHourRule, "zi_next_day")
        XCTAssertNil(rebuilt.geonameId, "geonameId 不入存档(展示元数据,不参与计算)")
        // birthDatetime = 真太阳时在出生城市时区的钟面(派生近似值,绝不回传 /calculate)
        let bjTZ = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        XCTAssertEqual(rebuilt.birthDatetime, Self.wallString(snapshot.birthSolarTime, timeZone: bjTZ))
    }

    // MARK: - archivedDisplayRequest(自定义地点盘)

    func testArchivedDisplayRequestCustomPlaceSnapshot() async throws {
        // S05:BirthPlaceResolver 给自定义地点填 placeName="自定义地点"、latitude=nil
        let request = BaziCalculateRequest(
            birthDatetime: "1995-11-03T08:00:00",
            timezone: "Asia/Urumqi",
            gender: "female",
            longitude: 87.62,
            latitude: nil,
            placeName: "自定义地点",
            geonameId: nil,
            ziHourRule: "zi_next_day"
        )
        let response = try await apiClient.calculateBazi(request: request)
        _ = try chartStore.upsert(response: response, request: request)

        let snapshot = try XCTUnwrap(chartStore.get(contentHash: response.contentHash))
        let rebuilt = snapshot.archivedDisplayRequest
        XCTAssertEqual(rebuilt.placeName, "自定义地点")
        XCTAssertEqual(rebuilt.timezone, "Asia/Urumqi")
        XCTAssertEqual(rebuilt.longitude, 87.62, accuracy: 1e-9)
        XCTAssertNil(rebuilt.latitude)
        let urumqiTZ = try XCTUnwrap(TimeZone(identifier: "Asia/Urumqi"))
        XCTAssertEqual(rebuilt.birthDatetime, Self.wallString(snapshot.birthSolarTime, timeZone: urumqiTZ))
    }

    // MARK: - archivedDisplayRequest(老快照:S03 前无时区/城市元数据)

    func testArchivedDisplayRequestLegacySnapshotFallsBackToCurrentTZ() throws {
        // 直接构造 @Model 实例(不入 context):模拟 S03 前老快照三 nil 字段
        let snapshot = ChartSnapshot(
            contentHash: "legacy_snapshot_1",
            schemaVersion: 1,
            birthSolarTime: Date(timeIntervalSince1970: 580_262_400),
            gender: "female",
            cityLongitude: 116.4,
            cityTimezone: nil,
            cityName: nil,
            cityLatitude: nil,
            ziHourRule: "zi_same_day",
            calcRuleSnapshot: Data(),
            payload: Data(),
            createdAt: .now
        )
        let rebuilt = snapshot.archivedDisplayRequest
        XCTAssertEqual(rebuilt.timezone, TimeZone.current.identifier, "老快照无时区 → 兜底设备时区标识符")
        XCTAssertNil(rebuilt.placeName, "城市名缺失 → ChartHeaderView 走「自定义经度」回退展示")
        XCTAssertNil(rebuilt.latitude)
        XCTAssertEqual(rebuilt.gender, "female")
        XCTAssertEqual(rebuilt.ziHourRule, "zi_same_day")
        XCTAssertEqual(
            rebuilt.birthDatetime,
            Self.wallString(snapshot.birthSolarTime, timeZone: .current),
            "老快照钟面派生用设备时区,与 timezone 兜底同源"
        )
    }
}
