import SwiftData
import XCTest
@testable import QiCompass

/// 付费墙纯逻辑守护(2026-09-27 匿名购买重构后):
/// - 章节清单/预告行/副题文案一致性(「日主」改名 + teaser 平行守护)
/// - 人民币大写润金转换(壹佰贰拾捌圆整;宁缺毋错:解析不了 → nil)
/// - 恢复购买状态机(restore 状态转移 + 拦截态守卫)
final class PaywallContractStepTests: XCTestCase {

    // MARK: - 章节清单(「日元」→「日主」改名 + teaser/副题一致性)

    func test_paidChapters_deep_uses日主_not日元() {
        // 「日元」紧挨价格易联想日币(2026-09-27 review);展示名已改「日主」
        XCTAssertTrue(PaywallModule.deepAnalysis.paidChapters.contains("日主"),
                      "深度章节名必须用「日主」")
        XCTAssertFalse(PaywallModule.deepAnalysis.paidChapters.contains("日元"),
                       "「日元」不得再出现(展示名维度)")
    }

    func test_chapterTeasers_countMatchesPaidChapters_perModule() {
        // teaser 与章名平行排列,PaywallView 按 index 取——count 必须一致
        for module in [PaywallModule.deepAnalysis, .compatibility] {
            XCTAssertEqual(
                module.chapterTeasers.count, module.paidChapters.count,
                "\(module.title) teaser 与章名 count 不一致"
            )
        }
    }

    func test_chapterTeasers_nonEmpty_andShort() {
        // 预告行是 caption 9.5pt 单行——空串或超长都会破版式;≤12 字
        for module in [PaywallModule.deepAnalysis, .compatibility] {
            for teaser in module.chapterTeasers {
                XCTAssertFalse(teaser.isEmpty, "teaser 不得为空")
                XCTAssertLessThanOrEqual(teaser.count, 12, "teaser 过长:\(teaser)")
            }
        }
    }

    func test_freeChaptersHint_namesFreeChapters_andPaidCount() {
        // 副题点名免费两章(消灭「余下」无上下文)+ 不再承诺「全设备同步」
        // (匿名购买语义下同步需绑定账号,由绑定行承载)
        for module in [PaywallModule.deepAnalysis, .compatibility] {
            XCTAssertTrue(module.freeChaptersHint.contains("免费"),
                          "\(module.title) 副题必须点名免费章节")
            XCTAssertFalse(module.freeChaptersHint.contains("全设备同步"),
                           "\(module.title) 副题不得再承诺全设备同步")
        }
        XCTAssertTrue(PaywallModule.deepAnalysis.freeChaptersHint.contains("捌"))
        XCTAssertTrue(PaywallModule.compatibility.freeChaptersHint.contains("肆"))
    }

    // MARK: - 大写润金(整价照转)

    func test_upperPrice_integerCNY() {
        XCTAssertEqual(ChineseUpperPrice.priceString(from: "¥128.00"), "壹佰贰拾捌圆整")
        XCTAssertEqual(ChineseUpperPrice.priceString(from: "¥88"), "捌拾捌圆整")
        XCTAssertEqual(ChineseUpperPrice.priceString(from: "CN¥128.00"), "壹佰贰拾捌圆整")
    }

    func test_upperPrice_zeroPaddingDigits() {
        XCTAssertEqual(ChineseUpperPrice.priceString(from: "¥108"), "壹佰零捌圆整")
        XCTAssertEqual(ChineseUpperPrice.priceString(from: "¥110"), "壹佰壹拾圆整")
        XCTAssertEqual(ChineseUpperPrice.priceString(from: "¥10"), "壹拾圆整")
    }

    func test_upperPrice_wanSegment() {
        XCTAssertEqual(ChineseUpperPrice.priceString(from: "¥10008"), "壹萬零捌圆整")
        XCTAssertEqual(ChineseUpperPrice.priceString(from: "¥10000"), "壹萬圆整")
        XCTAssertEqual(ChineseUpperPrice.priceString(from: "¥99999"), "玖萬玖仟玖佰玖拾玖圆整")
    }

