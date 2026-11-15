import XCTest
@testable import QiCompass

/// 章末反馈(2026-11-15 拍板:B6 极简 × B9 三拍退场)的存储与数据面测试。
///
/// 视觉三拍动线属真机目验范畴,此处锁数据契约:
/// - ChapterFeedbackStore:标记幂等读 / 容量整清
/// - ModuleID.feedbackSectionKeys:八章小节 key 全部在 ChapterContent.labels
///   有短名词(chip 不出现裸 snake_case key;模板 bump 增删小节的漂移在此暴露)
final class ChapterFeedbackTests: XCTestCase {

    // MARK: - ChapterFeedbackStore

    func testStoreMarksAndReadsPerChapter() {
        let defaults = UserDefaults(suiteName: "ChapterFeedbackTests")!
        defaults.removePersistentDomain(forName: "ChapterFeedbackTests")
        let hash = "h" + String(repeating: "0", count: 39)

        XCTAssertFalse(ChapterFeedbackStore.hasFeedback(
            contentHash: hash, module: .m0, defaults: defaults))
        ChapterFeedbackStore.markDone(
            contentHash: hash, module: .m0, defaults: defaults)
        XCTAssertTrue(ChapterFeedbackStore.hasFeedback(
            contentHash: hash, module: .m0, defaults: defaults))

        // 同盘不同章 / 同章不同盘 互不影响
        XCTAssertFalse(ChapterFeedbackStore.hasFeedback(
            contentHash: hash, module: .m1, defaults: defaults))
        XCTAssertFalse(ChapterFeedbackStore.hasFeedback(
            contentHash: String(repeating: "x", count: 40),
            module: .m0, defaults: defaults))
    }

    func testStoreCapacityPruneClearsAll() {
        let defaults = UserDefaults(suiteName: "ChapterFeedbackTests-prune")!
        defaults.removePersistentDomain(forName: "ChapterFeedbackTests-prune")

        // 唯一 hash 塞过 2000 上限 → 整清;整清后新一轮(最后 100 条)在,
        // 最老的 2001 条不在(只可能多问一次,无资损;见 store 注释)
        func hash(_ i: Int) -> String {
            String(format: "h%039d", i)
        }
        for i in 0...2100 {
            ChapterFeedbackStore.markDone(
                contentHash: hash(i), module: .m0, defaults: defaults)
        }
        XCTAssertFalse(ChapterFeedbackStore.hasFeedback(
            contentHash: hash(0), module: .m0, defaults: defaults))
        XCTAssertTrue(ChapterFeedbackStore.hasFeedback(
            contentHash: hash(2100), module: .m0, defaults: defaults))
    }

    // MARK: - feedbackSectionKeys 与 labels 表对齐(漂移守护)

    func testAllSectionKeysHaveShortLabels() {
        for module in ModuleID.allCases {
            let keys = module.feedbackSectionKeys
            XCTAssertFalse(
                keys.isEmpty, "\(module.rawValue) 反馈小节清单为空")
            for key in keys {
                // labels 缺 key 时 localizedLabel 原样透出 key——
                // 断言短名词存在即断言不等于裸 key
                let label = ChapterContent.localizedLabel(key)
                XCTAssertNotEqual(
                    label, key,
                    "\(module.rawValue) 小节 key=\(key) 缺 labels 短名词(chip 会裸 snake_case)")
            }
        }
    }

    func testNoteKeysExcludedFromSections() {
        // medical_note / disclaimer 是「注」类小字注,不是小节(拍板口径)
        let all = ModuleID.allCases.flatMap(\.feedbackSectionKeys)
        XCTAssertFalse(all.contains("evidence"))
        XCTAssertFalse(all.contains("medical_note"))
        XCTAssertFalse(all.contains("disclaimer"))
    }
}
