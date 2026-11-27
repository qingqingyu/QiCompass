// TASK-16(2026-11-27):删号链路本机 entitlement 失效的补偿机制回归锚。
// ① deactivateAllForAccount throws 化后正常路径;② 标记(txIds 快照)启动
// 重试成功清除且不误伤快照外新购买;③ 无快照回落 pair 全量失效;
// ④ 重试真实失败(save 抛错)→ 标记保留(任务书验收第三条);
// ⑤ 标记缺字段时 retry 不误清(guard else return,畸形标记的边界);
// ⑥ mark→retry round-trip(writer/consumer 标记格式契约)。
import SwiftData
import XCTest
@testable import QiCompass

@MainActor
final class AccountDeleteLocalDeactivationTests: XCTestCase {
    // SwiftData 容器保活坑(2026-11-05):测试须显式持容器,释放后 context 操作 SIGTRAP
    private var container: ModelContainer!
    private var context: ModelContext!
    private var store: EntitlementStore!
    private var savedDefaults: [String: Any]!

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(
            for: Entitlement.self, configurations: config)
        context = ModelContext(container)
        store = EntitlementStore(modelContext: context)
        savedDefaults = UserDefaults.standard.dictionary(
            forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey)
        UserDefaults.standard.removeObject(
            forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey)
    }

    override func tearDown() {
        // 恢复现场(标记可能是测试前真实残留,不丢)
        if let saved = savedDefaults {
            UserDefaults.standard.set(
                saved, forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey)
        } else {
            UserDefaults.standard.removeObject(
                forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey)
        }
        container = nil  // 先于 context 释放(保活坑纪律)
        super.tearDown()
    }

    /// 造一行指定 userId/userLocalId 的 active entitlement,返回 tx id
    @discardableResult
    private func seed(
        userId: String?, localId: String, tx: String = "tx-\(UUID().uuidString.prefix(8))"
    ) throws -> String {
        try store.upsert(
            transactionId: tx,
            productId: AppleProductID.deepAnalysisSingle,
            contentHash: "hash-task16",
            module: EntitlementModule.baziDeep,
            userLocalId: localId,
            userId: userId,
            purchasedAt: .now,
            originalPurchaseDate: .now)
        return tx
    }

    private func allEntitlements() throws -> [Entitlement] {
        try context.fetch(FetchDescriptor<Entitlement>())
    }

    func test_deactivate_normal_path_sets_inactive() throws {
        try seed(userId: "u1", localId: "l1")
        try store.deactivateAllForAccount(userId: "u1", userLocalId: "l1")
        let rows = try allEntitlements()
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].isActive, "userId/userLocalId 命中行必须失效")
    }

    func test_pending_mark_retry_success_clears_mark_and_spares_new_rows() throws {
        // 账号时代购买(快照内)+ 删号后同 localId 匿名新购买(快照外):
        // 重试精确失效前者,后者必须仍 active(误伤 = 用户付了钱被锁死)
        let accountTx = try seed(userId: "u2", localId: "l2")
        let postDeleteTx = try seed(userId: nil, localId: "l2")
        UserDefaults.standard.set(
            ["userId": "u2", "userLocalId": "l2", "txIds": [accountTx]],
            forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey)
        store.retryPendingLocalDeactivation()
        let byTx = try Dictionary(uniqueKeysWithValues:
            allEntitlements().map { ($0.transactionId, $0.isActive) })
        XCTAssertFalse(byTx[accountTx] ?? true, "快照内行重试后必须失效")
        XCTAssertTrue(byTx[postDeleteTx] ?? false, "快照外新购买不得被误伤")
        XCTAssertNil(
            UserDefaults.standard.dictionary(
                forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey),
            "重试成功必须清除标记")
    }

    func test_pending_mark_pair_fallback_deactivates_all_matching() throws {
        // 无 txIds(写标记时 fetch 也失败)→ 回落按 userId/userLocalId 对
        try seed(userId: "u5", localId: "l5")
        UserDefaults.standard.set(
            ["userId": "u5", "userLocalId": "l5"],
            forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey)
        store.retryPendingLocalDeactivation()
        XCTAssertFalse(try allEntitlements()[0].isActive, "回落路径命中行必须失效")
        XCTAssertNil(
            UserDefaults.standard.dictionary(
                forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey),
            "回落路径重试成功也必须清除标记")
    }

    func test_pending_mark_retry_failure_keeps_mark() throws {
        // 真实失败注入:同一 tmp 路径先可写落一行,再以 allowsSave=false
        // 只读打开(in-memory + allowsSave=false 会 loadIssue,须落盘文件)
        // → 快照失效路径的 save() 抛错 → retry 走 catch 分支,标记必须保留
        // 待下次启动再试。注:@Attribute(.unique) 重复插入在当前 SwiftData
        // 是 save 时静默 upsert(已实测不抛),不能用作注入。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("task16-ro-\(UUID().uuidString).store")
        defer { try? FileManager.default.removeItem(at: url) }
        let wContainer = try ModelContainer(
            for: Entitlement.self,
            configurations: ModelConfiguration(url: url))
        let wContext = ModelContext(wContainer)
        wContext.insert(Entitlement(
            transactionId: "ro-tx-task16",
            productId: AppleProductID.deepAnalysisSingle,
            contentHash: "hash-task16",
            module: EntitlementModule.baziDeep,
            userLocalId: "l4", userId: "u4",
            purchasedAt: .now, originalPurchaseDate: .now))
        try wContext.save()
        let roContainer = try ModelContainer(
            for: Entitlement.self,
            configurations: ModelConfiguration(url: url, allowsSave: false))
        let roStore = EntitlementStore(
            modelContext: ModelContext(roContainer))
        // 先锚注入机制本身:save 必须真抛(不抛 = 注入失效,本用例失真)
        XCTAssertThrowsError(
            try roStore.deactivateTransactionIds(["ro-tx-task16"]),
            "allowsSave=false 容器上 save 必须抛错(throws 语义锚)")
        UserDefaults.standard.set(
            ["userId": "u4", "userLocalId": "l4", "txIds": ["ro-tx-task16"]],
            forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey)
        roStore.retryPendingLocalDeactivation()
        XCTAssertNotNil(
            UserDefaults.standard.dictionary(
                forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey),
            "重试失败必须保留标记(清除后无下次补偿,错误状态永久留存)")
    }

    func test_mark_then_retry_roundtrip() throws {
        // writer↔consumer 格式契约锚:markPendingLocalDeactivation 写出的
        // 键(userId/userLocalId/txIds)必须被 retryPendingLocalDeactivation
        // 原样解析——改键名会让 guard 静默 return,标记永远不被消费
        let tx = try seed(userId: "u6", localId: "l6")
        store.markPendingLocalDeactivation(userId: "u6", userLocalId: "l6")
        XCTAssertEqual(
            UserDefaults.standard.dictionary(
                forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey)?["txIds"]
                as? [String],
            [tx],
            "标记必须含失败瞬间命中行的 txIds 快照")
        store.retryPendingLocalDeactivation()
        XCTAssertFalse(try allEntitlements()[0].isActive, "round-trip 后命中行已失效")
        XCTAssertNil(
            UserDefaults.standard.dictionary(
                forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey),
            "round-trip 成功必须清除标记")
    }

    func test_pending_mark_missing_fields_keeps_mark() throws {
        // 缺 userLocalId 的残缺标记:guard 拦下不炸、也不误清(保留待人工/下次)
        UserDefaults.standard.set(
            ["userId": "u3"],
            forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey)
        store.retryPendingLocalDeactivation()
        XCTAssertNotNil(
            UserDefaults.standard.dictionary(
                forKey: EntitlementStore.pendingLocalEntitlementDeactivationKey),
            "残缺标记不得被误清")
    }
}
