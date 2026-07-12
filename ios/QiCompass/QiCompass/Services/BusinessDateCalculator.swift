import Foundation

/// 业务日期计算器(pure function,易测试)。
///
/// 子时规则(决策 §3.6):
/// - `zi_next_day`:若 now >= 当日 23:00 → 返回次日(23:00 换日)
/// - `zero_oclock`:直接返回当日(00:00 换日)
///
/// 此值作为 `target_date` 发给后端,也作为 SwiftData 查询键。
/// 服务端不感知 zi 规则,纯函数。
enum BusinessDateCalculator {

    /// 计算业务日期。返回的 Date 仅含「年月日」语义(已截到本地午夜)。
    static func businessDate(now: Date = .now,
                              ziHourRule: String,
                              calendar: Calendar = .current) -> Date {
        // 先把 now 截到本地午夜(去掉时分秒)
        let today = calendar.startOfDay(for: now)

        switch ziHourRule {
        case "zi_next_day":
            // 23:00 后 → 次日(早子时归次日)
            // 取当日 23:00,若 now >= 23:00 则 +1 day
            if let threshold = calendar.date(
                bySettingHour: 23, minute: 0, second: 0,
                of: today
            ), now >= threshold {
                return calendar.date(byAdding: .day, value: 1, to: today) ?? today
            }
            return today
        case "zero_oclock":
            // 00:00 换日,直接返回截断到午夜的 today
            return today
        default:
            // 未知规则不静默兜底:按 zi_next_day 处理(产品默认),
            // 调用方应保证 ziHourRule 来自存档合法值
            return businessDate(now: now, ziHourRule: "zi_next_day", calendar: calendar)
        }
    }

    /// 给定 businessDate,返回该日本地 23:59:59 + 1s(=次日 00:00)作为 cachedUntil。
    /// 用于 DailyFortuneSnapshot 的日粒度缓存判据(决策 §1.B)。
    static func cachedUntil(forBusinessDate businessDate: Date,
                             calendar: Calendar = .current) -> Date {
        let endOfDay = calendar.date(
            bySettingHour: 23, minute: 59, second: 59,
            of: businessDate
        ) ?? businessDate
        return endOfDay.addingTimeInterval(1)
    }

    /// 当前时辰索引(0=子...11=亥),用于高亮 12 时辰条。
    /// 仅今日(today)显示;历史回看由调用方决定是否高亮(决策 §1.E)。
    static func currentHourIndex(now: Date = .now,
                                  ziHourRule: String,
                                  calendar: Calendar = .current) -> Int? {
        // 子时规则:zi_next_day 下,23:00 后属次日早子时 → hour=0
        // zero_oclock 下,23:00-23:59 仍是当日「亥」时(11),00:00 后才是子(0)
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)

        // 把时间归一化为「时辰序号」(0=子,1=丑,...,11=亥)
        // 23:00-00:59(跨日)→ 子(0)
        // 01:00-02:59 → 丑(1)
        // ...
        // 21:00-22:59 → 亥(11)
        // 简化:hour ∈ [23, 24) 或 [0, 1) → 子;其余(hour-1)/2 取整
        let isLateZi = hour == 23  // 23:00-23:59(晚子时)
        let isEarlyZi = hour == 0 && minute < 60  // 00:00-00:59(早子时)
        // 上面的 minute < 60 恒真,只为可读性

        switch ziHourRule {
        case "zi_next_day":
            // 23:00 后视为次日早子时,索引 0
            if isLateZi { return 0 }
            if isEarlyZi { return 0 }
            // 其余按时辰序号映射
            return shichenIndex(hour: hour)
        case "zero_oclock":
            // 00:00 换日:23:00-23:59 仍是当日亥时(11)
            if isLateZi { return 11 }
            if isEarlyZi { return 0 }
            return shichenIndex(hour: hour)
        default:
            return currentHourIndex(now: now, ziHourRule: "zi_next_day", calendar: calendar)
        }
    }

    /// hour(0-22)→ 时辰索引(0=子,1=丑,...,11=亥)。
    /// 00:00-00:59 已在外层处理为 0;此处只处理 01:00-22:59。
    private static func shichenIndex(hour: Int) -> Int {
        // 1-2 → 1(丑),3-4 → 2(寅),...,21-22 → 11(亥)
        return max(0, min(11, (hour - 1) / 2))
    }
}
