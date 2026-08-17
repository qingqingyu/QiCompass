import XCTest
@testable import QiCompass

/// UserFacingError 分类器测试(方案 §D5 / step 2)。
///
/// 验证:
/// - URLError code → networkUnavailable 映射
/// - stage-based 分类(排盘 vs AI)
/// - 后端 `BAZI_CALCULATION_FAILED` → chartFailed(排盘阶段)
/// - 达上限(DeepAnalysisError.dailyLimitReached)→ dailyLimitReached
/// - 用户可见文案白名单(2026-08-16 ErrorCode 清理):各领域错误枚举的
///   errorDescription 不得含技术片段(domain/code/OSStatus/内部术语)
final class UserFacingErrorTests: XCTestCase {

    // MARK: - 用户可见文案白名单(2026-08-16 ErrorCode 清理)

    /// 报障实例:模拟器 SIWA 失败的真实底层错误(domain + code 1000)。
    private let webAuthSessionError = NSError(
        domain: "com.apple.ASWebAuthenticationSession.authorizingError",
        code: 1000,
        userInfo: [NSLocalizedDescriptionKey:
            "The operation couldn't be completed. (com.apple.ASWebAuthenticationSession.authorizingError error 1000.)"]
    )

    private let forbiddenFragments = [
        "com.apple", "Error Domain", "NSURLError", "OSStatus", "sqlite",
        "request_id", "Keychain", "ASAuthorization", "provider=", "hash=",
        "模式 B", "code=", "error ",
    ]

    private func assertUserFacing(_ message: String?, file: StaticString = #filePath, line: UInt = #line) {
        let m = message ?? ""
        XCTAssertFalse(m.isEmpty, "用户文案不得为空串", file: file, line: line)
        for fragment in forbiddenFragments {
            XCTAssertFalse(
                m.contains(fragment),
                "用户文案含技术片段「\(fragment)」:\(m)",
                file: file, line: line
            )
        }
    }

    func test用户文案_AppleAuthError_appleError不含系统错误域() {
        let e = AppleAuthError.appleError(underlying: webAuthSessionError)
        XCTAssertEqual(e.errorDescription, "Apple 登录未完成,请重试")
        assertUserFacing(e.errorDescription)
    }

    func test用户文案_AppleAuthError_其余case全人话() {
        assertUserFacing(AppleAuthError.credentialMissing.errorDescription)
        assertUserFacing(AppleAuthError.identityTokenDecodingFailed.errorDescription)
        assertUserFacing(AppleAuthError.appleUserIdEmpty.errorDescription)
        assertUserFacing(
            AppleAuthError.keychainPersistFailed(underlying: .osStatus(-25299)).errorDescription
        )
    }

    func test用户文案_AppleAuthError_取消仍静默() {
        XCTAssertNil(AppleAuthError.canceled.errorDescription)
        XCTAssertTrue(AppleAuthError.canceled.isSilent)
    }

    func test用户文案_KeychainError不含OSStatus() {
        assertUserFacing(KeychainError.osStatus(-25299).errorDescription)
        assertUserFacing(KeychainError.invalidStringEncoding.errorDescription)
        assertUserFacing(
            KeychainError.unknown(underlying: URLError(.cannotConnectToHost)).errorDescription
        )
    }

    func test用户文案_PurchaseError全case不含底层细节() {
        let underlying = NSError(
            domain: "NSURLErrorDomain",
            code: -1009,
            userInfo: [NSLocalizedDescriptionKey: "Error Domain=NSURLErrorDomain Code=-1009"]
        )
        assertUserFacing(PurchaseError.entitlementStoreFailed(underlying: underlying).errorDescription)
        assertUserFacing(PurchaseError.backendRedeemFailed(underlying: underlying).errorDescription)
        assertUserFacing(PurchaseError.networkFailed(underlying: underlying).errorDescription)
        // verificationFailed 直传构造点文案(PurchaseManager 两处已改人话),
        // 这里断言生产构造点实际使用的固定文案
        XCTAssertEqual(
            PurchaseError.verificationFailed(message: "购买验证失败,请重试").errorDescription,
            "购买验证失败,请重试"
        )
        assertUserFacing(PurchaseError.productNotFound(productId: "com.qicompass.deep_analysis.single").errorDescription)
        assertUserFacing(PurchaseError.pending.errorDescription)
        assertUserFacing(PurchaseError.notSignedIn.errorDescription)
        XCTAssertNil(PurchaseError.userCancelled.errorDescription)
    }

    func test用户文案_城市搜索错误不含sqlite细节() {
        assertUserFacing(CitySearchError.databaseMissing.errorDescription)
        assertUserFacing(CitySearchError.databaseOpenFailed(code: 21).errorDescription)
        assertUserFacing(CitySearchError.queryFailed(message: "database is locked").errorDescription)
    }

    func test用户文案_深度每日合盘领域错误不含内部细节() {
        assertUserFacing(
            DeepAnalysisError.invalidV1ModuleInput("module=bazi_career missing field: birth_datetime").errorDescription
        )
        assertUserFacing(
            AIIdentityError.invalidHealthIdentity(provider: "anthropic", model: "claude-sonnet").errorDescription
        )
        let longHash = String(repeating: "a", count: 64)
        assertUserFacing(
            DailyFortuneSnapshotError.snapshotMissing(chartHash: longHash, targetDate: Date()).errorDescription
        )
        assertUserFacing(
            CompatibilitySnapshotError.snapshotMissing(compatibilityHash: longHash).errorDescription
        )
        assertUserFacing(
            CompatibilityViewModelError.archivedSnapshotMissing(hash: longHash).errorDescription
        )
    }

