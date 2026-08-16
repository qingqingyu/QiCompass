import Foundation
import Security

/// Keychain 原生封装(v2 PR2 账号系统)。
///
/// 不引第三方依赖(CLAUDE.md "不擅自加依赖"),用系统 `Security` framework 的 `SecItem*` API。
/// 错误显式传播:`OSStatus` 非 errSecSuccess 抛 `KeychainError.osStatus`,
/// errSecItemNotFound(查不到)按业务语义返回 nil 而非抛错(避免调用方 try/catch 噪音)。
///
/// 存储可访问性:`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
/// - 首次解锁后才能读(避免冷启动后无法恢复登录态)
/// - ThisDeviceOnly:不跨 iCloud Keychain 同步(避免多设备 token 串台,跨设备同步走 PR3)
enum KeychainHelper {

    /// Keychain key 枚举(类型安全,避免字面量散落)。
    enum Key: String {
        case appleUserId         // Apple 返回的 userIdentifier(sub)
        case googleUserId        // Google 返回的 userID(sub,2026-08-16 双 provider 起)
        case appleIdentityToken  // Apple ID Token(JWT 字符串)
        case jwtToken            // 后端 /api/auth/sign-in 返回的自家 JWT(仅 exchange 成功时写入;API 调用唯一 token 来源)
        case userEmail           // provider 返回的 email(Apple 首次登录返回;Google 每次返回)
        case userFullName        // provider 返回的 fullName(Apple 首次;Google 每次)
        case qicompassUserId     // 后端 qicompass_user.id(UUID,entitlement 绑账号用)
    }

    // MARK: - Data 接口

    /// 保存 Data 到 Keychain。已存在则覆盖(update),不存在则 add。
    /// - Throws: `KeychainError.osStatus` 当 SecItemAdd/SecItemUpdate 返回非 errSecSuccess
    static func save(_ data: Data, for key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        // 先尝试 update(已存在则覆盖)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus == errSecItemNotFound {
            // 不存在 → add
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.osStatus(addStatus)
            }
            return
        }
        // 其他 OSStatus 错误(权限 / 参数错)
        throw KeychainError.osStatus(updateStatus)
    }

    /// 读 Data。未找到返回 nil(业务语义"未存过"),其他错误抛 KeychainError。
    static func load(_ key: Key) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil  // 未存过,业务上不算错
        }
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
        return result as? Data
    }

    /// 删除条目。不存在视为成功(幂等),其他错误抛 KeychainError。
    static func delete(_ key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound || status == errSecSuccess {
            return
        }
        throw KeychainError.osStatus(status)
    }

    // MARK: - String 便捷接口(内部 UTF-8 编解码)

    /// 保存字符串(UTF-8 编码)。
    static func saveString(_ string: String, for key: Key) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.invalidStringEncoding
        }
        try save(data, for: key)
    }

    /// 读字符串(UTF-8 解码)。未找到返回 nil。
    static func loadString(_ key: Key) throws -> String? {
        guard let data = try load(key) else { return nil }
        guard let s = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidStringEncoding
        }
        return s
    }

    /// 清除所有已知的账号相关 key(signOut 用)。
    /// 错误聚集:任一 key 删除失败不阻断其他 key,所有错误聚合到返回数组。
    static func deleteAllAccountKeys() -> [KeychainError] {
        var errors: [KeychainError] = []
        for key in [
            Key.appleUserId, .googleUserId, .appleIdentityToken, .jwtToken, .userEmail,
            .userFullName, .qicompassUserId,
        ] {
            do {
                try delete(key)
            } catch let e as KeychainError {
                errors.append(e)
            } catch {
                errors.append(.unknown(underlying: error))
            }
        }
        return errors
    }
}

// MARK: - KeychainError

enum KeychainError: LocalizedError {
    case osStatus(OSStatus)
    case invalidStringEncoding
    case unknown(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .osStatus(let status):
            // SecCopyErrorMessageString 返回 CFString,转 Swift String
            if let msg = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain 操作失败(OSStatus \(status)):\(msg)"
            }
            return "Keychain 操作失败(OSStatus \(status))"
        case .invalidStringEncoding:
            return "Keychain 数据 UTF-8 编解码失败"
        case .unknown(let underlying):
            return "Keychain 未知错误:\(underlying.localizedDescription)"
        }
    }
}
