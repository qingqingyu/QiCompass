import Foundation
import AuthenticationServices
import GoogleSignIn
import UIKit

/// 登录方式(与后端 /api/auth/sign-in 的 provider 字段对齐)。
enum AuthProvider: String, Sendable {
    case apple
    case google

    /// UI 显示名(ProfileView 账号区文案)。
    var displayName: String {
        switch self {
        case .apple: return "Apple"
        case .google: return "Google"
        }
    }
}

/// 账号用户模型(v2 PR2 起,2026-08-16 从 AppleUser 泛化为多 provider)。
///
/// fullName/email:Apple 仅首次登录返回;Google 每次都返回(profile)。
/// identityToken 会过期(Apple ~10 分钟 / Google ~1 小时),只用于登录当次
/// exchange 换自家 JWT,不用于后续 API 调用,所以持久化后才能再次显示。
struct AccountUser: Equatable {
    let provider: AuthProvider
    let providerUserId: String   // provider 侧 sub(稳定标识,跨设备相同)
    let email: String?
    let fullName: String?
    let identityToken: String    // provider ID Token JWT(每次登录都返回,会过期)

    static func == (lhs: AccountUser, rhs: AccountUser) -> Bool {
        // 同 provider 同 sub 才是同一账号(Apple/Google 即使 sub 值相同也是两个账号,
        // 对齐后端 UNIQUE(provider, provider_user_id) 的账号隔离决策)
        lhs.provider == rhs.provider && lhs.providerUserId == rhs.providerUserId
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

/// Google 登录错误(2026-08-16,对齐 AppleAuthError 模式)。
enum GoogleAuthError: LocalizedError {
    /// GoogleService-Info.plist 缺失 / 无 CLIENT_ID(配置未就位,不是用户错)
    case notConfigured
    /// 拿不到 presenting ViewController(极端:UI 无 key window)
    case presentingViewControllerMissing
    /// GIDSignIn 成功但 idToken 缺失(契约破坏,显式报错不静默)
    case idTokenMissing
    case googleUserIdEmpty
    case keychainPersistFailed(underlying: KeychainError)
    case canceled
    case googleError(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Google 登录未配置(GoogleService-Info.plist 缺失 CLIENT_ID),请先用 Apple 登录"
        case .presentingViewControllerMissing:
            return "Google 登录窗口未就绪,请重试"
        case .idTokenMissing:
            return "Google 登录成功但未返回 ID Token,请重试"
        case .googleUserIdEmpty:
            return "Google 返回的用户标识为空"
        case .keychainPersistFailed(let underlying):
            return "登录态写入 Keychain 失败:\(underlying.errorDescription ?? "未知")"
        case .canceled:
            return nil  // 用户取消,静默
        case .googleError(let underlying):
            return "Google 登录失败:\(underlying.localizedDescription)"
        }
    }

    var isSilent: Bool {
        if case .canceled = self { return true }
        return false
    }
}

/// 账号登录状态机(v2 PR2 起,Apple / Google 双 provider)。
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
/// **Google 登录流程(2026-08-16 起)**:
/// - GoogleSignInButton 触发 handleGoogleSignIn()
/// - GIDSignIn.signIn(withPresenting:) 系统 WebView → GIDGoogleUser(idToken + profile)
/// - 同样 persist + exchange;GoogleService-Info.plist 未配置时显式显错不崩
/// - Google idToken(~1 小时过期)不持久化,只在登录当次 exchange 用
///
/// **启动时恢复**:init 时从 Keychain 读 provider 身份(appleUserId / googleUserId),
/// 有则恢复登录态;API 调用 token 从 `.jwtToken` 读(exchange 成功后落地的自家 JWT)。
///
/// **token 策略(PR2.5 后端已接)**:`lastKnownJwtToken` 只承载自家 JWT,不回退 identityToken —
/// Apple identityToken 约 10 分钟过期,且后端对"Authorization 存在但验签失败"硬 401
/// (user_local_id 兜底仅覆盖无 header 场景),发过期 token 会断整条 API 链。
/// `.jwtToken` 缺失(exchange 从未成功)→ 无 Authorization header → 后端按端点分两档:
/// interpret 等可选鉴权端点走 user_local_id 兜底(老客户端兼容,链路仍通);
/// redeem / entitlement-list / sync 系强制登录端点,直接 401(重新登录换到 JWT 后恢复)。
@Observable
@MainActor
final class AccountManager {

