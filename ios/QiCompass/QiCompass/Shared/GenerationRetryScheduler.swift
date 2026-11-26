import Foundation

/// 503/429 生成类请求的长周期自动重试调度(2026-11-26 用户拍板)。
///
/// 拍板形态:**前台定时 + 冷启补试**——iOS 后台执行不可靠(与 Background
/// Tasks 预生成被砍是同一结论),65 分钟间隔只在 App 活着时保证;冷启/回前台
/// 时检查「已过 65 分钟」则立即补试。不依赖任何后台任务。
///
/// 分工:本类型只回答「**何时**该重试」,不关心「**怎么**重试」——各
/// ViewModel 订阅 `dueNotification` 后走自己的既有 retry 链(请求参数与 UI
/// 状态都在 ViewModel 手里,调度器不复制业务入参,避免第二份参数源漂移)。
///
/// 间隔 65 分钟(3900s)而非整 1 小时:错开整点对齐——服务端监控/配额均按
/// 小时分桶,全体客户端整点重试会形成同步脉冲;+5 分钟把重试摊进桶内。
///
/// 触达面(架构边界):`fireDue` 只通知**当时活着**的订阅者——冷启立即检查
/// 早于非选中 tab 的 VM 懒加载,该类条目被消费但无人接收。实际无害:三管线
/// VM(Deep/Daily/Compat)冷启由 onAppear 管线续跑等效恢复,Ask 的重发档案
/// 本就会话作用域。新增 Kind 时不得依赖「冷启补试必达」语义。
///
/// 生命周期语义:
/// - 失败(503/429)→ `schedule(kind:)` 登记,65 分钟后到期
/// - 到期 → 发一次 `dueNotification`(userInfo 带 kind),条目即消费删除
///   (单发;VM 重试若再失败会重新 schedule 顺延——不会连环轰炸)
/// - 成功 → `clear(kind:)`(残留条目只会在到期时空发一次通知,VM 侧
///   「非失败态则忽略」兜底)
final class GenerationRetryScheduler {

    static let shared = GenerationRetryScheduler()

    /// 参与自动重试的生成类请求(redeem/登录等交易语义请求不在此列,
    /// 2026-11-26 拍板:它们失败应由人工路径重试)。
    enum Kind: String, CaseIterable {
        case dailyFortune
        case deepModule
        case deepTranslation
        case compatibility
        case askAnswer
    }

    static let retryInterval: TimeInterval = 65 * 60
    static let deadlinesKey = "generationRetryScheduler.deadlines"
    static let dueNotification = Notification.Name("generationRetryScheduler.due")
    static let kindUserInfoKey = "kind"

    private let defaults: UserDefaults
    private var heartbeat: Timer?
    private let lock = NSLock()

    /// 测试注入 defaults;生产走 .shared 的 .standard。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 失败登记 / 成功清除

    /// 失败(503/429)时登记:65 分钟后到期(测试可注入短间隔)。
    func schedule(_ kind: Kind, retryAfter: TimeInterval = GenerationRetryScheduler.retryInterval) {
        let due = Date().addingTimeInterval(retryAfter)
        lock.lock()
        defer { lock.unlock() }
        var table = loadTable()
        table[kind.rawValue] = due
        saveTable(table)
    }

    /// 成功(或不再需要重试)时清除条目。
    func clear(_ kind: Kind) {
        lock.lock()
        defer { lock.unlock() }
        var table = loadTable()
        guard table.removeValue(forKey: kind.rawValue) != nil else { return }
        saveTable(table)
    }

    /// 该 kind 下次重试时间(测试/调试用;nil = 无待重试)。
    func nextRetryAt(_ kind: Kind) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return loadTable()[kind.rawValue]
    }

    // MARK: - 心跳与补试

    /// App 激活时调用一次:起 60s 心跳并立即检查一轮(冷启补试入口)。
    /// Timer 挂主 RunLoop——与 UI 同线程,VM 收通知无跨线程跳跃。
    func startHeartbeat() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.heartbeat == nil else { return }
            self.heartbeat = Timer.scheduledTimer(
                withTimeInterval: 60, repeats: true,
            ) { [weak self] _ in
                self?.fireDue()
            }
            self.fireDue()
        }
    }

    /// 检查到期条目并发通知(心跳 tick / 回前台 / 冷启共用)。
    /// 返回本轮触发的 kinds(测试用)。
    @discardableResult
    func fireDue(now: Date = Date()) -> [Kind] {
        lock.lock()
        var table = loadTable()
        let dueRaw = table.filter { $0.value <= now }
        guard !dueRaw.isEmpty else {
            lock.unlock()
            return []
        }
        for (raw, _) in dueRaw { table.removeValue(forKey: raw) }
        saveTable(table)
        lock.unlock()

        let kinds = dueRaw.keys.compactMap { Kind(rawValue: $0) }
        // 通知统一主线程发(心跳天然主线程;冷启入口可能来自任意线程)
        if Thread.isMainThread {
            post(kinds)
        } else {
            DispatchQueue.main.async { self.post(kinds) }
        }
        return kinds
    }

    private func post(_ kinds: [Kind]) {
        for kind in kinds {
            NotificationCenter.default.post(
                name: Self.dueNotification, object: nil,
                userInfo: [Self.kindUserInfoKey: kind.rawValue],
            )
        }
    }

    // MARK: - 订阅助手

    /// 订阅某 kind 的到期通知(2026-11-26 收编:DailyFortune / DeepAnalysis /
    /// Compatibility 三 VM 与 DailyAskModel 四处注册块同构——kind 过滤与
    /// MainActor 跳转语义抽成单一事实源,防四处漂移)。
    ///
    /// 语义与原四处内联块逐字等价:`queue: .main` 收通知 → 按 userInfo
    /// kind rawValue 过滤异 kind → `Task { @MainActor }` 跳主隔离再调
    /// handler(不直调:notification block 不在 MainActor isolation 内,
    /// 直接同步调 @MainActor 方法过不了并发检查)。
    ///
    /// **只造不收**:返回的 token 由调用方持有、deinit 里 `removeObserver`
    /// ——生命周期归 VM(调度器是全局单例,代管移除会让 VM 生命期与单例
    /// 耦合;token 属性上的 `nonisolated(unsafe)` 纪律见各 VM 声明处)。
    static func observeDue(
        _ kind: Kind,
        handler: @escaping @MainActor () -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: dueNotification, object: nil, queue: .main
        ) { note in
            let raw = note.userInfo?[kindUserInfoKey] as? String
            guard raw == kind.rawValue else { return }
            Task { @MainActor in
                handler()
            }
        }
    }

    // MARK: - 持久化([String: Date],plist 原生支持 Date)

    private func loadTable() -> [String: Date] {
        (defaults.dictionary(forKey: Self.deadlinesKey) as? [String: Date]) ?? [:]
    }

    private func saveTable(_ table: [String: Date]) {
        defaults.set(table, forKey: Self.deadlinesKey)
    }
}
