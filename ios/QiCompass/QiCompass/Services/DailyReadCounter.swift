import Foundation

/// 每日阅读次数计数器(UserDefaults,午夜按日期 key 自然重置)。
///
/// key 格式:`{module}_read_count_{yyyy-MM-dd}`,每天新 key 自动从 0 开始。
/// 策略(方案 §4.6):
/// - 进入命盘 success 态不消耗
/// - 用户点"生成命书" → tryConsume,余量 ≥1 才调 /api/interpret
/// - 后端返回 cached=True → refund(命中缓存不消耗)
/// - AI 失败 → refund(重试不消耗)
/// - 达上限 → 弹"今日机缘已尽,明日再来" + 倒计时到午夜
///
/// @unchecked Sendable:UserDefaults 本身线程安全,无共享可变状态。
final class DailyReadCounter: @unchecked Sendable {
    private let defaults: UserDefaults

    /// 缓存 DateFormatter(初始化开销大,避免每次 key(for:) 都创建)
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for module: String, date: Date = .now) -> String {
        "\(module)_read_count_\(Self.dayFormatter.string(from: date))"
    }

    /// 剩余次数(= limit - 已消耗,下界 0)。
    func remaining(module: String, limit: Int) -> Int {
        let consumed = defaults.integer(forKey: key(for: module))
        return max(0, limit - consumed)
    }

    /// 尝试消耗 1 次。余量 ≥1 时扣 1 返回 true;达上限返回 false(不修改存储)。
    @discardableResult
    func tryConsume(module: String, limit: Int) -> Bool {
        let k = key(for: module)
        let consumed = defaults.integer(forKey: k)
        guard consumed < limit else { return false }
        defaults.set(consumed + 1, forKey: k)
        return true
    }

    /// 退款 1 次(命中后端缓存 / AI 失败时调用)。不低于 0。
    func refund(module: String) {
        let k = key(for: module)
        let consumed = defaults.integer(forKey: k)
        guard consumed > 0 else { return }
        defaults.set(consumed - 1, forKey: k)
    }

    /// 下次重置时间(本地午夜,用于倒计时展示)。
    func nextResetDate() -> Date {
        let calendar = Calendar.current
        let now = Date()
        guard let startOfTomorrow = calendar.date(
            byAdding: .day, value: 1, to: calendar.startOfDay(for: now)
        ) else {
            return now
        }
        return startOfTomorrow
    }
}
