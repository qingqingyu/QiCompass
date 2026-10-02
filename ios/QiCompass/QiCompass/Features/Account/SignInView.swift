import SwiftUI
import AuthenticationServices

/// Sign in with Apple 按钮 包装(v2 PR2;2026-09-25 暗色走查修复:随系统外观切换样式)。
///
/// Apple HIG 要求 SignInWithAppleButton 不可改颜色,只可选 4 种系统样式
/// (.black/.white/.whiteOutline)。Light 选 `.black` 黑底白字与浓墨 CTA 同源;
/// **Dark 下 `.black` 黑底压夜宣纸近隐身**——切 `.white` 白底,恰好与暗色下
/// 反转为米白底的 inkDeep CTA 同源(官方样式二选一,.white 即品牌语义)。
///
/// **解耦设计**:按钮不持有 AccountManager,通过 onResult 回调把 Apple 返回的
/// Result<ASAuthorization, Error> 抛给调用方(ProfileView 处理)。
/// 这样本组件无业务依赖,可在任何地方复用。
struct AppleSignInButton: View {
    /// 登录结果回调(成功 ASAuthorization / 失败 Error)。
    let onResult: (Result<ASAuthorization, Error>) -> Void
    /// 按钮高度(默认 50)。Profile 登录盒传 44 标准高度降权(2026-10-01 Me 页 F2:
    /// 全页最重元素是区块标题不是登录按钮);付费墙维持 50 不动。
    /// SIWA 标签字号/外观由系统锁定不可调(HIG 官方样式),44pt 即标准尺寸。
    var height: CGFloat = 50

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            // 请求 fullName + email(仅首次登录 Apple 返回,之后 nil)
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            onResult(result)
        }
        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
        .frame(height: height)
        .cornerRadius(BaziTheme.Radius.sm)
        .accessibilityLabel("使用 Apple 登录")
    }
}

// 2026-09-27 移除 GoogleSignInButton(用户拍板,全 App 只留 SIWA):
// 官方 SDK 品牌规范锁死亮蓝配色,与水墨视觉冲突且国内用户基本不可用。
// AccountManager.handleGoogleSignIn 与后端 Google exchange 保留(休眠态),
// 日后重启 UI 时对齐 AppleSignInButton 模式重写即可。
