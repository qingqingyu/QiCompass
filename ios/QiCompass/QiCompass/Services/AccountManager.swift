import Foundation
import AuthenticationServices

/// Apple 账号用户模型(v2 PR2 账号系统)。
///
/// 从 `ASAuthorizationAppleIDCredential` 提取的字段。fullName/email 仅首次登录 Apple 返回,
/// 之后登录 Apple 不再返(只有 appleUserId + identityToken)。所以持久化后才能再次显示。
struct AppleUser: Equatable {
    let appleUserId: String          // Apple sub(稳定标识,跨设备相同)
    let email: String?               // 首次登录返回,后续 nil(Keychain 持久化首次值)
    let fullName: String?            // 首次登录返回(PersonNameComponents 转 String)
    let identityToken: String        // Apple ID Token JWT(每次登录都返回,会过期)

    static func == (lhs: AppleUser, rhs: AppleUser) -> Bool {
        // 同 appleUserId 即视为同一用户(identityToken 会变)
        lhs.appleUserId == rhs.appleUserId
    }
}

/// Apple 账号登录错误(v2 PR2)。
enum AppleAuthError: LocalizedError {
    case credentialMissing
    case identityTokenDecodingFailed
    case appleUserIdEmpty
    case keychainPersistFailed(underlying: KeychainError)
    case canceled
    case appleError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .credentialMissing:
            return "Apple 登录凭证缺失(ASAuthorizationAppleIDCredential 为 nil)"
        case .identityTokenDecodingFailed:
            return "Apple ID Token 解码失败(非 UTF-8)"
        case .appleUserIdEmpty:
            return "Apple 返回的 userIdentifier(sub)为空"
        case .keychainPersistFailed(let underlying):
            return "登录态写入 Keychain 失败:\(underlying.errorDescription ?? "未知")"
        case .canceled:
            return nil  // 用户取消,静默
        case .appleError(let underlying):
            return "Apple 登录失败:\(underlying.localizedDescription)"
        }
    }

    /// 用户取消静默(对齐 PurchaseError.userCancelled 模式,Apple HIG 建议取消不打扰)
    var isSilent: Bool {
        if case .canceled = self { return true }
        return false
    }
}

/// Apple 账号登录状态机(v2 PR2)。
///
/// @Observable 让 ProfileView 自动刷新登录态。@MainActor 因为 Keychain API + ASAuthorization
/// 都需要主线程访问。
///
/// **Sign in with Apple 流程**:
/// - SignInWithAppleButton 自己触发系统 dialog,onCompletion 回调 Result<ASAuthorization, Error>
/// - handleAuthorization(result:) 解析 ASAuthorizationAppleIDCredential
/// - 成功 → 存 Keychain + state = .signedIn(user)
/// - 失败 → state = .signedOut + 错误回调(对齐"错误显式传播")
///
/// **启动时恢复**:init 时从 Keychain 读 appleUserId + identityToken,有则恢复登录态。
///
/// **本 PR 策略**:后端 PR2.5 未接 /api/auth/sign-in,identityToken 直接当 jwtToken 用
/// (后端没真验,但 UI 完整)。PR2.5 接真后端后再调 /api/auth/sign-in 换自家 JWT。
@Observable
@MainActor
final class AccountManager {

    enum State: Equatable {
        case loading      // 启动时读 Keychain 中
        case signedOut
        case signedIn(AppleUser)
        case failed(String)  // 登录失败(非取消),显错给 UI
    }

    /// 当前登录状态(UI 观察用)。
    private(set) var state: State = .loading

    /// last-known JWT token 快照(nonisolated(unsafe) 让 LiveAPIClient 在 background URLSession
    /// 线程读 token,不用 MainActor.run 切上下文)。仅 init / handleAuthorization / signOut
    /// 三个 @MainActor 入口同步更新。
    nonisolated(unsafe) private(set) var lastKnownJwtToken: String?

    /// PR2.5:APIClient 引用(调 /api/auth/sign-in 换自家 JWT)。
    /// strong(AppEnvironment 持有 apiClient + accountManager,生命周期相同,
    /// 不会循环;LiveAPIClient 反向引用 accountManager 是 weak)。
    /// 由 AppEnvironment 装配后调用 setAPIClient 注入。
    var apiClient: APIClient?

