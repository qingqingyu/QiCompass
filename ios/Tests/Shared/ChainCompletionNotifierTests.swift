import SwiftData
import UIKit
import XCTest
@testable import QiCompass

/// 整链完成通知(方案二,2026-10-11 拍板:只发整链完成一条):
/// - `ChainCompletionDelivery.resolve` 投递矩阵(前台 toast / 后台系统通知 / 未授权不投)
/// - `DeepAnalysisViewModel.shouldNotifyBookComplete` 完成判定(可跑口径:付费未解锁
///   与 M4/M5 未填输入不计分母)
/// - VM 端到端:mock 免费全链跑完 → spy 恰好收到一次 (chapterCount=2, isOwned=false)
@MainActor
final class ChainCompletionNotifierTests: XCTestCase {

    // MARK: - 投递矩阵(纯函数)

    func test_delivery_activeAndAuthorized_isInAppToast() {
        XCTAssertEqual(
            ChainCompletionDelivery.resolve(appState: .active, authorized: true),
            .inAppToast
        )
    }

    func test_delivery_backgroundOrInactiveAndAuthorized_isSystemNotification() {
        // inactive(通知中心下拉/切换器)同后台:系统通知送达
        XCTAssertEqual(
            ChainCompletionDelivery.resolve(appState: .background, authorized: true),
            .systemNotification
        )
        XCTAssertEqual(
            ChainCompletionDelivery.resolve(appState: .inactive, authorized: true),
            .systemNotification
        )
    }

    func test_delivery_unauthorized_alwaysSuppressed() {
        // 用户没给许可就不打扰:前后台一致
        XCTAssertEqual(ChainCompletionDelivery.resolve(appState: .active, authorized: false), .suppressed)
        XCTAssertEqual(ChainCompletionDelivery.resolve(appState: .background, authorized: false), .suppressed)
    }

    func test_delivery_unknownAppState_defaultsToToast() {
        // appState 不可知时按前台乐观处理(不误发系统通知)
        XCTAssertEqual(
            ChainCompletionDelivery.resolve(appState: nil, authorized: true),
            .inAppToast
        )
    }

    // MARK: - 完成判定(纯函数)

    private static func okState(cached: Bool = false) -> ModuleState {
        .ok(text: "{\"one_line\":\"x\"}", cached: cached)
    }

    func test_shouldNotify_allRunnableDoneOwned_isTrue() {
        var states: [ModuleID: ModuleState] = [:]
        for module in ModuleID.allCases {
            states[module] = Self.okState()
        }
        XCTAssertTrue(DeepAnalysisViewModel.shouldNotifyBookComplete(
            moduleStates: states, hasEntitlement: true,
            hasM4Input: true, hasM5Input: true
        ))
    }

    func test_shouldNotify_oneChapterMissing_isFalse() {
        var states: [ModuleID: ModuleState] = [:]
        for module in ModuleID.allCases {
            states[module] = Self.okState()
        }
        states[.m7] = .pending
        XCTAssertFalse(DeepAnalysisViewModel.shouldNotifyBookComplete(
            moduleStates: states, hasEntitlement: true,
            hasM4Input: true, hasM5Input: true
        ))
    }

    func test_shouldNotify_unpaid_freeTwoChaptersComplete_isTrue() {
        // 未购:可跑章只有 M0/M1(付费 locked 不计分母),两章齐即「免费章节已成」
        let states: [ModuleID: ModuleState] = [
            .m0: Self.okState(), .m1: Self.okState(),
            .m2: .locked, .m3: .locked, .m4: .locked,
            .m5: .locked, .m6: .locked, .m7: .locked,
        ]
        XCTAssertTrue(DeepAnalysisViewModel.shouldNotifyBookComplete(
            moduleStates: states, hasEntitlement: false,
            hasM4Input: false, hasM5Input: false
        ))
    }

