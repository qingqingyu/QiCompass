import Foundation

/// AI 数据授权记录(T12,2026-11-23 竞品差评对照第二批;D4=B 必勾复选框拍板)。
///
/// Apple 审核指南 5.1.2(i)(2025-11 更新):把个人数据交给第三方 AI 前
/// 「clearly disclose + explicit permission」。落盘两键:
/// - `aiDataConsentVersion`:已同意的口径版本(当前 1;文案实质变化时 +1,
///   老用户重新弹补授权 sheet)
/// - `aiDataConsentAt`:ISO 8601 同意时刻(审计用)
///
/// 存 UserDefaults 而非 SwiftData:授权是设备级身份事实,不属命盘域
/// (重置命盘不清——但「重置全部数据」按任务书把两键归入设置域清除,
/// 让重走 onboarding 重新授权,见 ProfileView.resetAllData)。
enum DataConsent {
    /// 当前授权口径版本。bump 时机:授权文案的**实质变化**(披露范围/服务商
    /// 变更),措辞微调不 bump。
    static let currentVersion = 1

    static let versionKey = "aiDataConsentVersion"
    static let atKey = "aiDataConsentAt"

    /// 写入同意记录(确认排盘点击 / 补授权 sheet 的「同意并继续」共用)。
    static func recordConsent(defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: versionKey)
        defaults.set(
            ISO8601DateFormatter().string(from: Date()), forKey: atKey)
    }

    /// 是否已同意**当前**版本口径(补授权判定唯一入口)。
    static func isCurrent(defaults: UserDefaults = .standard) -> Bool {
        let v = defaults.integer(forKey: versionKey)
        return v >= currentVersion
    }

    /// 启动分流判据(RootTabView onAppear 消费):onboarding 已完成但同意
    /// 记录缺失/版本落后 → 需要补授权 sheet。抽成纯函数对齐 CompleteOnceGate
    /// 范式(测试 target 无 ViewInspector,@State 分流判据不可断言):
    /// - 未授权老用户 → true(弹补授权 sheet)
    /// - 已同意当前版本 → false(不再弹)
    /// - 新用户(hasSeenOnboarding=false)→ false(由确认 sheet 勾选覆盖,
    ///   不走补授权路径;重置全部数据后也回到这一支)
    static func needsRetroConsent(
        hasSeenOnboarding: Bool, defaults: UserDefaults = .standard
    ) -> Bool {
        hasSeenOnboarding && !isCurrent(defaults: defaults)
    }

    /// 清除同意记录(「重置全部数据」调用;重走 onboarding 重新授权)。
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: versionKey)
        defaults.removeObject(forKey: atKey)
    }
}
