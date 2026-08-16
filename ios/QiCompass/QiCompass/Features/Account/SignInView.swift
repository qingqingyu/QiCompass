import SwiftUI
import AuthenticationServices
import GoogleSignInSwift

/// Sign in with Apple 按钮 包装(v2 PR2)。
///
/// Apple HIG 要求 SignInWithAppleButton 不可改颜色,只可选 4 种系统样式(.black/.white/.whiteOutline)。
/// 本项目 BaziTheme.paper 是极浅暖白,选 `.black` 黑底白字,与 PrimaryCTAButton 朱砂并列形成层级
/// (PrimaryCTAButton 是 App 内主操作,Apple 按钮是账号系统专属)。
///
/// **解耦设计**:按钮不持有 AccountManager,通过 onResult 回调把 Apple 返回的
/// Result<ASAuthorization, Error> 抛给调用方(ProfileView 处理)。
/// 这样本组件无业务依赖,可在任何地方复用。
struct AppleSignInButton: View {
    /// 登录结果回调(成功 ASAuthorization / 失败 Error)。
    let onResult: (Result<ASAuthorization, Error>) -> Void

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            // 请求 fullName + email(仅首次登录 Apple 返回,之后 nil)
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            onResult(result)
        }
        .signInWithAppleButtonStyle(.black)
        .frame(height: 50)
        .cornerRadius(BaziTheme.Radius.sm)
        .accessibilityLabel("使用 Apple 登录")
    }
}

/// Sign in with Google 按钮 包装(2026-08-16,对齐 AppleSignInButton 模式)。
///
/// Google 品牌规范:必须用官方 GoogleSignInButton(白底 + 彩色 G + 官方文案),
/// 不可自定义配色/文案 — 与 Apple HIG 对 SignInWithAppleButton 的约束同理。
///
/// **解耦设计**:按钮只触发 action 回调,由调用方驱动 AccountManager.handleGoogleSignIn。
/// GoogleService-Info.plist 未配置时按钮照常渲染,点击后 AccountManager 显式显错。
struct GoogleSignInButton: View {
    /// 点击回调(触发 AccountManager.handleGoogleSignIn)。
    let action: () -> Void

    var body: some View {
        GoogleSignInSwift.GoogleSignInButton(action: action)
            // 与 AppleSignInButton 同高,登录区两个按钮并列(布局不跳)
            .frame(height: 50)
            .cornerRadius(BaziTheme.Radius.sm)
            .accessibilityLabel("使用 Google 登录")
    }
}