    enum State: Equatable {
        case loading      // 启动时读 Keychain 中
        case signedOut
        case signedIn(AccountUser)
        case failed(String)  // 登录失败(非取消),显错给 UI
    }

    /// 购买就绪状态(qicompassUserId 是否已通过 exchange 落地)。
    ///
    /// 背景:provider 登录成功(state = .signedIn)≠ 购买就绪 — PurchaseManager 的购买 gate
    /// 与后端 redeem / entitlement / sync 端点都要求自家 JWT + qicompass_user.id,
    /// 两者只在 exchange(/api/auth/sign-in)成功后落地。购买类 UI 用它而非
    /// isLoggedIn 判断,否则会出现"显示可购买、点了却报『请先登录』"的死锁
    /// (2026-08-16 Fix#3 统一购买判据)。
    enum ExchangeState: Equatable, CustomStringConvertible {
        case idle            // 未登录(无 provider 身份)
        case inFlight        // provider 登录成功,exchange 进行中
        case failed(String)  // exchange 失败(qicompassUserId 未落地;重新登录可重试)
        case done            // qicompassUserId 已落地(可购买)

        var description: String {
            switch self {
            case .idle: return "idle"
            case .inFlight: return "inFlight"
            case .failed: return "failed"
            case .done: return "done"
            }
        }
    }

    /// 当前登录状态(UI 观察用)。
    private(set) var state: State = .loading

    /// exchange 进度(购买 gate 用;@Observable 驱动 PaywallView 自动切按钮)。
    private(set) var exchangeState: ExchangeState = .idle

    /// last-known JWT token 快照(nonisolated(unsafe) 让 LiveAPIClient 在 background URLSession
    /// 线程读 token,不用 MainActor.run 切上下文)。仅 init(restoreFromKeychain) /
    /// exchangeJwtToken(成功) / persist(账号切换时清空旧账号 token) / signOut
    /// 四个 @MainActor 入口同步更新,只承载自家 JWT。
    nonisolated(unsafe) private(set) var lastKnownJwtToken: String?

    /// 后端 qicompass_user.id(UUID,entitlement 绑账号用)。
    /// PR2.5 exchangeJwtToken 成功后填充,失败时为 nil(降级:UserIdentity.currentUserId
    /// 兜底用客户端 UUID)。nonisolated(unsafe) 同 lastKnownJwtToken 模式:属性是
    /// immutable String(Sendable),多线程读安全;仅 @MainActor 入口同步写。
    nonisolated(unsafe) private(set) var qicompassUserId: String?

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

    /// PR3.2:登录成功回调(AppEnvironment 装配时注入 SyncManager.pull)。
    /// 仅 exchange 成功后调用(失败不触发:同步链路的 redeem/entitlement/sync
    /// 都是强制登录端点,无自家 JWT 时触发只会连串 401)。
    var onSignedIn: (() async -> Void)?

