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
        // 链上游 pending 且链未跑(断链/达限残留):免费章视觉同未读,
        // 付费未购同锁——恢复主路径是 CTA 续读/回前台自动续跑,不在目录行
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m1, state: .pending, hasEntitlement: false),
            .unreadFree
        )
        XCTAssertEqual(
            ChapterRowModel.resolve(module: .m6, state: .pending, hasEntitlement: false),
            .lockedPaid
        )
    }

    func test_row_pending_chainRunningFree_isQueued() {
        // 2026-10-15:链在跑 + 免费章排队 → 排队中(行尾静态小字,
        // 点击不进章只提示——等待页「约半分钟」对排队章是虚假承诺)
        XCTAssertEqual(
            ChapterRowModel.resolve(
                module: .m1, state: .pending, hasEntitlement: false,
                chainRunning: true),
            .queued
        )
    }

    func test_row_pending_chainRunningPaidUnpaid_staysLockedPaid() {
        // 付费未购章排队中不给「会自动生成」承诺:链走到它只会落 .locked,
        // 维持付费锁视觉(PaidTag + 点击付费墙)
        XCTAssertEqual(
            ChapterRowModel.resolve(
                module: .m2, state: .pending, hasEntitlement: false,
                chainRunning: true),
            .lockedPaid
        )
    }

    func test_row_pending_chainRunningPaidEntitled_isQueued() {
        // 已购付费章:链会自动生成它,排队承诺成立
        XCTAssertEqual(
            ChapterRowModel.resolve(
                module: .m7, state: .pending, hasEntitlement: true,
                chainRunning: true),
            .queued
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

    func test_cta_limitReached_passesEntitledPaidResume() {
        // 次数耗尽但下一章是**已购付费章**(拍板①:付费 m2-m7 不扣本地池,
        // 本地池 = 免费体验配额,付费护栏在服务端 paid 桶)→ 开卷不拦;
        // 修复前 remaining≤0 一刀切 .limitReached,已购内容被 CTA 谎报拦死
        let states: [ModuleID: ModuleState] = [
            .m0: .ok(text: "a", cached: true),
            .m1: .ok(text: "b", cached: true),
        ]
        XCTAssertEqual(
            HomeCTAModel.resolve(moduleStates: states, remainingReads: 0, hasEntitlement: true),
            .resume(.m2)
        )
    }

    func test_cta_limitReached_stillBlocksFreeNext() {
        // 次数耗尽且下一章是免费章(要扣本地池)→ 仍 .limitReached
        let states: [ModuleID: ModuleState] = [
            .m0: .ok(text: "a", cached: true),
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

    // MARK: - B1(2026-11-06):阅读页 pending 态分诊

    func test_pendingChapterBody_链在跑_排队等待() {
        XCTAssertEqual(
            PendingChapterBody.resolve(state: .pending, chainRunning: true),
            .calculating,
            "链在跑的 pending = 排队章,维持三墨点等待观感"
        )
    }

    func test_pendingChapterBody_链已停_断链残留引导() {
        XCTAssertEqual(
            PendingChapterBody.resolve(state: .pending, chainRunning: false),
            .stalledGuide,
            "链停 + pending = 无人生成的残留,必须渲染引导态(说明 + 继续生成 CTA),不得再演布算中"
        )
    }

    func test_pendingChapterBody_非pending防御_等待观感() {
        XCTAssertEqual(
            PendingChapterBody.resolve(state: .fetching, chainRunning: false),
            .calculating,
            "非 pending 态不经本模型;防御性按等待观感(不误报可续跑)"
        )
        XCTAssertEqual(
            PendingChapterBody.resolve(state: nil, chainRunning: false),
            .calculating
        )
    }

    // MARK: - A4(2026-11-06):大运「当前」高亮比 startYear

    func test_luckPillar_isCurrent_比startYear_六十甲子回绕不双高亮() {
        // 60 年前后两步同干支大运(ganZhi 相同,startYear 不同)
        let early = LuckPillarDTO(ganZhi: "甲子", startYear: 1990, endYear: 1999, startAge: 1, endAge: 10)
        let late = LuckPillarDTO(ganZhi: "甲子", startYear: 2050, endYear: 2059, startAge: 61, endAge: 70)
        let current = CurrentPillarDTO(ganZhi: "甲子", startYear: 2050, endYear: 2059)

        XCTAssertFalse(
            LuckPillarsTimeline.isCurrent(early, current: current),
            "ganZhi 同但 startYear 不同:早柱不得高亮(旧 ganZhi 比较会双高亮)"
        )
        XCTAssertTrue(
            LuckPillarsTimeline.isCurrent(late, current: current),
            "startYear 对齐的当前柱必须高亮"
        )
        XCTAssertFalse(
            LuckPillarsTimeline.isCurrent(late, current: nil),
            "无当前柱(nil)全不高亮"
        )
    }

    // MARK: - A1(2026-11-06):真太阳时按出生地时区渲染

    /// 北京出生盘的钟面必须按 +08 渲染,与设备时区无关(美东设备此前
    /// 会把钟面/日期错位)。两消费点共用同款出生地时区语义。
    func test_trueSolarTimeText_按出生地时区渲染() throws {
        var beijing = Calendar(identifier: .gregorian)
        beijing.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let instant = beijing.date(from: DateComponents(
            year: 1993, month: 5, day: 21, hour: 2, minute: 30))!

        // meta 行消费点(ChartHeaderView)
        XCTAssertEqual(
            ChartHeaderView.trueSolarTimeText(instant, timezoneID: "Asia/Shanghai"),
            "1993-05-21 02:30",
            "真太阳时钟面按出生地时区(+08)渲染,设备时区无关"
        )
        // 合盘 prompt 出生串消费点(PromptContextBuilder.chartContext)
        XCTAssertEqual(
            PromptContextBuilder.birthClockText(instant, timezoneID: "Asia/Shanghai"),
            "1993-05-21 02:30"
        )
        // 老快照 tzID nil:兜底设备时区(与既有行为一致,只断言可渲染)
        XCTAssertFalse(ChartHeaderView.trueSolarTimeText(instant, timezoneID: nil).isEmpty)
        XCTAssertFalse(PromptContextBuilder.birthClockText(instant, timezoneID: nil).isEmpty)
        // 非法标识符同兜底,不崩
        XCTAssertFalse(ChartHeaderView.trueSolarTimeText(instant, timezoneID: "Not/AZone").isEmpty)
    }
}
