import Foundation

/// 每日阅读次数计数器(UserDefaults,午夜按日期 key 自然重置)。
///
/// **全局池口径**(方案 §D1 / step 1):
/// 三模块(深度解析 / 合盘 / 每日运势)共享每日 10 次额度,每次扣 1。
/// 文档"10 次"是顶部总括,各模块"1 / 3 / 1 次"是"每次扣 1 次"细则;
/// 多命盘(5 命盘 × 3 模块 = 15 次)才会真正触及守护。
///
/// Key 设计(本地时区,跟随系统):
/// - 全局:`daily_read_count_{yyyy-MM-dd}`
/// - 模块(分析埋点):`{module}_read_count_{yyyy-MM-dd}`
///
/// 日期 key 由 `Calendar.autoupdatingCurrent` 实时计算,避免用户切时区后静态 formatter 失真。
///
/// 策略(方案 §4.6 + §D1 扣次数顺序):
/// - 进入命盘 success 态不消耗
/// - 先查本地缓存(命中不扣)→ 未命中 `tryConsume` 全局池 → 后端 `cached=true` 或流程最终未给用户展示成功结果则 `refund`
/// - AI 失败 → refund(重试不消耗)
/// - 达上限 → 弹"今日机缘已尽,明日再来" + 倒计时到午夜
///
/// @unchecked Sendable:UserDefaults 单次读写线程安全;读-改-写(tryConsume/refund)
/// 通过内部 `NSLock` 串行化保证原子,无其他共享可变状态。
final class DailyReadCounter: @unchecked Sendable {
    private let defaults: UserDefaults
    /// 保护 tryConsume / refund 的读-改-写原子性。
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 限额

    /// 每日全局共享池上限。
    enum ReadLimit {
        static let globalDaily = 10
    }

    // MARK: - 消耗 / 退款

    /// 尝试消耗 1 次。全局池余量 ≥1 时扣 1 返回 true;达上限返回 false(不修改存储)。
    /// 同时记录模块维度消耗(埋点用,不影响限流)。
    ///
    /// 读-改-写在 `lock` 内串行化,避免并发调用各读一份、只增 1(漏计)。
    @discardableResult
    func tryConsume(module: String, date: Date = .now) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let gKey = globalKey(date: date)
        let gConsumed = defaults.integer(forKey: gKey)
        guard gConsumed < ReadLimit.globalDaily else { return false }
        defaults.set(gConsumed + 1, forKey: gKey)

        // 模块埋点(失败不影响限流)
        let mKey = moduleKey(module: module, date: date)
        let mConsumed = defaults.integer(forKey: mKey)
        defaults.set(mConsumed + 1, forKey: mKey)
        return true
    }

    /// 退款 1 次(命中后端缓存 / AI 失败时调用)。全局池与模块埋点同步回退,不低于 0。
    /// 同样在 `lock` 内串行化,与 tryConsume 互斥。
    func refund(module: String, date: Date = .now) {
        lock.lock()
        defer { lock.unlock() }
        let gKey = globalKey(date: date)
        let gConsumed = defaults.integer(forKey: gKey)
        if gConsumed > 0 {
            defaults.set(gConsumed - 1, forKey: gKey)
        }
        let mKey = moduleKey(module: module, date: date)
        let mConsumed = defaults.integer(forKey: mKey)
        if mConsumed > 0 {
            defaults.set(mConsumed - 1, forKey: mKey)
        }
    }

    // MARK: - 查询

    /// 全局剩余次数(VM / UI 展示用)。= `ReadLimit.globalDaily - 全局已消耗`,下界 0。
    func remaining(date: Date = .now) -> Int {
        let consumed = defaults.integer(forKey: globalKey(date: date))
        return max(0, ReadLimit.globalDaily - consumed)
    }

    /// 模块维度已消耗次数(分析埋点用,不影响限流)。
    func moduleConsumed(_ module: String, date: Date = .now) -> Int {
        defaults.integer(forKey: moduleKey(module: module, date: date))
    }

    /// 下次重置时间(本地午夜,用于倒计时展示)。
    func nextResetDate(date: Date = .now) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        guard let startOfTomorrow = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: date)
        ) else {
            return date
        }
        return startOfTomorrow
    }

    // MARK: - Private (key 生成)

    /// 全局池 key:`daily_read_count_{yyyy-MM-dd}`。
    private func globalKey(date: Date) -> String {
        "daily_read_count_\(dayKey(date: date))"
    }

    /// 模块埋点 key:`{module}_read_count_{yyyy-MM-dd}`。
    private func moduleKey(module: String, date: Date) -> String {
        "\(module)_read_count_\(dayKey(date: date))"
    }

    /// 用 `Calendar.autoupdatingCurrent` 算本地日期,拼 `yyyy-MM-dd`。
    /// 不用静态 DateFormatter,避免用户切时区后 key 失真。
    /// components 缺失属 Calendar 不变量违反（理论不会发生），
    /// 显式断言而非静默用 0 填充（避免 "0000-00-00" key 污染计数）。
    private func dayKey(date: Date) -> String {
        let cal = Calendar.autoupdatingCurrent
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        guard let year = comps.year,
              let month = comps.month,
              let day = comps.day else {
            assertionFailure("Calendar.dateComponents 缺失组件: \(comps) date=\(date)")
            // 断言失败时仍返回确定性 key（用 epoch 日），不污染正常日期 key 空间
            let epochDay = Int(date.timeIntervalSince1970 / 86400)
            return "epoch_\(epochDay)"
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