    /// 启动时从 Keychain 恢复登录态(同步,Keychain API 快)。
    ///
    /// 双 provider 身份键:appleUserId / googleUserId 同时最多一个非空(persist
    /// 的账号切换守卫保证);都有值时优先 apple(防御双键残留的 legacy 场景)。
    private func restoreFromKeychain() {
        do {
            let appleUserId = try KeychainHelper.loadString(.appleUserId)
                .flatMap { $0.isEmpty ? nil : $0 }
            let googleUserId = try KeychainHelper.loadString(.googleUserId)
                .flatMap { $0.isEmpty ? nil : $0 }

            let provider: AuthProvider?
            let providerUserId: String?
            if let appleUserId {
                provider = .apple
                providerUserId = appleUserId
            } else if let googleUserId {
                provider = .google
                providerUserId = googleUserId
            } else {
                provider = nil
                providerUserId = nil
            }
            guard let provider, let providerUserId else {
                state = .signedOut
                exchangeState = .idle
                return
            }

            let email = try KeychainHelper.loadString(.userEmail)
            let fullName = try KeychainHelper.loadString(.userFullName)
            // identityToken 仅 Apple 持久化;Google idToken(~1h 过期)不持久化。
            // 它不用于 API 调用(见类头 token 策略),恢复场景传空串仅占位。
            let identityToken: String
            if provider == .apple {
                identityToken = try KeychainHelper.loadString(.appleIdentityToken) ?? ""
            } else {
                identityToken = ""
            }
            let user = AccountUser(
                provider: provider,
                providerUserId: providerUserId,
                email: email,
                fullName: fullName,
                identityToken: identityToken
            )
            state = .signedIn(user)
            // API 调用 token:自家 JWT(exchange 成功落地,JWT_EXP_MINUTES=30 天)。
            // 缺失/空串 → nil → 请求不带 Authorization header(可选鉴权端点走 user_local_id
            // 兜底,强制登录端点 401,见类头 token 策略:不回退 identityToken)。
            // 空串过滤:旧版 build 曾把可能为 "" 的 identityToken 写进 .jwtToken,
            // 残留 "" 会让 "Bearer " 触发后端硬 401。
            lastKnownJwtToken = try KeychainHelper.loadString(.jwtToken)
                .flatMap { $0.isEmpty ? nil : $0 }
            // PR2.5+:恢复 qicompass_user.id(entitlement 绑账号用);缺失表示
            // exchangeJwtToken 还没跑成功过(或 backfill 失败),UserIdentity 会兜底。
            qicompassUserId = try KeychainHelper.loadString(.qicompassUserId)
            // 购买就绪:qicompassUserId 落地 = done;缺失 = failed(identityToken
            // 已过期无法后台重 exchange,唯一补救路径是重新走登录)
            if let qicompassUserId, !qicompassUserId.isEmpty {
                exchangeState = .done
            } else {
                exchangeState = .failed("账号同步未完成,请重新登录")
            }
            // OSLogMessage 插值 lazy capture,实例属性先提到 local(项目既有惯例)
            let restoredExchange = exchangeState
            let restoredProvider = provider
            AppLogger.app.info("account.restore.ok provider=\(restoredProvider.rawValue, privacy: .public) providerUserId=\(providerUserId.prefix(8), privacy: .public) exchange=\(restoredExchange, privacy: .public)")
        } catch let error as KeychainError {
            AppLogger.persistence.error(
                "account.restore.keychain_failed error=\(error.errorDescription ?? "未知", privacy: .public)"
            )
            // Keychain 读失败不阻断 App(降级 signedOut,用户重新登录即可)
            state = .signedOut
            exchangeState = .idle
        } catch {
            AppLogger.persistence.error(
                "account.restore.unknown_error error=\(String(describing: error), privacy: .public)"
            )
            state = .signedOut
            exchangeState = .idle
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
                // 购买就绪状态机:provider 登录成功 → inFlight(exchangeJwtToken 内部终结为
                // done/failed)。token 不在此处设置:exchange 成功前无自家 JWT,
                // 保持现值(可能为上次 exchange 的有效 token 或 nil;切换账号时
                // persist 已清空旧账号值),见类头 token 策略。
                exchangeState = .inFlight
                AppLogger.app.info("account.signIn.ok provider=apple providerUserId=\(user.providerUserId.prefix(8), privacy: .public)")
                // PR2.5:登录成功后异步调 /api/auth/sign-in 换自家 JWT
                // 失败不阻断登录态(token 为 nil 时 API 请求无 header,
                // 可选鉴权端点兜底 user_local_id,强制登录端点 401,见类头)
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

    /// Google 登录入口(GoogleSignInButton 触发)。
    ///
    /// GoogleService-Info.plist 未配置时显式显错(不静默不崩)— 配置文件就位后
    /// 零代码改动生效(运行时读 CLIENT_ID,见 GoogleSignInConfig)。
    func handleGoogleSignIn() {
        guard let clientID = GoogleSignInConfig.clientID else {
            AppLogger.app.error("account.googleSignIn.not_configured")
            state = .failed(GoogleAuthError.notConfigured.errorDescription ?? "Google 登录未配置")
            return
        }
        guard let presenting = Self.rootViewController() else {
            AppLogger.app.error("account.googleSignIn.no_presenter")
            state = .failed(GoogleAuthError.presentingViewControllerMissing.errorDescription ?? "Google 登录失败")
            return
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        AppLogger.app.info("account.googleSignIn.start")
        Task { @MainActor in
            do {
                let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting)
                let gidUser = result.user
                // idToken 契约校验:缺失显式抛错(错误显式传播,不静默降级)
                guard let idToken = gidUser.idToken?.tokenString, !idToken.isEmpty else {
                    throw GoogleAuthError.idTokenMissing
                }
                guard let googleUserId = gidUser.userID, !googleUserId.isEmpty else {
                    throw GoogleAuthError.googleUserIdEmpty
                }
                let user = AccountUser(
                    provider: .google,
                    providerUserId: googleUserId,
                    email: gidUser.profile?.email,
                    fullName: gidUser.profile?.name,
                    identityToken: idToken
                )
                try persist(user: user)
                state = .signedIn(user)
                exchangeState = .inFlight
                AppLogger.app.info("account.googleSignIn.ok provider=google providerUserId=\(googleUserId.prefix(8), privacy: .public)")
                await exchangeJwtToken(user: user)
            } catch let error as GoogleAuthError {
                AppLogger.app.error(
                    "account.googleSignIn.failed error=\(error.errorDescription ?? "未知", privacy: .public)"
                )
                if !error.isSilent {
                    state = .failed(error.errorDescription ?? "Google 登录失败")
                }
                // 取消静默,不更新 state(对齐 Apple 流程)
            } catch {
                // GIDSignInError.code == .canceled → 用户主动取消,静默
                if let gidError = error as? GIDSignInError, gidError.code == .canceled {
                    AppLogger.app.info("account.googleSignIn.canceled")
                    return
                }
                AppLogger.app.error(
                    "account.googleSignIn.google_error msg=\(error.localizedDescription, privacy: .public)"
                )
                state = .failed(GoogleAuthError.googleError(underlying: error).errorDescription ?? "Google 登录失败")
            }
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
        qicompassUserId = nil
        exchangeState = .idle
        AppLogger.app.info("account.signOut.ok")
    }

    /// 是否已登录(API 调用前判断 Authorization header 注入用)。
    var isLoggedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    /// 当前用户的后端 user_id(qicompass_user.id),已登录时返值,未登录返 nil。
    ///
    /// 用于 entitlement / 同步等需要 user 维度的场景(PurchaseManager 传 appAccountToken、
    /// EntitlementStore 双轨查询)。调用方若需要"未登录兜底",用
    /// `UserIdentity.currentUserId`(内部优先 Keychain.qicompassUserId,fallback userLocalId)。
    var currentUserId: String? {
        qicompassUserId
    }

    // MARK: - 内部

    /// 取 key window 的 rootViewController(GIDSignIn 的 presenting 参数要 VC,
    /// 纯 SwiftUI 无直接入口,走 connectedScences 查询)。
    @MainActor
    private static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow })?
            .rootViewController
    }

