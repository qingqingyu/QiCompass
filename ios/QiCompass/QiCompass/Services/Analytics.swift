import Foundation
import TelemetryDeck

/// 埋点统一封装(TASK-06,2026-11-01 事件表经用户确认)。
///
/// 纪律(任务书红线):
/// - **业务代码只调本文件**,不直接 import TelemetryDeck / 不碰 SDK 类型
/// - 事件名与参数值一律 enum/bool 约束——**禁止上报**出生信息、命盘内容、
///   解读正文、问事原文、content_hash、任何自由文本(封装层无接收自由
///   文本的入口,类型层挡掉)
/// - 不跨 App 追踪、不接 ATT;TelemetryDeck 匿名(随机会话 ID),
///   Debug 构建 SDK 默认 testMode(只在 Telemetry Viewer 测试模式可见)
/// - App ID 从 Info.plist `TELEMETRYDECK_APP_ID` 读,不硬编码;未配置
///   = 埋点关闭(本地构建/未接后台),显式日志不崩
enum Analytics {
    private static let appIDInfoKey = "TELEMETRYDECK_APP_ID"

    /// QiCompassApp.init 调一次;重复调用 SDK 自身幂等。
    /// 未配置(App ID 空)= 埋点完全关闭:不 initialize,**signal 全部
    /// 短路**——空 config 下发信号在 SDK 内部走未定义路径(测试宿主
    /// 实测崩溃),显式闸掉最稳。
    private static var isConfigured = false

    /// signal 出口(生产恒为 TelemetryDeck;测试可注入捕获闭包断言上报,
    /// TASK-08 复核返工引入——runV1Module 免费章上报的行为可测性)
    private static var signalSink: (String, [String: String]) -> Void =
        { TelemetryDeck.signal($0, parameters: $1) }

    #if DEBUG
    /// 仅供测试:替换 signal 出口并强制启用(绕过 App ID 配置闸);
    /// 用例结束必须调 resetSinkForTesting() 恢复,防串同进程其他用例。
    static func replaceSinkForTesting(
        _ sink: @escaping (String, [String: String]) -> Void
    ) {
        signalSink = sink
        isConfigured = true
    }

    static func resetSinkForTesting() {
        signalSink = { TelemetryDeck.signal($0, parameters: $1) }
        isConfigured = false
    }
    #endif

    static func configure() {
        let appID = Bundle.main
            .object(forInfoDictionaryKey: appIDInfoKey) as? String
        // 空串或未展开的 build setting 字面量($(VAR))都按未配置处理
        // ——拿垃圾 ID 初始化 = 信号全部上报失败,比关闭更糟
        let configured = appID.map {
            !$0.isEmpty && !$0.hasPrefix("$(")
        } ?? false
        guard configured, let appID else {
            AppLogger.app.info(
                "TelemetryDeck 未配置 \(appIDInfoKey, privacy: .public),埋点关闭"
            )
            return
        }
        isConfigured = true
        // testMode 不显式设:SDK 默认 DEBUG 构建标记 Testing 信号,
        // Release 走正式——正是「Debug 不上报正式数据」的语义
        TelemetryDeck.initialize(config: .init(appID: appID))
        AppLogger.app.info("TelemetryDeck 初始化完成(事件表 2026-11-01 确认稿)")
    }

    // MARK: - 参数枚举(上报值域的唯一来源;AnalyticsContractTests 锁定)

    enum Module: String, CaseIterable {
        case deep, compat
    }

    enum PaywallSource: String, CaseIterable {
        case deep, compat, ask
    }

    enum PurchaseProduct: String, CaseIterable {
        case deepSingle = "deep_single"
        case compatSingle = "compat_single"
        case askPack = "ask_pack"
    }

    enum PurchaseFailureReason: String, CaseIterable {
        case cancelled
        case paymentFailed = "payment_failed"
        case verificationFailed = "verification_failed"
        case backendRejected = "backend_rejected"
        case unknown
    }

    enum OnboardingStep: String, CaseIterable {
        case welcome
        case zodiacReveal = "zodiac_reveal"
        case birthForm = "birth_form"
        case done
    }

    enum Language: String, CaseIterable {
        case zhHans = "zh-Hans"
        case zhHant = "zh-Hant"
        case en
    }

    // MARK: - 事件(2026-11-01 用户确认的 12 项)

    static func onboardingStepCompleted(_ step: OnboardingStep) {
        signal("onboarding_step_completed", ["step": step.rawValue])
    }

    static func birthFormSubmitted(hourKnown: Bool) {
        signal("birth_form_submitted", ["hour_known": hourKnown ? "true" : "false"])
    }

    static func freeChaptersGenerated(module: Module) {
        signal("free_chapters_generated", ["module": module.rawValue])
    }

    static func paywallShown(source: PaywallSource) {
        signal("paywall_shown", ["source": source.rawValue])
    }

    static func purchaseStarted(product: PurchaseProduct) {
        signal("purchase_started", ["product": product.rawValue])
    }

    static func purchaseSucceeded(product: PurchaseProduct) {
        signal("purchase_succeeded", ["product": product.rawValue])
    }

    static func purchaseFailed(reason: PurchaseFailureReason) {
        signal("purchase_failed", ["reason": reason.rawValue])
    }

    static func restoreTapped() {
        signal("restore_tapped")
    }

    static func dailyFortuneViewed() {
        signal("daily_fortune_viewed")
    }

    static func askSent(paid: Bool) {
        signal("ask_sent", ["paid": paid ? "true" : "false"])
    }

    static func askTrialExhausted() {
        signal("ask_trial_exhausted")
    }

    static func languageSwitched(to: Language) {
        signal("language_switched", ["to": to.rawValue])
    }

    /// 唯一出口:参数字典值域由上面各 enum 拼装,自由文本进不来;
    /// 未配置时短路(不碰 SDK)。
    private static func signal(
        _ name: String, _ parameters: [String: String] = [:],
    ) {
        guard isConfigured else { return }
        signalSink(name, parameters)
    }
}