    // MARK: - 大写润金(抑制:宁缺毋错,不造假大写)

    func test_upperPrice_suppressedForFractionalPrice() {
        // 角分价(如 en 区 $19.99)无整数大写对应物
        XCTAssertNil(ChineseUpperPrice.priceString(from: "$19.99"))
    }

    func test_upperPrice_suppressedForThousandSeparator() {
        // 无 locale 信息,分组符与小数符不可区分:出现逗号一律抑制(宁缺毋错)
        XCTAssertNil(ChineseUpperPrice.priceString(from: "1,280.00"))
        XCTAssertNil(ChineseUpperPrice.priceString(from: "1,280"))
        // 全零分组段最危险:逗号被当小数符吞掉后三位会产出金额错误的大写
        // (¥10,000 → 壹拾圆整),必须抑制而非错误转换
        XCTAssertNil(ChineseUpperPrice.priceString(from: "¥10,000"))
        XCTAssertNil(ChineseUpperPrice.priceString(from: "¥1,000.00"))
    }

    func test_upperPrice_suppressedForOutOfRangeZeroOrUnparseable() {
        XCTAssertNil(ChineseUpperPrice.priceString(from: "¥100000"))  // 越界(>99999)
        XCTAssertNil(ChineseUpperPrice.priceString(from: "¥0"))       // 零元无意义
        XCTAssertNil(ChineseUpperPrice.priceString(from: "¥.50"))     // 前导小数点:无整数位,吞成 50 会错百倍
        XCTAssertNil(ChineseUpperPrice.priceString(from: ""))
        XCTAssertNil(ChineseUpperPrice.priceString(from: "价格待定"))
    }

    // MARK: - 恢复购买状态机(RestoreState 转移 + 拦截态守卫)

    @MainActor
    func test_restore_拦截态_守卫与purchase同构() async {
        // S07:拦截态 restore 全程不可达(restoreState 纹丝不动)
        let container = try! ModelContainerFactory.makeInMemory()
        let apiClient = MockAPIClient()
        let purchaseManager = PurchaseManager(
            entitlementStore: EntitlementStore(modelContext: container.mainContext),
            apiClient: apiClient
        )
        let vm = PaywallViewModel(
            module: .deepAnalysis,
            contentHash: "blocked_restore",
            purchaseManager: purchaseManager,
            hourUnknownGate: .hourUnknownDayDetermined
        )
        XCTAssertTrue(vm.isPurchaseIntercepted)

        await vm.restore()

        XCTAssertEqual(vm.restoreState, .idle, "拦截态 restore 必须是 no-op")
    }

    @MainActor
    func test_restore_mock本地无entitlement_nothingFound() async {
        // Mock 路径:本地无当前盘 entitlement → 未找到(消耗型诚实语义)
        try? KeychainHelper.delete(.qicompassUserId)
        let container = try! ModelContainerFactory.makeInMemory()
        let apiClient = MockAPIClient()
        let purchaseManager = PurchaseManager(
            entitlementStore: EntitlementStore(modelContext: container.mainContext),
            apiClient: apiClient
        )
        let vm = PaywallViewModel(
            module: .deepAnalysis,
            contentHash: "no_entitlement_hash",
            purchaseManager: purchaseManager
        )

        await vm.restore()

        XCTAssertEqual(vm.restoreState, .nothingFound)
    }

