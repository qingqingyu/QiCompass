import SwiftData
import XCTest
@testable import QiCompass

/// EntitlementStore.hasAnyActivePurchase(每日运势历史回看解锁判据,MONETIZATION.md §每日运势历史回看)。
///
/// 覆盖:
/// - 无任何购买记录 → false
/// - 任意一笔 active(不限 module / contentHash,合盘也算)→ true
/// - 有记录但全部 inactive(退款撤销)→ false
/// - 双轨:userId 命中(userLocalId 完全不同,跨设备场景)→ true
/// - 双轨:userId 未命中 → 兜底 userLocalId 命中 → true
@MainActor
final class EntitlementStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: EntitlementStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemory()
        store = EntitlementStore(modelContext: container.mainContext)
    }

    override func tearDownWithError() throws {
        store = nil
        container = nil
        try super.tearDownWithError()
    }

    /// 插入一笔购买记录(upsert + 可选 deactivate 构造 inactive 行)。
    private func insertPurchase(
        _ tx: String,
        module: String = "bazi_deep",
        userLocalId: String = "local-A",
        userId: String? = nil,
        active: Bool = true
    ) throws {
        try store.upsert(
            transactionId: tx,
            productId: "com.qicompass.deep_analysis.single",
            contentHash: "hash-\(tx)",
            module: module,
            userLocalId: userLocalId,
            userId: userId,
            purchasedAt: Date(),
            originalPurchaseDate: Date()
        )
        if !active {
            store.deactivate(transactionId: tx)
        }
    }

    // MARK: - 基础判据

    func test_noPurchases_returnsFalse() {
        let result = store.hasAnyActivePurchase(userLocalId: "local-A")
        XCTAssertFalse(result, "无任何购买记录应锁定历史回看")
    }

    func test_anyActivePurchase_returnsTrue_regardlessOfModuleAndHash() throws {
        // 合盘 module + 另一个命盘 hash,同样解锁(规则是「任意购买」,不限 module/命盘)
        try insertPurchase("tx-1", module: "compatibility", userLocalId: "local-A")

        let result = store.hasAnyActivePurchase(userLocalId: "local-A")
        XCTAssertTrue(result, "任意一笔 active 购买(不限 module/contentHash)即解锁")
    }

    func test_allPurchasesInactive_returnsFalse() throws {
        try insertPurchase("tx-1", userLocalId: "local-A", active: false)
        try insertPurchase("tx-2", userLocalId: "local-A", active: false)

        let result = store.hasAnyActivePurchase(userLocalId: "local-A")
        XCTAssertFalse(result, "全部 inactive(退款撤销)不应解锁")
    }

    // MARK: - 双轨(userId 优先 / userLocalId 兜底)

    func test_userIdTrack_hitsEvenWhenLocalIdDiffers() throws {
        // 跨设备场景:换机重装后 userLocalId 变了,但登录 userId 名下有购买
        try insertPurchase("tx-1", userLocalId: "local-OLD", userId: "backend-user-1")

        let byUser = store.hasAnyActivePurchase(userLocalId: "local-NEW", userId: "backend-user-1")
        XCTAssertTrue(byUser, "userId 名下有 active 购买应解锁(与 userLocalId 无关)")

        // 老身份查不到(双轨互不串):local-NEW 没有任何记录
        let byLocalOnly = store.hasAnyActivePurchase(userLocalId: "local-NEW")
        XCTAssertFalse(byLocalOnly, "userLocalId 无记录且未传 userId 时应保持锁定")
    }

    func test_userIdMiss_fallsBackToLocalId() throws {
        // userId 查不到(退登 / 换账号),兜底 userLocalId 命中老购买
        try insertPurchase("tx-1", userLocalId: "local-A", userId: nil)

        let result = store.hasAnyActivePurchase(userLocalId: "local-A", userId: "backend-user-other")
        XCTAssertTrue(result, "userId 未命中应兜底 userLocalId 命中")
    }
}
