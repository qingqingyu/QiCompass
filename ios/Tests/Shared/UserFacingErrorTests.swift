import XCTest
@testable import QiCompass

/// UserFacingError 分类器测试(方案 §D5 / step 2)。
///
/// 验证:
/// - URLError code → networkUnavailable 映射
/// - stage-based 分类(排盘 vs AI)
/// - 后端 `BAZI_CALCULATION_FAILED` → chartFailed(排盘阶段)
/// - 达上限(DeepAnalysisError.dailyLimitReached)→ dailyLimitReached
final class UserFacingErrorTests: XCTestCase {

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
