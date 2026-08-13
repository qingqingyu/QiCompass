import Foundation

/// 类型安全的本地化 key 引用(i18n 决策 6,`i18n-implementation-plan.md` § 2)。
///
/// 替代 SwiftUI 的 `Text("硬编码中文")` 反模式:
/// - 显式语义,避免 LocalizedStringKey 类型推断歧义(`Text("硬编码")` 会被当 key 还是字面量,
///   SwiftUI 行为不一致,常导致翻译不生效)
/// - 类型安全,编译期检查 key 拼写
/// - IDE 自动补全(`L10n.DailyFortune.` → 显示所有 daily fortune key)
///
/// key 命名规则(对齐 i18n 决策 5):
/// `{module}.{scope}.{name}`(点分隔,语义清晰)
///
/// Slice 1 范围:DailyFortune 模块全量 + 共享组件(CountdownResetLabel / DailyLimitReachedView)。
///
/// 使用:
/// ```swift
/// Text(L10n.DailyFortune.dayPillarLabel)                    // 替代 Text("流日柱")
/// Text(L10n.DailyFortune.interpretRemaining(3))             // 替代 Text("剩余 \(n) 次")
/// Text(L10n.DailyFortune.chongLabel(chong: "午", targets: []))  // 替代 Text("冲午")
/// ```
enum L10n {
    // MARK: - 每日运势模块

    /// 每日运势模块。
    enum DailyFortune {
        // -- Header --

        /// "农历" 前缀(用于 "农历 七月初十" 这种拼接)。
        /// zh: "农历";en: "Lunar"
        static let lunarPrefix = String(localized: "dailyfortune.header.lunarPrefix")

        /// "流日柱" 标签(大字头上方的小字)。
        /// zh: "流日柱";en: "Day Pillar"
        static let dayPillarLabel = String(localized: "dailyfortune.header.dayPillarLabel")

        /// "冲" 前缀(用于 "冲午" / "冲午 (年支午)" 这种拼接)。
        /// zh: "冲";en: "Clashes: "
        static let chongPrefix = String(localized: "dailyfortune.header.chongPrefix")

        /// 构造"冲"标签(本地化 prefix + chong 字符 + 可选 targets 列表)。
        ///
        /// 中文: "冲午" / "冲午 (年支午)"
        /// 英文: "Clashes: 午" / "Clashes: 午 (Year Branch 午)"
        ///
        /// - Parameters:
        ///   - chong: 冲到的地支字(如 "午"),来自 backend day_chong 字段
        ///   - targets: 被冲到的四柱位置描述列表(如 ["年支午"]),空列表则不加 targets
        /// - Returns: 完整本地化字符串
        static func chongLabel(chong: String, targets: [String]) -> String {
            let isEnglish = AppLanguage.current == "en"
            let separator = isEnglish ? ", " : "、"
            let targetsStr = targets.isEmpty ? "" : " (\(targets.joined(separator: separator)))"
            return "\(chongPrefix)\(chong)\(targetsStr)"
        }

        // -- Empty View --

        /// 空态标题(zh="今日流日运势", en="Today's Daily Fortune")
        static let emptyTitle = String(localized: "dailyfortune.empty.title")

        /// 空态副标题 1(zh="需先完成深度解析,基于命盘推演流日。")
        static let emptySubtitle1 = String(localized: "dailyfortune.empty.subtitle1")

        /// 空态副标题 2(zh="完成深度解析后,本页将自动生成每日运势。")
        static let emptySubtitle2 = String(localized: "dailyfortune.empty.subtitle2")

        // -- Interpretation Section --

        /// 解读区标题 + CTA 按钮标题(zh="今日解读", en="Today's Reading")
        static let interpretTitle = String(localized: "dailyfortune.interpret.title")

        /// 剩余次数(zh="剩余 N 次", en="N reads left")
        static func interpretRemaining(_ count: Int) -> String {
            String(format: String(localized: "dailyfortune.interpret.remaining"), count)
        }

        /// 缓存标识(zh="24h 内已缓存,不消耗次数")
        static let interpretCached = String(localized: "dailyfortune.interpret.cached")

        /// 重试按钮(zh="重试", en="Retry")
        static let interpretRetry = String(localized: "dailyfortune.interpret.retry")

        /// CTA 说明文字(zh="点击生成今日流日解读(约 50-80 字)")
        static let interpretCTA = String(localized: "dailyfortune.interpret.cta")

        /// 加载中文字(zh="推演中…", en="Divining…")
        static let interpretLoading = String(localized: "dailyfortune.interpret.loading")

        // -- Hour Pillars Section --

        /// 12 时辰标题(zh="12 时辰", en="12 Hourly Pillars")
        static let hourTitle = String(localized: "dailyfortune.hour.title")

        /// 折叠提示(zh="展开查看 12 时辰详情")
        static let hourExpandHint = String(localized: "dailyfortune.hour.expandHint")

        /// 当前时辰标识(zh="当下", en="Now")
        static let hourNow = String(localized: "dailyfortune.hour.now")

        // -- Tomorrow Preview --

        /// 明日预告标题(zh="明日预告", en="Tomorrow's Preview")
        static let tomorrowTitle = String(localized: "dailyfortune.tomorrow.title")

        // -- 宜/忌 标签(Huangli + YiJi 共用)--

        /// 宜(zh="宜", en="Auspicious")
        static let yiLabel = String(localized: "dailyfortune.label.yi")

        /// 忌(zh="忌", en="Inauspicious")
        static let jiLabel = String(localized: "dailyfortune.label.ji")

        // -- Main View --

        /// 离线标识(zh="离线查看(展示本地缓存,不扣次数)")
        static let mainOffline = String(localized: "dailyfortune.main.offline")

        /// 历史加载失败(zh="历史加载失败", en="Failed to load history")
        static let mainHistoryError = String(localized: "dailyfortune.main.historyError")
    }

    // MARK: - 共享组件

    /// 共享文案(跨模块复用:CountdownResetLabel / DailyLimitReachedView)。
    enum Common {
        /// 达上限提示(zh="今日机缘已尽,明日再来")
        static let limitReached = String(localized: "common.limitReached")

        /// 倒计时完整标签(zh="距重置:3 时 15 分", en="Resets in 3h 15m")
        static func countdownLabel(hours: Int, minutes: Int) -> String {
            let timeStr = String(
                format: String(localized: "common.countdown.timeFormat"), hours, minutes
            )
            return String(format: String(localized: "common.countdown"), timeStr)
        }
    }
}
