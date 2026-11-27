// TASK-15:删号重认证按 provider 分流的纯函数测试。
import XCTest
@testable import QiCompass

final class DeleteReauthDecisionTests: XCTestCase {
    func test_apple_needs_reauth() throws {
        let d = try ProfileView.deleteReauthDecision(provider: .apple)
        guard case .needsAppleReauth = d else {
            return XCTFail("apple 应需要重认证")
        }
    }

    func test_google_skips_reauth() throws {
        let d = try ProfileView.deleteReauthDecision(provider: .google)
        guard case .skipReauth = d else {
            return XCTFail("google 应跳过重认证")
        }
    }

    func test_nil_user_throws() {
        XCTAssertThrowsError(try ProfileView.deleteReauthDecision(provider: nil)) {
            error in
            XCTAssertTrue(
                error is ProfileView.AccountDeleteStateError,
                "无用户应抛状态错误,不是默认当 Apple 处理")
        }
    }
}
