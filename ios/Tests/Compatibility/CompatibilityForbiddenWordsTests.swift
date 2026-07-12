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
            "两人性情较合,有所互补",
            "运势较佳,宜顺势而为",
            "需多沟通,稍有摩擦",
            "倾向和谐,可期",
            "略有波折,亦见机遇",
        ]
        for t in texts {
            XCTAssertTrue(ForbiddenWords.scan(t).isEmpty, "模糊叙事不应命中禁词: \(t)")
        }
    }

    // MARK: - 多词去重

    func test扫描_多词命中去重保序() {
        let text = "必成婚配,必定幸福,注定结合"
        let hits = ForbiddenWords.scan(text)
        XCTAssertEqual(hits, ["必成", "必定", "注定"], "多词命中必须去重保序")
    }

    // MARK: - 错误态描述

    func testCompatibilityError_forbiddenWordsHit_错误描述() {
        let err = CompatibilityError.forbiddenWordsHit(words: ["必成", "必分"])
        XCTAssertEqual(err.errorDescription, "解读包含不合规绝对结论,请重试")
    }

    func testCompatibilityError_modeBMissingPersonBChart_错误描述() {
        let err = CompatibilityError.modeBMissingPersonBChart
        XCTAssertEqual(err.errorDescription, "模式 B 后端响应缺少 B 盘数据")
    }
}
