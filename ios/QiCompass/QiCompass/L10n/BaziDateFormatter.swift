import Foundation

/// 八字 App 日期格式化策略(i18n 决策 7,`i18n-implementation-plan.md` § 2;
/// 农历条目 2026-09-27 由展示层语言交接 §3 术语显示矩阵取代旧口径)。
///
/// 产品决策(§3 农历行;今日页定稿 2026-10-01 D4 修订 EN 腿):
/// - **zh / zh-hant:农历为主** — 农历是术语,保持 lunar_python 原文
///   ("正月初一" / "七月初十"),不转写。
/// - **en:公历为主要信息行、农历降为次要行** — 公历大字/周几走本 enum 的
///   locale formatter;农历以 11pt muted 小字呈现,并转写为
///   "Eighth lunar month, day 11 · Wu-Shen day"(实现见 DailyHeaderSection
///   .enLunarLine;2026-10-01 D4 起 EN 基座层零汉字,日柱拼音化走
///   BaziTerms.romanizedHyphen——取代 09-24 的 "5th Moon · 28th · Day of 辛丑"
///   半中半英形态)。保留中文正确,但不能是唯一日期信息——本条即 U4 的落地口径。
/// - **流日柱(干支)**:命盘页等仍汉字为主(§3 干支条);今日页 EN 基座层
///   例外走无调拼音(见上),hero 落款竖排汉字属艺术层不受限。
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

    /// 星期全名(今日页定稿 2026-10-01 D3 头部区第一行,头部 meta 现在出图
    /// 上纸面、星期升为主信息行):zh → "星期四";en → "Thursday"。
    static let weekdayFull: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "EEEE"
        return f
    }()

    /// 月年(今日页定稿 2026-10-01 D3 头部区第二行):zh → "2026年10月";
    /// en → "October 2026"。template 让系统按 locale 排字段顺序。
    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = DateFormatter.dateFormat(
            fromTemplate: "yyyyMMMM",
            options: 0,
            locale: Locale.current
        )
        return f
    }()
}
