import Foundation
import UIKit
import UserNotifications

/// 命书整链完成通知(方案二,2026-10-11 拍板:只发整链完成一条):
/// - **后台**:UNUserNotificationCenter 本地通知一条(未授权 → 不投递,留日志)
/// - **前台**:不弹系统横幅(willPresent 返回空),改 post 内部完成广播,
///   由 RootTabView 挂的 `ChainDoneToast` 呈现水墨 toast
/// - **点通知**:跳深度解析 tab(复用既有 `.switchTab` 机制,不新造导航通道)
///
/// 诚实边界(链在 App 内跑,退后台 ~30s 后被挂起):通知只在「离开后短时间内
/// 整链恰好完成」时送达;链被挂起则无通知,回 App 靠断点续跑接管——通知文案
/// 不写死时间,不过度承诺。
/// @MainActor:通知投递判定读 UIApplication.shared.applicationState,
/// 且调用方(VM/视图)全在主线程——协议锁定主隔离,测试替身也随协议获得
/// MainActor 隔离(spy 的 completions 写读同线程,消除数据竞争)。
@MainActor
protocol ChainCompletionNotifying: AnyObject {
    /// 上下文式权限请求(第一次点开「生成中」章节时调用一次;状态已定则
    /// 静默返回,不重复打扰——iOS 权限弹窗本身只出一次,这里补的是调用侧幂等)。
    func requestAuthorizationOnce() async
    /// 当前是否已授权(等待卡/横幅的条件文案与投递判定用)。
    func isAuthorized() async -> Bool
    /// 整链完成:按前台/后台与授权状态决定投递渠道。
    func notifyBookComplete(chapterCount: Int, isOwned: Bool) async
}

/// 投递渠道决策(纯函数,测试直接断言矩阵):
/// 未授权 → 一律不投(用户没给许可就不打扰);前台 → in-app toast;
/// 后台/inactive(通知中心下拉等) → 系统本地通知。
enum ChainCompletionDelivery: Equatable {
    case inAppToast
    case systemNotification
    case suppressed

    static func resolve(appState: UIApplication.State?, authorized: Bool) -> ChainCompletionDelivery {
        guard authorized else { return .suppressed }
        guard let appState else { return .inAppToast }
        return appState == .active ? .inAppToast : .systemNotification
    }
}

@MainActor
final class ChainCompletionNotifier: NSObject, ChainCompletionNotifying, UNUserNotificationCenterDelegate {
    static let shared = ChainCompletionNotifier()

    /// 内部完成广播(RootTabView 的 ChainDoneToast 监听;userInfo 携带
    /// chapterCount / isOwned 供 toast 文案)。
    static let completionNotificationName = Notification.Name("com.qicompass.deepChain.completed")
    /// 系统通知 request identifier 前缀(didReceive 按它识别本族通知)。
    static let requestIdentifierPrefix = "com.qicompass.deepChain.complete"

    private override init() {
        super.init()
        // delegate 在实例化时即挂(QiCompassApp.init 触达 shared):冷启动由
        // 通知点入的场景,didReceive 必须在 launch 完成前就绪才不丢——
        // 只靠 requestAuthorizationOnce 挂会漏掉「本次会话没打开过生成中
        // 章节」的授权用户(后台完成点通知不跳 tab)。
        center.delegate = self
    }

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    // MARK: - ChainCompletionNotifying

    func requestAuthorizationOnce() async {
        // delegate 已在 init 挂上(App 启动即触达 shared),此处不再重复
        let status = await settingsStatus()
        guard status == .notDetermined else {
            AppLogger.app.info("chainNotifier.requestAuthorization skip status=\(status.rawValue, privacy: .public) — 已定,不再打扰")
            return
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            AppLogger.app.info("chainNotifier.requestAuthorization granted=\(granted, privacy: .public)")
        } catch {
            // 权限请求失败不吞:留 error 级痕迹,等待卡文案按未授权回落
            AppLogger.app.error("chainNotifier.requestAuthorization failed error=\(String(describing: error), privacy: .public)")
        }
    }

    func isAuthorized() async -> Bool {
        let status = await settingsStatus()
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    func notifyBookComplete(chapterCount: Int, isOwned: Bool) async {
        let authorized = await isAuthorized()
        let delivery = ChainCompletionDelivery.resolve(
            appState: UIApplication.shared.applicationState,
            authorized: authorized
        )
        switch delivery {
        case .suppressed:
            AppLogger.app.info("chainNotifier.notify suppressed authorized=\(authorized, privacy: .public) count=\(chapterCount, privacy: .public) — 未授权不投递(用户可在系统设置开启)")
        case .inAppToast:
            AppLogger.app.info("chainNotifier.notify inAppToast count=\(chapterCount, privacy: .public) isOwned=\(isOwned, privacy: .public)")
            NotificationCenter.default.post(
                name: Self.completionNotificationName,
                object: nil,
                userInfo: ["chapterCount": chapterCount, "isOwned": isOwned]
            )
        case .systemNotification:
            AppLogger.app.info("chainNotifier.notify systemNotification count=\(chapterCount, privacy: .public) isOwned=\(isOwned, privacy: .public)")
            let content = UNMutableNotificationContent()
            content.title = L10n.DeepChain.notifyTitle(isOwned: isOwned)
            content.body = L10n.DeepChain.notifyBody(chapterCount: chapterCount, isOwned: isOwned)
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "\(Self.requestIdentifierPrefix).\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                // 排队失败不吞:留 error 级痕迹(不影响 App 内状态,toast 渠道之外无降级)
                AppLogger.app.error("chainNotifier.notify addRequest failed error=\(String(describing: error), privacy: .public)")
            }
        }
    }

    private func settingsStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 前台到达的系统通知不弹横幅(水墨 toast 已承载,双通道同屏是打扰)。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    /// 点通知 → 深度解析 tab(复用 .switchTab;冷启动/热回都走这一条路)。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // guard 须在 MainActor 域内做:requestIdentifierPrefix 是本类
        // (@MainActor)的隔离 static,nonisolated 上下文直接引用编译不过
        await MainActor.run {
            let identifier = response.notification.request.identifier
            guard identifier.hasPrefix(ChainCompletionNotifier.requestIdentifierPrefix) else { return }
            NotificationCenter.default.post(
                name: .switchTab,
                object: nil,
                userInfo: ["tab": RootTabView.Tab.deepAnalysis.switchKey]
            )
        }
    }
}