    init() {
        restoreFromKeychain()
    }

    /// AppEnvironment 装配 APIClient 后调(在 setAccountManager 之前/之后均可)。
    func setAPIClient(_ client: APIClient) {
        apiClient = client
        AppLogger.app.info("account.apiClient_injected")
    }

    /// 启动时从 Keychain 恢复登录态(同步,Keychain API 快)。
    private func restoreFromKeychain() {
        do {
            guard let appleUserId = try KeychainHelper.loadString(.appleUserId),
                  !appleUserId.isEmpty else {
                state = .signedOut
                return
            }
            let email = try KeychainHelper.loadString(.userEmail)
            let fullName = try KeychainHelper.loadString(.userFullName)
            let identityToken = try KeychainHelper.loadString(.appleIdentityToken) ?? ""
            let user = AppleUser(
                appleUserId: appleUserId,
                email: email,
                fullName: fullName,
                identityToken: identityToken
            )
            state = .signedIn(user)
            lastKnownJwtToken = user.identityToken.isEmpty ? nil : user.identityToken
            AppLogger.app.info("account.restore.ok appleUserId=\(appleUserId.prefix(8), privacy: .public)")
        } catch let error as KeychainError {
            AppLogger.persistence.error(
                "account.restore.keychain_failed error=\(error.errorDescription ?? "未知", privacy: .public)"
            )
            // Keychain 读失败不阻断 App(降级 signedOut,用户重新登录即可)
            state = .signedOut
        } catch {
            AppLogger.persistence.error(
                "account.restore.unknown_error error=\(String(describing: error), privacy: .public)"
            )
            state = .signedOut
        }
    }

    /// 处理 SignInWithAppleButton 的 onCompletion 回调。
    /// 成功 → 存 Keychain + state = .signedIn
    /// 失败 → 取消静默 / 其他失败显错
    func handleAuthorization(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                AppLogger.app.error("account.signIn.credential_missing")
                state = .failed(AppleAuthError.credentialMissing.errorDescription ?? "登录失败")
                return
            }
            do {
                let user = try parseCredential(credential)
                try persist(user: user)
                state = .signedIn(user)
                lastKnownJwtToken = user.identityToken.isEmpty ? nil : user.identityToken
                AppLogger.app.info("account.signIn.ok appleUserId=\(user.appleUserId.prefix(8), privacy: .public)")
                // PR2.5:登录成功后异步调 /api/auth/sign-in 换自家 JWT
                // 失败不阻断登录(用户可重试 / 降级用 identityToken)
                Task { await exchangeJwtToken(user: user) }
            } catch let error as AppleAuthError {
                AppLogger.app.error(
                    "account.signIn.failed error=\(error.errorDescription ?? "未知", privacy: .public)"
                )
                if !error.isSilent {
                    state = .failed(error.errorDescription ?? "登录失败")
                } else {
                    // 用户取消,不更新 state(保持原状)
                }
            } catch {
                AppLogger.app.error(
                    "account.signIn.unknown_error error=\(String(describing: error), privacy: .public)"
                )
                state = .failed(error.localizedDescription)
            }

