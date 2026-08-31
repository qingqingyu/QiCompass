import Foundation

/// 八字 App 日期格式化策略(i18n 决策 7,`i18n-implementation-plan.md` § 2)。
///
/// 产品决策:
/// - **农历永远 zh_CN** — 农历是术语,英文用户看到 "正月" 比看到 "Lunar January"
///   更能感知到这是 Chinese Astrology,符合"专业不忽悠" Memorable Thing(DESIGN.md)。
///   且 lunar_python 输出的农历格式("正月初一" / "七月初十")翻译成英文会很生硬。
/// - **公历按 user locale** — 本地化日期格式("2026年8月12日" vs "August 12, 2026")。
/// - **流日柱(干支)永远中文** — "甲子" 不翻译,英文用户看到 "Jia Zi" 也是术语。
///   (注:流日柱本身的术语翻译由 backend 在 context 里完成,
///    iOS 只展示 backend 返回的字符串。)
///
/// 使用 `DateFormatter.dateFormat(fromTemplate:options:locale:)` 让 Apple 系统
/// 按 locale 自动调整字段顺序(避免硬编码 "yyyy-MM-dd" 在英文 locale 显示乱)。
enum BaziDateFormatter {
    /// 农历显示:永远 zh_CN(术语,不翻译)。
    /// 输入:lunar_python 输出的农历字符串(如 "正月初一")。
    /// 由于该字符串已是中文,此 formatter 实际只用于"农历"前缀 label 的本地化,
    /// 不直接格式化 Date 对象。保留此处作为文档化决策。
    static let lunar: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    /// 公历显示:按 user locale,dateStyle = .long(完整格式,含星期由 template 决定)。
    /// zh → "2026年8月12日";en → "August 12, 2026"。
    static let gregorianLong: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    /// 公历显示 + 星期:按 user locale,使用 template 让系统决定字段顺序。
    /// zh → "2026年8月12日 星期三";en → "Wednesday, August 12, 2026"。
    static let gregorianWithWeekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        // dateFormat(fromTemplate:options:locale:) 会按 locale 调整字段顺序
        // 例:zh 显示 "yyyy年M月d日 EEEE";en 显示 "EEEE, MMMM d, yyyy"
        f.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "yyyyMMMMdEEEE",
            options: 0,
            locale: Locale.current
        )
        return f
    }()

    /// 公历短日期(无年份无星期,今日运势 V1 头部大字):zh → "8月30日";en → "August 30"。
    static let gregorianShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "MMMMdd",
            options: 0,
            locale: Locale.current
        )
        return f
    }()

    /// 星期短格式(今日运势 V1 头部次级层级,与历史 pill 同款式式):zh → "周日";en → "Sun"。
    static let weekdayShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "E"
        return f
    }()
}
