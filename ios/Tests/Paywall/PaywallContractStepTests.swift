import XCTest
@testable import QiCompass

/// B 章回分段(2026-09-05 design-shotgun 定稿 variant-b)纯逻辑守护:
/// - 契约 stepper 阶段派生(判据与 Fix#3 购买按钮分支同构)
/// - 人民币大写落价转换(壹佰贰拾捌圆整;宁缺毋错:解析不了 → nil)
final class PaywallContractStepTests: XCTestCase {

    // MARK: - stepper 阶段派生

    func test_step_sealing_whenSignedOut() {
        XCTAssertEqual(PaywallContractStep.derive(signedIn: false, exchangeDone: false), .sealing)
        XCTAssertEqual(PaywallContractStep.derive(signedIn: false, exchangeDone: true), .sealing)
    }

    func test_step_sealing_whenSignedInButExchangeNotDone() {
        // signedIn ≠ 可购(Fix#3:购买就绪 = exchange 完成,非仅 SIWA 成功)
        XCTAssertEqual(PaywallContractStep.derive(signedIn: true, exchangeDone: false), .sealing)
    }

    func test_step_dealing_whenSignedInAndExchangeDone() {
        XCTAssertEqual(PaywallContractStep.derive(signedIn: true, exchangeDone: true), .dealing)
    }

    // MARK: - 大写落价(整价照转)

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

    // MARK: - 大写落价(抑制:宁缺毋错,不造假大写)

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
}
