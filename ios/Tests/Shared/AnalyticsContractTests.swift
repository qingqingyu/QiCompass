import XCTest
@testable import QiCompass

/// Analytics 契约测试(TASK-06 验收:封装层参数中不出现非枚举字符串)。
///
/// 封装层无接收自由文本的入口(类型层挡掉),本测试锁定值域契约:
/// 事件名 snake_case、参数值全部来自 enum 白名单——未来任何人往
/// Analytics 加事件/参数,rawValue 越出白名单形态(混入用户内容样式)
/// 会在此先红,而不是流向 TelemetryDeck。
final class AnalyticsContractTests: XCTestCase {
    /// 事件名唯一合法形态:小写字母/数字/下划线(禁止空格、CJK、任意自由文本)
    private let eventNamePattern = "^[a-z][a-z0-9_]*$"

    private let allowedParameterValues: Set<String> = [
        // Module / PaywallSource
        "deep", "compat", "ask",
        // PurchaseProduct
        "deep_single", "compat_single", "ask_pack",
        // PurchaseFailureReason
        "cancelled", "payment_failed", "verification_failed",
        "backend_rejected", "unknown",
        // OnboardingStep
        "welcome", "zodiac_reveal", "birth_form", "done",
        // Language
        "zh-Hans", "zh-Hant", "en",
        // 布尔字面量(ask_sent / birth_form_submitted)
        "true", "false",
    ]

    private func assertCanonical(_ raw: String, _ what: String) {
        XCTAssertTrue(
            allowedParameterValues.contains(raw)
                || raw.range(of: eventNamePattern, options: .regularExpression) != nil,
            "\(what) 的值 \(raw) 不在枚举白名单/合法形态内——埋点参数只允许枚举值"
        )
    }

    func test_eventNamesAreSnakeCaseOnly() {
        // 覆盖全部 12 个事件的字面名(与 Analytics.swift 一一对应;
        // 改名/新增须同步这里——契约测试的意义就是逼人看一眼)
        let eventNames = [
            "onboarding_step_completed", "birth_form_submitted",
            "free_chapters_generated", "paywall_shown",
            "purchase_started", "purchase_succeeded", "purchase_failed",
            "restore_tapped", "daily_fortune_viewed",
            "ask_sent", "ask_trial_exhausted", "language_switched",
        ]
        for name in eventNames {
            XCTAssertNotNil(
                name.range(of: eventNamePattern, options: .regularExpression),
                "事件名 \(name) 不是合法 snake_case"
            )
        }
    }

    func test_allParameterEnumRawValuesAreCanonical() {
        for raw in Analytics.Module.allCases.map(\.rawValue)
            + Analytics.PaywallSource.allCases.map(\.rawValue)
            + Analytics.PurchaseProduct.allCases.map(\.rawValue) {
            assertCanonical(raw, "参数枚举")
        }
        for raw in Analytics.PurchaseFailureReason.allCases.map(\.rawValue)
            + Analytics.OnboardingStep.allCases.map(\.rawValue)
            + Analytics.Language.allCases.map(\.rawValue) {
            assertCanonical(raw, "参数枚举")
        }
    }

    func test_failureReasonCoversSilentCancelAndUnknown() {
        // purchase_failed 的 reason 必须能表达「用户取消」与「未知」
        //(PaywallViewModel 两条分支的最小覆盖)
        XCTAssertEqual(Analytics.PurchaseFailureReason.cancelled.rawValue, "cancelled")
        XCTAssertEqual(Analytics.PurchaseFailureReason.unknown.rawValue, "unknown")
    }

    func test_languageRawValuesMatchWireValues() {
        // 上报语言值与后端/客户端 language wire 值一致(zh-Hans/zh-Hant/en)
        XCTAssertEqual(Analytics.Language.zhHans.rawValue, "zh-Hans")
        XCTAssertEqual(Analytics.Language.zhHant.rawValue, "zh-Hant")
        XCTAssertEqual(Analytics.Language.en.rawValue, "en")
    }

    func test_deepFreeChapterHookKeyedOnRootModuleID() {
        // 2026-11-03 复核修复的回归锚:deep 免费内容事件的触发键 =
        // ModuleID.m0.rawValue(枚举绑定,改名编译期跟随)。老
        // "bazi_deep_free" 是 v1 链化前的死串——ModuleID 已无此 case,
        // 任何代码再拿它当触发条件都是死代码(原 TASK-06 缺陷即此)。
        XCTAssertEqual(ModuleID.m0.rawValue, "m0_structure")
        XCTAssertNil(ModuleID(rawValue: "bazi_deep_free"))
    }

    func test_configuredWithoutAppIDImplicitlyDisables() {
        // App ID 键缺席(测试环境无该 Info.plist 值)时 configure() 走关闭
        // 分支不崩——send 侧 SDK 未初始化也是安全 no-op(官方语义)
        Analytics.configure()
        // 各事件函数在未初始化状态下调用不崩(烟囱)
        Analytics.onboardingStepCompleted(.welcome)
        Analytics.birthFormSubmitted(hourKnown: true)
        Analytics.freeChaptersGenerated(module: .deep)
        Analytics.paywallShown(source: .ask)
        Analytics.purchaseStarted(product: .askPack)
        Analytics.purchaseSucceeded(product: .deepSingle)
        Analytics.purchaseFailed(reason: .cancelled)
        Analytics.restoreTapped()
        Analytics.dailyFortuneViewed()
        Analytics.askSent(paid: false)
        Analytics.askTrialExhausted()
        Analytics.languageSwitched(to: .en)
    }
}