    /// 调 /api/auth/sign-in 把 provider identity_token 换成自家 JWT。
    /// 成功(accessToken 非空)→ KeychainHelper.jwtToken 替换为自家 JWT + lastKnownJwtToken 同步更新。
    /// 失败(含空 accessToken 拒收)→ token 保持现值(旧的自家 JWT 或 nil;nil 时 API
    /// 请求无 Authorization,可选鉴权端点兜底 user_local_id / 强制登录端点 401,见类头),登录态不破。
    private func exchangeJwtToken(user: AccountUser) async {
        guard let client = apiClient else {
            AppLogger.app.warning("account.exchangeJwtToken.skip reason=no_api_client")
            exchangeState = .failed("账号同步未就绪,请重新登录")
            return
        }
        var exchangeSucceeded = false
        do {
            AppLogger.app.info("account.exchangeJwtToken.start provider=\(user.provider.rawValue, privacy: .public) providerUserId=\(user.providerUserId.prefix(8), privacy: .public)")
            let resp = try await client.signIn(
                request: SignInRequest(
                    provider: user.provider.rawValue,
                    identityToken: user.identityToken,
                    userLocalId: UserIdentity.userLocalId
                )
            )
            // 空串防御:后端契约 accessToken 非空;空串会让 "Bearer " 触发后端硬 401
            // (断整条 API 链),整个 exchange 拒收(token + userId 都不落地)—
            // 与网络失败同一降级语义,显式记日志非静默。
            if resp.accessToken.isEmpty {
                AppLogger.app.error(
                    "account.exchangeJwtToken.empty_access_token userId=\(resp.userId.prefix(8), privacy: .public) — 拒收,token 保持现值"
                )
                exchangeState = .failed("账号同步返回异常,请重新登录重试")
            } else {
                try KeychainHelper.saveString(resp.accessToken, for: .jwtToken)
                // 同步更新 lastKnownJwtToken(APIClient 后续请求用自家 JWT 而非 identityToken)
                lastKnownJwtToken = resp.accessToken
                // Slice 2:持久化后端 user_id(entitlement 绑账号的核心标识)。
                // PurchaseManager / EntitlementStore 通过 UserIdentity.currentUserId 读 Keychain。
                try KeychainHelper.saveString(resp.userId, for: .qicompassUserId)
                qicompassUserId = resp.userId
                exchangeState = .done
                exchangeSucceeded = true
                AppLogger.app.info(
                    "account.exchangeJwtToken.ok userId=\(resp.userId.prefix(8), privacy: .public) expiresAt=\(resp.expiresAt, privacy: .public)"
                )
            }
        } catch {
            // 失败 token 保持现值(旧自家 JWT 或 nil → 无 header,兜底行为见类头
            // 两档后端鉴权),登录态不破。重新登录可重试(后端可能短暂不可达)。
            AppLogger.app.error(
                "account.exchangeJwtToken.failed error=\(String(describing: error), privacy: .public) — token 保持现值"
            )
            exchangeState = .failed("账号同步失败,请重新登录重试")
        }
        // PR3.2:仅 exchange 成功才触发 onSignedIn(同步链路端点全部强制登录,
        // 无自家 JWT 时触发只会连串 401)
        if exchangeSucceeded, let onSignedIn {
            await onSignedIn()
        }
    }

