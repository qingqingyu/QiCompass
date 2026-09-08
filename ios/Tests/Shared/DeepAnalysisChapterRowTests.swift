import XCTest
@testable import QiCompass

/// 捌章目录行 + 主页 CTA 状态派生测试(盘面小景 S4,仿 PillarSlotModel 范式:
/// 视图分支经纯模型断言,不依赖 ViewInspector)。
final class DeepAnalysisChapterRowTests: XCTestCase {

    // MARK: - ChapterRowModel.resolve

    func test_row_nilState_freeModule_isUnreadFree() {
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m0, state: nil, hasEntitlement: false),
            .unreadFree
        )
    }

    func test_row_nilState_paidModuleWithoutEntitlement_isLockedPaid() {
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m2, state: nil, hasEntitlement: false),
            .lockedPaid
        )
    }

    func test_row_nilState_paidModuleWithEntitlement_isUnreadFree() {
        // 已购但未开始:实线徽可开卷,不是锁
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m7, state: nil, hasEntitlement: true),
            .unreadFree
        )
    }

    func test_row_ok_isRead() {
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m1, state: .ok(text: "x", cached: false), hasEntitlement: false),
            .read
        )
        // 付费章 ok 后即使无 entitlement 查询值也保持已读(购后退款回退不在 UI 语义内)
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m3, state: .ok(text: "x", cached: true), hasEntitlement: false),
            .read
        )
    }

    func test_row_fetching_failed_needsInput_locked() {
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m0, state: .fetching, hasEntitlement: false),
            .generating
        )
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m2, state: .failed(message: "网络不稳"), hasEntitlement: true),
            .retryable
        )
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m4, state: .needsInput, hasEntitlement: true),
            .needsInput
        )
        // VM 付费守卫显式置 locked(如购买回退):保持锁态,不被 entitlement 覆盖
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m5, state: .locked, hasEntitlement: true),
            .lockedPaid
        )
    }

    func test_row_pending_fallsBackToAccessSemantics() {
        // 链上游 pending:免费章视觉同未读,付费未购同锁(进章显示布算中)
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m1, state: .pending, hasEntitlement: false),
            .unreadFree
        )
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m6, state: .pending, hasEntitlement: false),
            .lockedPaid
        )
    }

    // MARK: - HomeCTAModel.resolve

    func test_cta_coldStart_isOpenFirstM0() {
        XCTAssertEqual(
            HomeCTAModel.resolve(moduleStates: [:], remainingReads: 3, hasEntitlement: false),
            .openFirst(.m0)
        )
    }

    func test_cta_freeRead_resumesNextUnread() {
        let states: [ModuleID: ModuleState] = [
            .m0: .ok(text: "a", cached: true),
        ]
        XCTAssertEqual(
            HomeCTAModel.resolve(moduleStates: states, remainingReads: 2, hasEntitlement: false),
            .resume(.m1)
        )
    }

    func test_cta_freeExhausted_noEntitlement_isUnlockAll() {
        // 免费两章已读,无 entitlement:下一可读章不存在(付费全锁)→ 解印
        let states: [ModuleID: ModuleState] = [
            .m0: .ok(text: "a", cached: true),
            .m1: .ok(text: "b", cached: true),
        ]
        XCTAssertEqual(
            HomeCTAModel.resolve(moduleStates: states, remainingReads: 5, hasEntitlement: false),
            .unlockAll
        )
    }

    func test_cta_entitled_continuesIntoPaidChapters() {
        // 已购:付费章是合法续读对象,不弹解印
        let states: [ModuleID: ModuleState] = [
            .m0: .ok(text: "a", cached: true),
            .m1: .ok(text: "b", cached: true),
        ]
        XCTAssertEqual(
            HomeCTAModel.resolve(moduleStates: states, remainingReads: 5, hasEntitlement: true),
            .resume(.m2)
        )
    }

    func test_cta_limitReached_blocksNextUnread() {
        // 免费章未读完 + 次数耗尽 → ghost(已读章仍可从目录行重读)
        let states: [ModuleID: ModuleState] = [
            .m0: .ok(text: "a", cached: true),
        ]
        XCTAssertEqual(
            HomeCTAModel.resolve(moduleStates: states, remainingReads: 0, hasEntitlement: false),
            .limitReached
        )
    }

    func test_cta_allRead_isReread() {
        var states: [ModuleID: ModuleState] = [:]
        for module in ModuleID.allCases {
            states[module] = .ok(text: "t", cached: true)
        }
        XCTAssertEqual(
            HomeCTAModel.resolve(moduleStates: states, remainingReads: 0, hasEntitlement: true),
            .reread
        )
    }

    func test_cta_limitReached_blocksEntitledPaidResume() {
        // 次数耗尽但已购:续读付费章同样被次数拦(v1 全模块计次)→ limitReached
        let states: [ModuleID: ModuleState] = [
            .m0: .ok(text: "a", cached: true),
            .m1: .ok(text: "b", cached: true),
        ]
        XCTAssertEqual(
            HomeCTAModel.resolve(moduleStates: states, remainingReads: 0, hasEntitlement: true),
            .limitReached
        )
    }

    // MARK: - ChainProgress(2026-09-08 断点续跑:主页进度横幅纯派生)

    func test_chainProgress_freeUser_runnableIsTwo() {
        // 免费盘:runnable = M0/M1(付费未购不计、M4/M5 无输入不计),全未生成
        let progress = ChainProgress.resolve(
            moduleStates: [:], hasEntitlement: false, hasM4Input: false, hasM5Input: false
        )
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.done, 0)
        XCTAssertEqual(progress.remaining, 2)
        XCTAssertEqual(progress.estimatedMinutes, 2, "2 章 × 45s = 90s → 向上取整 2 分钟")
    }

    func test_chainProgress_entitled_excludesUnfilledM4M5_includesWhenFilled() {
        let states: [ModuleID: ModuleState] = [.m0: .ok(text: "a", cached: true)]
        // 已购但 M4/M5 未填输入:runnable = M0-M3 + M6 + M7 = 6(等用户动作的章不占预计耗时)
        let unfilled = ChainProgress.resolve(
            moduleStates: states, hasEntitlement: true, hasM4Input: false, hasM5Input: false
        )
        XCTAssertEqual(unfilled.total, 6)
        XCTAssertEqual(unfilled.done, 1)
        XCTAssertEqual(unfilled.remaining, 5)
        XCTAssertEqual(unfilled.estimatedMinutes, 4, "5 章 × 45s = 225s → ceil = 4 分钟")
        // 填了输入:捌章全计
        let filled = ChainProgress.resolve(
            moduleStates: states, hasEntitlement: true, hasM4Input: true, hasM5Input: true
        )
        XCTAssertEqual(filled.total, 8)
        XCTAssertEqual(filled.done, 1)
        XCTAssertEqual(filled.remaining, 7)
    }

    func test_chainProgress_estimateMinutesCeiling() {
        XCTAssertEqual(ChainProgress.estimatedMinutes(remaining: 0), 0)
        XCTAssertEqual(ChainProgress.estimatedMinutes(remaining: 1), 1, "45s → 1 分钟")
        XCTAssertEqual(ChainProgress.estimatedMinutes(remaining: 2), 2, "90s → 2 分钟")
        XCTAssertEqual(ChainProgress.estimatedMinutes(remaining: 8), 6, "360s → 6 分钟")
    }

    func test_chainProgress_doneCountsOnlyRunnableOks() {
        // 付费未购时付费章的 ok 不进 done/total(购买回退等极端场景下横幅口径不膨胀)
        let states: [ModuleID: ModuleState] = [
            .m0: .ok(text: "a", cached: true),
            .m2: .ok(text: "b", cached: true),
        ]
        let progress = ChainProgress.resolve(
            moduleStates: states, hasEntitlement: false, hasM4Input: false, hasM5Input: false
        )
        XCTAssertEqual(progress.total, 2)
        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(progress.remaining, 1)
    }
}