    func test_shouldNotify_needsInputExcludedFromDenominator() {
        // M4/M5 未填输入不计分母(等用户动作 ≠ 未完成):其余章 ok → 完成
        var states: [ModuleID: ModuleState] = [:]
        for module in ModuleID.allCases {
            states[module] = Self.okState()
        }
        states[.m4] = .needsInput
        states[.m5] = .needsInput
        XCTAssertTrue(DeepAnalysisViewModel.shouldNotifyBookComplete(
            moduleStates: states, hasEntitlement: true,
            hasM4Input: false, hasM5Input: false
        ))
    }

    func test_shouldNotify_emptyStates_isFalse() {
        // total=0 不得当「完成」(空集的 remaining 恒 0,须显式拦)
        XCTAssertFalse(DeepAnalysisViewModel.shouldNotifyBookComplete(
            moduleStates: [:], hasEntitlement: true,
            hasM4Input: true, hasM5Input: true
        ))
    }

    // MARK: - VM 端到端(未购免费全链 → spy 一次)

    /// spy:notifier 协议测试替身,记录整链完成调用。
    final class SpyChainNotifier: ChainCompletionNotifying {
        var completions: [(chapterCount: Int, isOwned: Bool)] = []

        func requestAuthorizationOnce() async {}

        func isAuthorized() async -> Bool { false }

        func notifyBookComplete(chapterCount: Int, isOwned: Bool) async {
            completions.append((chapterCount, isOwned))
        }
    }

    private var container: ModelContainer!
    private var vm: DeepAnalysisViewModel!
    private var spy: SpyChainNotifier!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        let apiClient = MockAPIClient()
        let chartStore = ChartSnapshotStore(context: context)
        let linkStore = UserSnapshotLinkStore(context: context)
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
            userLinkStore: linkStore
        )
        spy = SpyChainNotifier()
        vm = DeepAnalysisViewModel(
            orchestrator: orchestrator,
            entitlementStore: EntitlementStore(modelContext: context),
            chainCompletionNotifier: spy
        )
        vm.gender = "male"
        vm.setShichenHour(10)
    }

    override func tearDown() async throws {
        if let vm {
            _ = await waitUntil(timeout: 10) { !vm.isChainRunning && !vm.isHydrating }
        }
        vm = nil
        spy = nil
        container = nil
        try await super.tearDown()
    }

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

    private func filledForm() {
        vm.birthDate = Date(timeIntervalSince1970: 580_262_400)
        vm.selectedPlace = .city(Self.losAngeles)
    }

    func test_vm_freeChainComplete_notifiesOnceWithTwoChapters() async throws {
        // 排盘成功自动起链:未购 → M0/M1 fresh ok、M2-M7 locked,
        // 链落定时 spy 恰好一次 (chapterCount=2, isOwned=false)
        filledForm()
        vm.calculate()

        let settled = await waitUntil(timeout: 12) {
            self.vm.moduleStates[.m0]?.isOk == true
                && self.vm.moduleStates[.m1]?.isOk == true
                && self.vm.moduleStates[.m2] == .locked
                && !self.vm.isChainRunning
        }
        XCTAssertTrue(settled, "链未落定: m0=\(String(describing: vm.moduleStates[.m0])) m1=\(String(describing: vm.moduleStates[.m1])) m2=\(String(describing: vm.moduleStates[.m2])) isChainRunning=\(vm.isChainRunning)")

        // notifier 调用是 ok 落态后的 fire-and-forget Task,给一拍落地
        _ = await waitUntil(timeout: 2) { !self.spy.completions.isEmpty }
        XCTAssertEqual(spy.completions.count, 1, "整链完成只通知一次: \(spy.completions)")
        XCTAssertEqual(spy.completions.first?.chapterCount, 2, "未购可跑章 = M0/M1")
        XCTAssertEqual(spy.completions.first?.isOwned, false)
    }

    private func waitUntil(
        timeout: TimeInterval = 8,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return condition()
    }
}