    /// 解析 ASAuthorizationAppleIDCredential → AccountUser(provider = .apple)。
    private func parseCredential(_ credential: ASAuthorizationAppleIDCredential) throws -> AccountUser {
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
        return AccountUser(
            provider: .apple,
            providerUserId: credential.user,
            email: email,
            fullName: fullName,
            identityToken: identityToken
        )
    }

    /// 持久化 AccountUser 到 Keychain(逐字段存,失败抛 provider 对应的 AuthError)。
    private func persist(user: AccountUser) throws {
        do {
            // 账号切换守卫(原 Apple-only 守卫泛化到双 provider):
            // 登录身份变化 — 同 provider 换号,或跨 provider 换号(Apple→Google / 反向)—
            // 时清旧账号的 token / user_id + 另一 provider 的身份键。
            // `.jwtToken` 不再被登录覆盖(只由 exchangeJwtToken 写),不清会残留旧账号
            // 30 天有效 JWT(signOut 清理部分失败 + 换号登录场景),重启后挂进
            // 新账号会话 → 跨账号数据混淆;双身份键残留会让 restoreFromKeychain
            // 误判登录身份。
            let previousAppleUserId = try KeychainHelper.loadString(.appleUserId)
            let previousGoogleUserId = try KeychainHelper.loadString(.googleUserId)
            let sameProviderPrevious: String? = (user.provider == .apple)
                ? previousAppleUserId
                : previousGoogleUserId
            let otherProviderExisting: String? = (user.provider == .apple)
                ? previousGoogleUserId
                : previousAppleUserId
            let isAccountSwitch =
                (sameProviderPrevious != nil && sameProviderPrevious != user.providerUserId)
                || otherProviderExisting != nil
            if isAccountSwitch {
                try KeychainHelper.delete(.jwtToken)
                try KeychainHelper.delete(.qicompassUserId)
                if user.provider == .apple {
                    try KeychainHelper.delete(.googleUserId)
                } else {
                    try KeychainHelper.delete(.appleUserId)
                }
                lastKnownJwtToken = nil
                qicompassUserId = nil
                AppLogger.app.warning(
                    "account.switch_detected provider=\(user.provider.rawValue, privacy: .public) providerUserId=\(user.providerUserId.prefix(8), privacy: .public) — 已清旧账号 token/user_id"
                )
            }
            switch user.provider {
            case .apple:
                try KeychainHelper.saveString(user.providerUserId, for: .appleUserId)
                try KeychainHelper.saveString(user.identityToken, for: .appleIdentityToken)
            case .google:
                try KeychainHelper.saveString(user.providerUserId, for: .googleUserId)
                // Google idToken(~1h 过期)不持久化:exchange 在登录当次同步完成,
                // 持久化只会留下误导性的过期凭证
            }
            // 注:不写 .jwtToken — 它只承载 exchange 成功后的自家 JWT(exchangeJwtToken 写),
            // 同一账号重复登录但 exchange 失败时不覆盖旧的有效 token(跨账号场景由上方守卫清)。
            if let email = user.email {
                try KeychainHelper.saveString(email, for: .userEmail)
            }
            if let fullName = user.fullName {
                try KeychainHelper.saveString(fullName, for: .userFullName)
            }
        } catch let error as KeychainError {
            switch user.provider {
            case .apple:
                throw AppleAuthError.keychainPersistFailed(underlying: error)
            case .google:
                throw GoogleAuthError.keychainPersistFailed(underlying: error)
            }
        }
    }
}
