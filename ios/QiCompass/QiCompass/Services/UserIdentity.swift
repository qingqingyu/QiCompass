import Foundation

/// 客户端用户身份(v1.5 双轨:已登录走后端 user_id,未登录走客户端 UUID 兜底)。
///
/// **双轨设计**(Slice 3 改造,对齐 entitlement 绑 Apple 账号决策):
/// - `userLocalId`:客户端 lazy UUID,存 UserDefaults,跟 Apple 账号无关。
///   首启动生成一次,后续读同一值;删 App / 重装会重新生成(失去 entitlement 关联)。
/// - `currentUserId`:优先返 Keychain 的 `.qicompassUserId`(后端 user.id,跨设备稳定),
///   缺失则 fallback `userLocalId`。所有需要 user 维度的调用方
///   (PurchaseManager / EntitlementStore / SyncManager / DeepAnalysisOrchestrator)
///   应该用这个,不要直接读 userLocalId。
/// - `isAuthenticated`:是否已登录(等价于 Keychain 有 qicompassUserId)。
///
/// 持久化:
/// - `userLocalId`:UserDefaults(keyed by `com.qicompass.user_local_id`)
/// - `qicompassUserId`:Keychain(`.qicompassUserId`,由 AccountManager.exchangeJwtToken 写)
enum UserIdentity {
    /// 客户端 user_local_id(首次启动 lazy 生成 + 持久化)。
    static let userLocalId: String = {
        let key = "com.qicompass.user_local_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            // 规则 2:函数入口日志(已存在身份,常规路径)
            AppLogger.app.info("UserIdentity.userLocalId loaded existing=\(existing.prefix(8), privacy: .public)")
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        // 规则 2:首次生成分支日志(首启 / 重装后)
        AppLogger.app.info("UserIdentity.userLocalId generated new=\(new.prefix(8), privacy: .public)")
        return new
    }()

    /// 当前用户身份:已登录走后端 qicompass_user.id,未登录兜底客户端 UUID。
    ///
    /// 用于 entitlement / 命盘同步等需要 user 维度的场景。**所有调用方应使用这个**,
    /// 不要直接读 `userLocalId`(老代码保留兼容,但新代码用 currentUserId)。
    ///
    /// 后端 entitlement.user_id 字段对应这个值;PurchaseManager 把它当
    /// appAccountToken 传 StoreKit(qicompass_user.id 是 UUID 格式,符合 Apple 要求)。
    static var currentUserId: String {
        if let backendId = try? KeychainHelper.loadString(.qicompassUserId),
           !backendId.isEmpty {
            return backendId
        }
        return userLocalId
    }

    /// 是否已登录(等价于 Keychain 有 .qicompassUserId)。
    /// PurchaseManager 强制登录检查 / PaywallView 未登录 gate 用这个。
    static var isAuthenticated: Bool {
        guard let id = try? KeychainHelper.loadString(.qicompassUserId),
              !id.isEmpty else {
            return false
        }
        return true
    }
}
