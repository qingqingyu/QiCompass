import Foundation

/// 客户端用户身份(v1 无账号系统)。
///
/// MONETIZATION.md §Entitlement 数据模型:`user_local_id` = 客户端生成的 UUID。
/// 用于 entitlement 查询的 user 维度(`(content_hash, module, user_local_id)` 三元组)。
///
/// 持久化:UserDefaults(keyed by `com.qicompass.user_local_id`)。
/// 首次启动 lazy 生成,后续读同一值。
///
/// **v2 加账号系统时**:用 `appAccountToken` 关联 Apple StoreKit,无缝迁移。
enum UserIdentity {
    /// 客户端 user_local_id(首次启动 lazy 生成 + 持久化)。
    static let userLocalId: String = {
        let key = "com.qicompass.user_local_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()
}
