import Foundation

/// Google 登录运行时配置(2026-08-16 Google 登录 slice)。
///
/// **配置文件不进仓库**:GoogleService-Info.plist 由 Google Cloud Console 的
/// iOS 型 OAuth client 生成(含 CLIENT_ID),就位前 Google 按钮渲染但点击显式
/// 报"未配置"(错误显式传播,不静默不崩);就位后零代码改动生效。
///
/// 为什么运行时读 plist 而非编译期常量:同一份代码要兼容"配置未就位"的
/// 开发构建与"配置就位"的发布构建,运行时检测让 plist 成唯一差异物。
enum GoogleSignInConfig {

    /// Google OAuth client ID(xxx.apps.googleusercontent.com)。
    /// Bundle 主资源里没有 GoogleService-Info.plist 或缺 CLIENT_ID → nil(未配置)。
    static var clientID: String? {
        guard
            let path = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
            let dict = NSDictionary(contentsOfFile: path),
            let clientID = dict["CLIENT_ID"] as? String,
            !clientID.isEmpty
        else {
            return nil
        }
        return clientID
    }

    /// Google 登录是否可用(配置就位)。
    static var isConfigured: Bool {
        clientID != nil
    }
}