        case .failure(let asError):
            // ASAuthorization.Error.code == .canceled 是用户主动取消
            if let asAuthError = asError as? ASAuthorizationError,
               asAuthError.code == .canceled {
                AppLogger.app.info("account.signIn.canceled")
                // 静默,不更新 state
                return
            }
            AppLogger.app.error(
                "account.signIn.apple_error code=\((asError as NSError).code) msg=\(asError.localizedDescription, privacy: .public)"
            )
            state = .failed(AppleAuthError.appleError(underlying: asError).errorDescription ?? "登录失败")
        }
    }

    /// 退出登录:清 Keychain + state = .signedOut。
    func signOut() {
        let errors = KeychainHelper.deleteAllAccountKeys()
        if !errors.isEmpty {
            AppLogger.persistence.error(
                "account.signOut.keychain_errors count=\(errors.count, privacy: .public)"
            )
            // 不阻断登出,Keychain 残留不致命(下次登录覆盖)
        }
        state = .signedOut
        lastKnownJwtToken = nil
        AppLogger.app.info("account.signOut.ok")
    }

    /// 是否已登录(API 调用前判断 Authorization header 注入用)。
    var isLoggedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    /// 当前 JWT token(APIClient 注入 Authorization header 用)。
    /// 本 PR 暂时返 identityToken(Apple ID Token)。PR2.5 接后端后改为返自家 JWT。
    var jwtToken: String? {
        guard case .signedIn(let user) = state else { return nil }
        return user.identityToken.isEmpty ? nil : user.identityToken
    }

    // MARK: - 内部

    /// PR2.5:调 /api/auth/sign-in 把 Apple identity_token 换成自家 JWT。
    /// 成功 → KeychainHelper.jwtToken 替换为自家 JWT + lastKnownJwtToken 同步更新。
    /// 失败 → 保留原 identityToken(降级,不阻断登录态)。
    private func exchangeJwtToken(user: AppleUser) async {
        guard let client = apiClient else {
            AppLogger.app.warning("account.exchangeJwtToken.skip reason=no_api_client")
            return
        }
        do {
            AppLogger.app.info("account.exchangeJwtToken.start appleUserId=\(user.appleUserId.prefix(8), privacy: .public)")
            let resp = try await client.signIn(
                request: SignInRequest(identityToken: user.identityToken)
            )
            try KeychainHelper.saveString(resp.accessToken, for: .jwtToken)
            // 同步更新 lastKnownJwtToken(APIClient 后续请求用自家 JWT 而非 identityToken)
            lastKnownJwtToken = resp.accessToken
            AppLogger.app.info(
                "account.exchangeJwtToken.ok userId=\(resp.userId.prefix(8), privacy: .public) expiresAt=\(resp.expiresAt, privacy: .public)"
            )
        } catch {
            // 失败保留原 identityToken,用户已登录态不破(降级)。下次启动可重试(后端可能短暂不可达)
            AppLogger.app.error(
                "account.exchangeJwtToken.failed error=\(String(describing: error), privacy: .public) — 降级用 identityToken"
            )
        }
    }

    /// 解析 ASAuthorizationAppleIDCredential → AppleUser。
    private func parseCredential(_ credential: ASAuthorizationAppleIDCredential) throws -> AppleUser {
        guard !credential.user.isEmpty else {
            throw AppleAuthError.appleUserIdEmpty
        }
        // identityToken:Data? → UTF-8 String
        var identityToken = ""
        if let data = credential.identityToken {
            guard let s = String(data: data, encoding: .utf8) else {
                throw AppleAuthError.identityTokenDecodingFailed
            }
            identityToken = s
        }
        // email / fullName 仅首次返回(后续 nil),保留 Keychain 已有值
        let email = credential.email ?? (try? KeychainHelper.loadString(.userEmail))
        let fullName: String? = {
            if let components = credential.fullName {
                return PersonNameComponentsFormatter().string(from: components)
            }
            return try? KeychainHelper.loadString(.userFullName)
        }()
        return AppleUser(
            appleUserId: credential.user,
            email: email,
            fullName: fullName,
            identityToken: identityToken
        )
    }

    /// 持久化 AppleUser 到 Keychain(逐字段存,失败抛 KeychainError)。
    private func persist(user: AppleUser) throws {
        do {
            try KeychainHelper.saveString(user.appleUserId, for: .appleUserId)
            try KeychainHelper.saveString(user.identityToken, for: .appleIdentityToken)
            // jwtToken 与 appleIdentityToken 同值(本 PR 后端 PR2.5 前策略)
            try KeychainHelper.saveString(user.identityToken, for: .jwtToken)
            if let email = user.email {
                try KeychainHelper.saveString(email, for: .userEmail)
            }
            if let fullName = user.fullName {
                try KeychainHelper.saveString(fullName, for: .userFullName)
            }
        } catch let error as KeychainError {
            throw AppleAuthError.keychainPersistFailed(underlying: error)
        }
    }
}
