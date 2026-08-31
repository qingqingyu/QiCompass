import SwiftData
import XCTest
@testable import QiCompass

/// S07 时辰未知付费墙拦截态测试(docs/时辰未知-slices/S07)。
///
/// 覆盖 slice 验收:
/// - **判据分支矩阵**:`HourUnknownGate`(hour_known true/false × 日柱歧义 ×
///   存档 payload 解码路径)——判据单一事实源,消费方不得重复推断
/// - **purchase 全程不可达**(路径断言):拦截态 `purchase()` 调用后 state 纹丝不动
///   + entitlement 零写入(MockAPIClient 的 mock redeem 路径从未运行)
/// - **StoreKit product 不加载**:拦截态 `loadProduct()` 直接返回,productState 停 `.loading`
/// - **有时辰用户回归**:购买链路可达(未登录 → notSignedIn 显错,state 离开 .idle),
///   价格文案 fallback 与现状一致
@MainActor
final class PaywallHourUnknownGateTests: XCTestCase {

    private var container: ModelContainer!
    private var entitlementStore: EntitlementStore!
    private var purchaseManager: PurchaseManager!
    private var apiClient: MockAPIClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        entitlementStore = EntitlementStore(modelContext: context)
        apiClient = MockAPIClient()
        purchaseManager = PurchaseManager(entitlementStore: entitlementStore, apiClient: apiClient)
        // 购买链路可达性断言依赖「未登录 → notSignedIn」确定性;清掉同模拟器
        // Keychain 可能残留的登录态(模拟器 Keychain 跨测试进程持久)
        try? KeychainHelper.delete(.qicompassUserId)
    }

    override func tearDownWithError() throws {
        purchaseManager = nil
        entitlementStore = nil
        apiClient = nil
        container = nil
        try super.tearDown()
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

    /// 构造最小 BaziResponse(判据只看 pillars + calc_rule_snapshot.hour_known)。
    /// - Parameters:
    ///   - hourKnown:nil = 老 payload 缺 key(decodeIfPresent ?? true)
    ///   - hourPresent:时柱在不在(默认随 hourKnown:true→在,false→不在)
    ///   - dayPresent:日柱在不在(日柱歧义 = false)
    private static func makeResponse(
        hourKnown: Bool?,
        hourPresent: Bool? = nil,
        dayPresent: Bool = true
    ) -> BaziResponse {
        let pillar = makePillar()
        let ganzhi = GanZhiNaYinDTO(ganZhi: "甲子", nayin: "海中金")
        return BaziResponse(
            contentHash: "gate_\(UUID().uuidString.prefix(8))",
            trueSolarTime: nil,
            trueSolarOffsetMinutes: 0,
            pillars: PillarsDTO(
                year: pillar,
                month: pillar,
                day: dayPresent ? pillar : nil,
                hour: (hourPresent ?? (hourKnown ?? true)) ? pillar : nil
            ),
            mingGong: ganzhi, shenGong: ganzhi, taiYuan: ganzhi,
            elementBalance: ElementBalanceDTO(wood: 2, fire: 1, earth: 1, metal: 1, water: 3),
            favorableElements: ["木", "水"], unfavorableElements: ["土"],
            dayMasterStrength: dayPresent ? "balanced" : "unknown_hour",
            tiaoshouApplied: false,
            xijiMethod: "扶抑+调候", patternHint: nil,
            shensha: [],
            luckPillars: [],
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

    // MARK: - 判据分支矩阵(单一事实源)

    func testGate_四柱完整_回归hourKnown() {
        // 老 payload 缺 hour_known key(decodeIfPresent ?? true)
        XCTAssertEqual(Self.makeResponse(hourKnown: nil).hourUnknownGate, .hourKnown,
                       "老存档(S04 前)必须零拦截")
        // 显式 hour_known=true
        XCTAssertEqual(Self.makeResponse(hourKnown: true).hourUnknownGate, .hourKnown,
                       "有时辰用户付费墙与现状完全一致")
    }

    func testGate_时柱缺失日柱在_hourUnknownDayDetermined() {
        XCTAssertEqual(
            Self.makeResponse(hourKnown: false, hourPresent: false).hourUnknownGate,
            .hourUnknownDayDetermined,
            "日柱确定的无时辰用户:免费 2 章照给,付费墙拦截态"
        )
    }

    func testGate_日柱缺失_dayAmbiguous() {
        XCTAssertEqual(
            Self.makeResponse(hourKnown: false, hourPresent: false, dayPresent: false).hourUnknownGate,
            .dayAmbiguous,
            "日柱歧义:不进内容页,免费 2 章亦拦"
        )
    }

    func testGate_存档payload往返_判据保持() throws {
        // ChartSnapshotStore 同款编解码路径:upsert 编码 → decodeResponse 解码,
        // 判据必须穿透存档往返(payload 是拦截判据的单一事实源)
        let response = Self.makeResponse(hourKnown: false, hourPresent: false)
        let data = try APICoder.encoder.encode(response)
        let decoded = try APICoder.decoder.decode(BaziResponse.self, from: data)
        XCTAssertEqual(decoded.hourUnknownGate, .hourUnknownDayDetermined)
        XCTAssertEqual(decoded.isHourKnown, false)
    }

    func testGate_老盘缺hourKnownKey_解码为True_零拦截() throws {
        // 构造 S04 之前的老 payload 形状:四柱齐全 + calc_rule_snapshot 无 hour_known key
        let response = Self.makeResponse(hourKnown: false)  // 四柱齐全(小时在,仅用于编码形状)
        let data = try APICoder.encoder.encode(response)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var calcRule = try XCTUnwrap(root["calc_rule_snapshot"] as? [String: Any])
        calcRule.removeValue(forKey: "hour_known")
        root["calc_rule_snapshot"] = calcRule
        let stripped = try JSONSerialization.data(withJSONObject: root)

        let decoded = try APICoder.decoder.decode(BaziResponse.self, from: stripped)
        XCTAssertEqual(decoded.isHourKnown, true, "缺 key 必须 decodeIfPresent ?? true(2026-08-15 keyNotFound 教训)")
        XCTAssertEqual(decoded.hourUnknownGate, .hourKnown, "老盘零拦截")
    }

    // MARK: - purchase 全程不可达(路径断言)

    func testPurchase_拦截态_状态不动_entitlement零写入() async {
        let cases: [(gate: HourUnknownGate, hash: String)] = [
            (.hourUnknownDayDetermined, "blocked_hash_day_determined"),
            (.dayAmbiguous, "blocked_hash_day_ambiguous"),
        ]
        for testCase in cases {
            let vm = PaywallViewModel(
                module: .deepAnalysis,
                contentHash: testCase.hash,
                purchaseManager: purchaseManager,
                hourUnknownGate: testCase.gate
            )
            XCTAssertTrue(vm.isPurchaseIntercepted)

            await vm.purchase()

            XCTAssertEqual(vm.state, .idle, "拦截态 purchase() 必须原路返回,state 纹丝不动(gate=\(testCase.gate))")
            // mock redeem 路径从未运行 → entitlement 零写入(PurchaseManager.purchase 不可达的行为证据)
            XCTAssertNil(
                entitlementStore.getActive(
                    contentHash: testCase.hash,
                    module: EntitlementModule.baziDeep,
                    userLocalId: UserIdentity.userLocalId
                ),
                "拦截态不得产生任何 entitlement(gate=\(testCase.gate))"
            )
        }
    }

    func testLoadProduct_拦截态_不加载StoreKit() async {
        let vm = PaywallViewModel(
            module: .compatibility,
            contentHash: "blocked_product",
            purchaseManager: purchaseManager,
            hourUnknownGate: .hourUnknownDayDetermined
        )
        // StoreKit 不被触碰:productState 停留初始 .loading(正常路径这里会离开 .loading)
        await vm.loadProduct()
        XCTAssertEqual(vm.productState, .loading, "拦截态不加载 StoreKit product(D6 拦购买三件套之一)")
    }

    // MARK: - 有时辰用户回归(付费墙与现状完全一致)

    func testPurchase_有时辰_购买链路可达_notSignedIn显错() async {
        let vm = PaywallViewModel(
            module: .deepAnalysis,
            contentHash: "normal_hash",
            purchaseManager: purchaseManager
            // hourUnknownGate 缺省 .hourKnown = 所有既有调用点形态
        )
        XCTAssertFalse(vm.isPurchaseIntercepted)

        await vm.purchase()

        // 未登录 → PurchaseManager.purchase 抛 notSignedIn → state 显式离开 .idle:
        // 证明 purchase 链路对有时辰用户完全可达(与 S07 前行为一致)
        if case .failed(let message) = vm.state {
            XCTAssertTrue(message.contains("登录"), "未登录显错文案,实际:\(message)")
        } else {
            XCTFail("有时辰用户 purchase 必须进入购买链路(离开 .idle),实际:\(vm.state)")
        }
        XCTAssertNil(
            entitlementStore.getActive(
                contentHash: "normal_hash",
                module: EntitlementModule.baziDeep,
                userLocalId: UserIdentity.userLocalId
            ),
            "未登录被 purchase 入口拦截,同样零写入(基线行为)"
        )
    }

    func testDisplayPriceText_有时辰_fallback价格与现状一致() {
        let vm = PaywallViewModel(
            module: .deepAnalysis,
            contentHash: "price_hash",
            purchaseManager: purchaseManager
        )
        XCTAssertTrue(vm.displayPriceText.contains("¥128"), "价格文案不受拦截改造影响,实际:\(vm.displayPriceText)")
    }
}