    // MARK: - 达上限

    func test达上限_DeepAnalysisError映射为UserFacing() {
        let nextReset = Date().addingTimeInterval(3600)
        let error = DeepAnalysisError.dailyLimitReached(nextReset: nextReset, remaining: 0)
        let userError = UserFacingError.from(error, stage: .interpret)

        if case .dailyLimitReached(let mapped) = userError {
            XCTAssertEqual(mapped, nextReset)
        } else {
            XCTFail("应为 .dailyLimitReached,实际:\(userError)")
        }
    }

    // MARK: - URLError → networkUnavailable

    func test网络错误_超时映射为NetworkUnavailable() {
        let urlError = URLError(.timedOut)
        let userError = UserFacingError.from(urlError, stage: .chart)

        XCTAssertEqual(userError, .networkUnavailable)
    }

    func test网络错误_无网络映射为NetworkUnavailable() {
        let urlError = URLError(.notConnectedToInternet)
        let userError = UserFacingError.from(urlError, stage: .dailyDeterministic)

        XCTAssertEqual(userError, .networkUnavailable)
    }

    func test网络错误_连接丢失映射为NetworkUnavailable() {
        let urlError = URLError(.networkConnectionLost)
        let userError = UserFacingError.from(urlError, stage: .compatibilityDeterministic)

        XCTAssertEqual(userError, .networkUnavailable)
    }

    // MARK: - APIError 包装

    func testAPIError包装的URLError_映射为NetworkUnavailable() {
        let apiError = APIError.networkError(URLError(.timedOut))
        let userError = UserFacingError.from(apiError, stage: .chart)

        XCTAssertEqual(userError, .networkUnavailable)
    }

    // MARK: - BAZI_CALCULATION_FAILED

    func test后端排盘库错误_chart阶段映射为ChartFailed() {
        let apiError = APIError.backendError(
            code: "BAZI_CALCULATION_FAILED",
            message: "lunar_python error",
            requestId: "req-123"
        )
        let userError = UserFacingError.from(apiError, stage: .chart)

        if case .chartFailed = userError {
            // 通过
        } else {
            XCTFail("stage=.chart 时应为 .chartFailed,实际:\(userError)")
        }
    }

    func test后端排盘库错误_interpret阶段映射为InterpretFailed() {
        let apiError = APIError.backendError(
            code: "BAZI_CALCULATION_FAILED",
            message: "lunar_python error",
            requestId: "req-123"
        )
        let userError = UserFacingError.from(apiError, stage: .interpret)

        if case .interpretFailed = userError {
            // 通过
        } else {
            XCTFail("stage=.interpret 时应为 .interpretFailed,实际:\(userError)")
        }
    }

    // MARK: - Stage-based 默认分类

    func test未知错误_chart阶段_默认为ChartFailed() {
        struct CustomError: Error {}
        let userError = UserFacingError.from(CustomError(), stage: .chart)

        if case .chartFailed = userError {
            // 通过
        } else {
            XCTFail("stage=.chart 未知错误应默认 .chartFailed,实际:\(userError)")
        }
    }

    func test未知错误_interpret阶段_默认为InterpretFailed() {
        struct CustomError: Error {}
        let userError = UserFacingError.from(CustomError(), stage: .interpret)

        if case .interpretFailed = userError {
            // 通过
        } else {
            XCTFail("stage=.interpret 未知错误应默认 .interpretFailed,实际:\(userError)")
        }
    }

    // MARK: - isOffline

    func testIsOffline_已知离线Code返回True() {
        XCTAssertTrue(UserFacingError.isOffline(URLError(.timedOut)))
        XCTAssertTrue(UserFacingError.isOffline(URLError(.notConnectedToInternet)))
        XCTAssertTrue(UserFacingError.isOffline(URLError(.networkConnectionLost)))
        XCTAssertTrue(UserFacingError.isOffline(URLError(.cannotConnectToHost)))
        XCTAssertTrue(UserFacingError.isOffline(URLError(.cannotFindHost)))
    }

    func testIsOffline_非离线Code返回False() {
        XCTAssertFalse(UserFacingError.isOffline(URLError(.badURL)))
        XCTAssertFalse(UserFacingError.isOffline(URLError(.unsupportedURL)))
    }

    // MARK: - subtitle

    func test二级文案_网络不可用() {
        XCTAssertEqual(UserFacingError.networkUnavailable.subtitle, "网络不通或服务遥远,请稍后重试")
    }

    func test二级文案_排盘异常() {
        XCTAssertEqual(UserFacingError.chartFailed(originalDescription: "x").subtitle, "排盘引擎暂不可用,请稍后重试")
    }

    func test二级文案_命书生成失败() {
        XCTAssertEqual(UserFacingError.interpretFailed(originalDescription: "x").subtitle, "命书暂未能成形,可单独重试(命盘已就绪)")
    }

    func test二级文案_达上限() {
        XCTAssertEqual(UserFacingError.dailyLimitReached(nextReset: Date()).subtitle, "每日 10 次已用完,午夜重置")
    }
}
