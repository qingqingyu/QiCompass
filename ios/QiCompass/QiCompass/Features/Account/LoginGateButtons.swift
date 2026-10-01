import SwiftUI

/// 登录按钮(SIWA)+ 可选失败显错 —— 全 App 登录入口的唯一实现。
///
/// 收敛背景(2026-09-06):登录动作接线此前在 ProfileView 引导盒与
/// PaywallView 两处重复(login-paywall approved.json 不变量 3)。
/// 语境差异(我的 = 跨设备同步 / 付费墙 = 绑定凭证)由调用方的
/// 标题/副题承载,本组件只管凭据动作与显错,不持有任何文案观点。
///
/// 2026-09-27 移除 Google 按钮(用户拍板,全 App 只留 SIWA):官方 SDK
/// 品牌规范锁死亮蓝配色与水墨视觉冲突,且国内用户基本不可用;海外
/// Apple 用户 SIWA 同样可用。AccountManager.handleGoogleSignIn 与后端
/// Google exchange 保留(休眠态,日后重启无成本)。
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
    /// Apple 按钮高度(默认 50 与付费墙一致;ProfileView 登录盒传 44 降权,
    /// 2026-10-01 Me 页 F2——共用组件默认值不动,调用方按语境注入)。
    var buttonHeight: CGFloat = 50

    var body: some View {
        VStack(spacing: BaziTheme.Spacing.sm) {
            if let errorMessage {
                Text(errorMessage)
                    .font(BaziFont.caption(size: 10.5))
                    .foregroundStyle(errorColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            AppleSignInButton(height: buttonHeight) { result in
                env.accountManager.handleAuthorization(result)
            }
        }
    }
}
