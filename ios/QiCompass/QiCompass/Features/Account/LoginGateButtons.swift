import SwiftUI

/// 登录按钮对(SIWA + Google)+ 可选失败显错 —— 全 App 登录入口的唯一实现。
///
/// 收敛背景(2026-09-06):登录动作接线此前在 ProfileView 引导盒与
/// PaywallView signInPrompt 两处重复(login-paywall approved.json 不变量 3)。
/// 语境差异(我的 = 跨设备同步 / 付费墙 = 保存购买凭证)由调用方的
/// 标题/副题承载,本组件只管凭据动作与显错,不持有任何文案观点。
///
/// 显错语义(Fix#1):登录失败不吞,nil = 不渲染错误行。
/// 错误色按调用方既有语境注入:ProfileView 用 destructive,
/// PaywallView 用 shenshaInauspicious(与其 sheet 内购买失败文案同色)。
struct LoginGateButtons: View {
    @EnvironmentObject private var env: AppEnvironment

    /// 登录失败文案(不吞;nil = 无失败,不渲染)。
    /// 统一规格:居中整行 + 10.5 caption(付费墙购买失败 errorCaption 同款;
    /// ProfileView 引导盒原为左对齐/12 间距,共享化后随本组件统一)。
    var errorMessage: String? = nil
    /// 失败文案颜色(见类型注释,两个调用方语境不同)。
    var errorColor: Color = BaziTheme.destructive

    var body: some View {
        VStack(spacing: BaziTheme.Spacing.sm) {
            if let errorMessage {
                Text(errorMessage)
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(errorColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            AppleSignInButton { result in
                env.accountManager.handleAuthorization(result)
            }
            GoogleSignInButton {
                env.accountManager.handleGoogleSignIn()
            }
        }
    }
}