    @MainActor
    func test_restore_先购买再恢复_restored() async {
        // Mock 路径:匿名购买成功 → 本地已有 → 恢复返回 restored(消耗型同机找回)
        try? KeychainHelper.delete(.qicompassUserId)
        let container = try! ModelContainerFactory.makeInMemory()
        let apiClient = MockAPIClient()
        let purchaseManager = PurchaseManager(
            entitlementStore: EntitlementStore(modelContext: container.mainContext),
            apiClient: apiClient
        )
        let vm = PaywallViewModel(
            module: .deepAnalysis,
            contentHash: "restore_after_buy",
            purchaseManager: purchaseManager
        )

        await vm.purchase()
        XCTAssertEqual(vm.state, .success)

        await vm.restore()
        XCTAssertEqual(vm.restoreState, .restored)
    }

    // MARK: - 防漏单 pending 记录(2026-09-29 listener 续接闭环)

    /// PendingRedeemStore 是购买失败时点的资损关键持久化:listener 续接
    /// redeem 靠它拿回 content_hash/module(消耗型交易本体不带)。round-trip
    /// 与清记录语义在此锁定;显式清理防模拟器容器跨轮残留(DailyReadCounter 教训)。
    func test_pendingRedeemStore_roundTrip_andRemove() {
        UserDefaults.standard.removeObject(forKey: "qicompass.pending_redeems.v1")
        defer { UserDefaults.standard.removeObject(forKey: "qicompass.pending_redeems.v1") }

        // 空 → nil
        XCTAssertNil(PendingRedeemStore.get(txId: "tx_missing"))

        // set → get 按字段还原
        PendingRedeemStore.set(
            txId: "tx_001",
            .init(
                productId: "com.qicompass.deep_analysis.single",
                contentHash: "hash_abc",
                module: EntitlementModule.baziDeep
            )
        )
        let record = PendingRedeemStore.get(txId: "tx_001")
        XCTAssertEqual(record?.productId, "com.qicompass.deep_analysis.single")
        XCTAssertEqual(record?.contentHash, "hash_abc")
        XCTAssertEqual(record?.module, EntitlementModule.baziDeep)

        // 同 txId 不同上下文 → 保留首条不覆盖(2026-09-30 keep-first 语义:
        // 首条 redeem 可能已在他处兑现到一半[客户端超时但后端已提交],被顶掉后
        // listener 拿新 hash 续接会撞 ENTITLEMENT_ERROR 清档收尾,首条对应的
        // 本地 entitlement 从此无人补写)
        PendingRedeemStore.set(
            txId: "tx_001",
            .init(
                productId: "com.qicompass.compatibility.single",
                contentHash: "hash_xyz",
                module: EntitlementModule.compatibility
            )
        )
        let kept = PendingRedeemStore.get(txId: "tx_001")
        XCTAssertEqual(kept?.contentHash, "hash_abc", "冲突不覆盖,保留首条")
        XCTAssertEqual(kept?.module, EntitlementModule.baziDeep)

        // 同上下文重写 = 幂等照常落(不误伤正常路径)
        PendingRedeemStore.set(
            txId: "tx_001",
            .init(
                productId: "com.qicompass.deep_analysis.single",
                contentHash: "hash_abc",
                module: EntitlementModule.baziDeep
            )
        )
        XCTAssertEqual(PendingRedeemStore.get(txId: "tx_001")?.contentHash, "hash_abc")

        // remove → 消失;重复 remove 幂等
        PendingRedeemStore.remove(txId: "tx_001")
        XCTAssertNil(PendingRedeemStore.get(txId: "tx_001"))
        PendingRedeemStore.remove(txId: "tx_001")  // 不 crash 不写坏存储
        XCTAssertNil(PendingRedeemStore.get(txId: "tx_001"))

        // 多笔互不干扰
        PendingRedeemStore.set(
            txId: "tx_a",
            .init(productId: "p1", contentHash: "h1", module: "m1")
        )
        PendingRedeemStore.set(
            txId: "tx_b",
            .init(productId: "p2", contentHash: "h2", module: "m2")
        )
        PendingRedeemStore.remove(txId: "tx_a")
        XCTAssertEqual(PendingRedeemStore.get(txId: "tx_b")?.contentHash, "h2")
    }
}
