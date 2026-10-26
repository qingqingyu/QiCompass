import SwiftData
import XCTest
@testable import QiCompass

/// S4c C3 问事次数包购买链测试:
/// - **PendingRedeemStore v1 档兼容**:旧 JSON(无 kind 键)解码不崩、
///   kind == nil 走 entitlement 原路径(10-15 教训:新增字段必 decodeIfPresent);
///   pack 记录 round-trip。
/// - **purchaseAskPack Mock 路径**:入账 +15、余额经 askWallet 回写、请求
///   录制(product_id/user_local_id);redeem 失败抛 backendRedeemFailed。
/// - **restoreAskPurchases Mock**:诚实返 nothingFound(无本地账可查)。
/// - **AskPaywallViewModel**:Mock 购买成功回调触发、恢复 nothingFound。
///
/// StoreKit 真路径(购买/续接/恢复)需 .storekit 配置或沙盒,M6 TestFlight 期
/// 真机验证——单测只锁 Mock 语义与数据结构,不碰 StoreKit。
@MainActor
final class AskPackRedeemTests: XCTestCase {

    private var container: ModelContainer!
    private var entitlementStore: EntitlementStore!
    private var purchaseManager: PurchaseManager!
    private var apiClient: MockAPIClient!
    private var wallet: AskWalletModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        let context = container.mainContext
        entitlementStore = EntitlementStore(modelContext: context)
        apiClient = MockAPIClient()
        purchaseManager = PurchaseManager(entitlementStore: entitlementStore, apiClient: apiClient)
        wallet = AskWalletModel(apiClient: apiClient, tokenProvider: { nil })
        purchaseManager.askWallet = wallet
        UserDefaults.standard.removeObject(forKey: "qicompass.pending_redeems.v1")
        // 匿名购买断言依赖「未登录」确定性(模拟器 Keychain 跨测试进程持久)
        try? KeychainHelper.delete(.qicompassUserId)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: "qicompass.pending_redeems.v1")
        purchaseManager = nil
        entitlementStore = nil
        apiClient = nil
        wallet = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - PendingRedeemStore v1 档兼容

    func testPendingRedeemStore_v1旧档无kind键_解码不崩且kind为nil() throws {
        // v1 旧档三字段、无 kind(Optional decodeIfPresent 语义)
        let legacyJSON = """
        {"tx-legacy":{"productId":"com.qicompass.deep_analysis.single","contentHash":"h-1","module":"bazi_deep"}}
        """
        UserDefaults.standard.set(Data(legacyJSON.utf8), forKey: "qicompass.pending_redeems.v1")

        let record = try XCTUnwrap(PendingRedeemStore.get(txId: "tx-legacy"))
        XCTAssertEqual(record.productId, "com.qicompass.deep_analysis.single")
        XCTAssertEqual(record.contentHash, "h-1")
        XCTAssertEqual(record.module, "bazi_deep")
        XCTAssertEqual(record.kind, nil, "旧档 kind 为 nil → listener 走 entitlement 原路径(不进 askPack 分流)")
    }

    func testPendingRedeemStore_pack记录roundTrip() {
        let packRecord = PendingRedeemStore.Record(
            productId: AskPackProductID.pack15,
            contentHash: "",
            module: "",
            kind: .askPack
        )
        PendingRedeemStore.set(txId: "tx-pack-rt", packRecord)
        XCTAssertEqual(PendingRedeemStore.get(txId: "tx-pack-rt"), packRecord, "pack 记录编码落盘解码 round-trip 保真")
        PendingRedeemStore.remove(txId: "tx-pack-rt")
        XCTAssertNil(PendingRedeemStore.get(txId: "tx-pack-rt"))
    }

    // MARK: - purchaseAskPack Mock 路径

    func testPurchaseAskPack_Mock路径_入账15_余额经钱包回写_录制断言() async throws {
        apiClient.setMockAskBalance(3)
        let balance = try await purchaseManager.purchaseAskPack()

        XCTAssertEqual(balance, 18, "试用 3 + 15 = 18(mock 钱包)")
        XCTAssertEqual(wallet.balance, 18, "余额经 askWallet.apply 单一口径回写")
        let recorded = try XCTUnwrap(apiClient.recordedAskRedeemRequests.last)
        XCTAssertEqual(recorded.productId, AskPackProductID.pack15)
        XCTAssertEqual(recorded.userLocalId, UserIdentity.userLocalId, "匿名维度 = 安装 UUID(与后端钱包 owner 匹配)")
    }

    func testPurchaseAskPack_Mock路径_redeem失败_抛错钱包不动() async {
        apiClient.askRedeemResponder = { _ in
            throw APIError.backendError(code: "APPLE_VERIFICATION_ERROR", message: "验签失败", requestId: "t")
        }
        wallet.apply(3)
        do {
            _ = try await purchaseManager.purchaseAskPack()
            XCTFail("redeem 失败应抛 PurchaseError")
        } catch let error as PurchaseError {
            if case .backendRedeemFailed = error {
                // 期望分类
            } else {
                XCTFail("应为 backendRedeemFailed,实为 \(error)")
            }
        } catch {
            XCTFail("应为 PurchaseError 系,实为 \(error)")
        }
        XCTAssertEqual(wallet.balance, 3, "失败路径不动余额(后端未入账)")
    }

    // MARK: - restoreAskPurchases Mock

    func testRestoreAskPurchases_Mock_诚实返nothingFound() async throws {
        let outcome = try await purchaseManager.restoreAskPurchases()
        XCTAssertEqual(outcome, .nothingFound, "Mock 无本地账可查,不碰 StoreKit")
        XCTAssertTrue(apiClient.recordedAskRedeemRequests.isEmpty, "不发起任何 redeem")
    }

    // MARK: - AskPaywallViewModel(Mock 管理器)

    func testAskPaywallVM_Mock购买成功_回调触发_无失败态() async {
        let successExpectation = expectation(description: "onPurchaseSuccess")
        let vm = AskPaywallViewModel(
            purchaseManager: purchaseManager,
            onPurchaseSuccess: { successExpectation.fulfill() }
        )
        await vm.purchase()
        XCTAssertEqual(vm.state, .idle, "成功即 dismiss(无 success 常驻态)")
        XCTAssertEqual(wallet.balance, 18, "mock 钱包默认试用 3 + 15 = 18")
        await fulfillment(of: [successExpectation], timeout: 1)
    }

    func testAskPaywallVM_恢复Mock_nothingFound态() async {
        let vm = AskPaywallViewModel(purchaseManager: purchaseManager)
        await vm.restoreAsk()
        XCTAssertEqual(vm.restoreState, .nothingFound)
    }

    func testAskPaywallVM_CTA文案含价格_角分价无大写() {
        let vm = AskPaywallViewModel(purchaseManager: purchaseManager)
        vm.productState = .loaded(displayPrice: "$4.99")
        XCTAssertEqual(vm.chineseUpperPrice, nil, "角分价不造假大写(ChineseUpperPrice 规则)")
        XCTAssertEqual(vm.displayPriceText, String(format: L10n.AskPaywall.ctaFormat, "$4.99"))
    }
}
