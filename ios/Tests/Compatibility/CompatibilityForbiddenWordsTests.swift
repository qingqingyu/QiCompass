import XCTest
@testable import QiCompass

/// 禁词扫描器单元测试(方案 §阶段 6 / D10)。
///
/// 验证:
/// - 命中清单内绝对结论词 → 返回非空 hits
/// - 不命中的模糊叙事 → 返回空数组
/// - 多词命中去重保序
/// - 错误态错误描述(CompatibilityError.forbiddenWordsHit.errorDescription)
final class CompatibilityForbiddenWordsTests: XCTestCase {

    // MARK: - 单词命中

    func test扫描_必成_命中() {
        XCTAssertEqual(ForbiddenWords.scan("此二人必成婚配"), ["必成"])
    }

    func test扫描_必分_命中() {
        XCTAssertEqual(ForbiddenWords.scan("恐必分道扬镳"), ["必分"])
    }

    func test扫描_必破财_命中() {
        XCTAssertEqual(ForbiddenWords.scan("今年必破财"), ["必破财"])
    }

    func test扫描_必定_命中() {
        XCTAssertEqual(ForbiddenWords.scan("必定幸福"), ["必定"])
    }

    func test扫描_一定_命中() {
        XCTAssertEqual(ForbiddenWords.scan("一定会成功"), ["一定会"])
    }

    func test扫描_一定不会_命中() {
        XCTAssertEqual(ForbiddenWords.scan("一定不会出错"), ["一定不会"])
    }

    func test扫描_必然_命中() {
        XCTAssertEqual(ForbiddenWords.scan("必然有所成"), ["必然"])
    }

    func test扫描_绝对_命中() {
        XCTAssertEqual(ForbiddenWords.scan("绝对完美"), ["绝对"])
    }

    func test扫描_铁定_命中() {
        XCTAssertEqual(ForbiddenWords.scan("此事铁定"), ["铁定"])
    }

    func test扫描_注定_命中() {
        XCTAssertEqual(ForbiddenWords.scan("命中注定"), ["注定"])
    }

    // MARK: - 未命中(模糊叙事)

    func test扫描_模糊叙事未命中() {
        let texts = [
            "两人性情较合，有所互补",
            "运势较佳，宜顺势而为",
            "需多沟通，稍有摩擦",
            "倾向和谐，可期",
            "略有波折，亦见机遇",
        ]
        for t in texts {
            XCTAssertTrue(ForbiddenWords.scan(t).isEmpty, "模糊叙事不应命中禁词: \(t)")
        }
    }

    // MARK: - 多词去重

    func test扫描_多词命中去重保序() {
        let text = "必成婚配，必定幸福，注定结合"
        let hits = ForbiddenWords.scan(text)
        XCTAssertEqual(hits, ["必成", "必定", "注定"], "多词命中必须去重保序")
    }

    // MARK: - 错误态描述

    // 2026-08-16 ErrorCode 清理:errorDescription 是用户可见文案,固定人话,
    // 不含「模式 B」等内部术语(技术上下文由 orchestrator throw 点日志记录)。
    func testCompatibilityError_forbiddenWordsHit_错误描述() {
        let err = CompatibilityError.forbiddenWordsHit(words: ["必成", "必分"])
        XCTAssertEqual(err.errorDescription, "解读包含不合规绝对结论，请重试")
    }

    func testCompatibilityError_modeBMissingPersonBChart_错误描述() {
        let err = CompatibilityError.modeBMissingPersonBChart
        XCTAssertEqual(err.errorDescription, "合盘数据异常，请重试")
    }

    func testCompatibilityError_modeBMissingPersonBInput_错误描述() {
        let err = CompatibilityError.modeBMissingPersonBInput
        XCTAssertEqual(err.errorDescription, "合盘数据异常，请重试")
    }
}

// MARK: - T9 繁体禁词形(2026-11-22 竞品差评对照)

extension CompatibilityForbiddenWordsTests {
    func test扫描_繁体_一定會_命中() {
        XCTAssertEqual(ForbiddenWords.scan("你們一定會在一起"), ["一定會"])
    }

    func test扫描_繁体_一定不會_命中() {
        XCTAssertEqual(ForbiddenWords.scan("一定不會出錯"), ["一定不會"])
    }

    func test扫描_繁体_鐵定_命中() {
        XCTAssertEqual(ForbiddenWords.scan("此事鐵定"), ["鐵定"])
    }

    func test扫描_繁体_絕對_命中() {
        XCTAssertEqual(ForbiddenWords.scan("絕對完美"), ["絕對"])
    }

    func test扫描_繁体模糊叙事未命中() {
        // 反例:繁体正常叙事不误伤
        XCTAssertEqual(ForbiddenWords.scan("兩人性情較合,傾向互補"), [])
        XCTAssertEqual(ForbiddenWords.scan("此事較難成行,容易生變"), [])
    }

    func test扫描_繁体_必破財_命中() {
        // 任务书「其余词简繁同形」前提纠错:必破财 繁体作「必破財」不同形,
        // 按任务意图一并补列(review 发现,缓存扫描 0 命中)
        XCTAssertEqual(ForbiddenWords.scan("今年必破財"), ["必破財"])
    }

    func test词表_繁体五词在列() {
        for word in ["一定會", "一定不會", "鐵定", "絕對", "必破財"] {
            XCTAssertTrue(ForbiddenWords.absoluteConclusions.contains(word), "缺 \(word)")
        }
    }
}

// MARK: - 拍板落地(2026-11-22):註定 + D2 英文短语整词匹配

extension CompatibilityForbiddenWordsTests {
    func test扫描_註定_命中() {
        XCTAssertEqual(ForbiddenWords.scan("你們註定在一起"), ["註定"])
    }

    func test扫描_英文短语_整词命中() {
        XCTAssertEqual(ForbiddenWords.scan("You are destined to succeed."), ["destined to"])
        XCTAssertEqual(ForbiddenWords.scan("This venture is doomed."), ["doomed"])
        XCTAssertEqual(ForbiddenWords.scan("You are WILL DEFINITELY win."), ["will definitely"])
        XCTAssertEqual(ForbiddenWords.scan("a 100% match"), ["100%"])
    }

    func test扫描_英文_词边界防误杀() {
        // 子串相同但不成词 / 正常叙事 → 不拦截
        XCTAssertEqual(ForbiddenWords.scan("He is willing to try."), [])
        XCTAssertEqual(ForbiddenWords.scan("You may be destined."), [])
        XCTAssertEqual(ForbiddenWords.scan("The day tends to favor patience."), [])
    }

    func test词表_双端同步计数() {
        // 与 backend forbidden_words.py 数量锁一致(17 中 + 7 英)
        XCTAssertEqual(ForbiddenWords.absoluteConclusions.count, 17)
        XCTAssertEqual(ForbiddenWords.absoluteEnglishPhrases.count, 7)
    }
}
