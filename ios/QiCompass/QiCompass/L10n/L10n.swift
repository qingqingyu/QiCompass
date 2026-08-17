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
    // MARK: - Onboarding(2026-08-13 三屏重构新增)

    /// Onboarding 模块。
    enum Onboarding {
        // -- 表单页(第 2 屏)--

        /// 表单页标题。
        /// zh: "你的出生信息";en: "Your birth details"
        static let formTitle = String(localized: "onboarding.form.title")

        /// 隐私微文案(表单页底部,Q1 拆分下沉:隐私信息在用户交出生信息那一刻出现)。
        /// zh: "命盘只存你手机 · 无账号";en: "Your chart stays on your phone · No account"
        static let formPrivacyLine = String(localized: "onboarding.form.privacyLine")

        // -- 生肖反馈屏(第 3 屏)--

        /// 好朋友区块标题(三合六合)。
        /// zh: "好朋友";en: "Natural friends"
        static let revealFriendsTitle = String(localized: "onboarding.reveal.friendsTitle")

        /// 需磨合区块标题(六冲,软化措辞,不用「不和谐/相冲」避免恐吓)。
        /// zh: "需磨合";en: "Needs patience"
        static let revealClashTitle = String(localized: "onboarding.reveal.clashTitle")

        /// 立场微文案(反馈屏底部,Q1 拆分下沉:收到结论那一刻给可信度背书)。
        /// zh: "同一组生辰,同一张盘 · 喜忌由规则判,AI 只润色"
        /// en: "Same birth data, same chart · Rules decide, AI polishes"
        static let revealStanceLine = String(localized: "onboarding.reveal.stanceLine")

        /// 反馈屏 CTA(zh="查看今日运势", en="See today's fortune")
        static let revealCTA = String(localized: "onboarding.reveal.cta")

        // -- 12 生肖人格文案(静态善意正面画像,Q6 锁定:1-2 句,不吹天命不写负面)--

        static let personalityRat = String(localized: "onboarding.personality.rat")
        static let personalityOx = String(localized: "onboarding.personality.ox")
        static let personalityTiger = String(localized: "onboarding.personality.tiger")
        static let personalityRabbit = String(localized: "onboarding.personality.rabbit")
        static let personalityDragon = String(localized: "onboarding.personality.dragon")
        static let personalitySnake = String(localized: "onboarding.personality.snake")
        static let personalityHorse = String(localized: "onboarding.personality.horse")
        static let personalityGoat = String(localized: "onboarding.personality.goat")
        static let personalityMonkey = String(localized: "onboarding.personality.monkey")
        static let personalityRooster = String(localized: "onboarding.personality.rooster")
        static let personalityDog = String(localized: "onboarding.personality.dog")
        static let personalityPig = String(localized: "onboarding.personality.pig")
    }

    // MARK: - 城市搜索模块(S03,全球城市选择)

    /// 城市搜索(出生地选择,sheet 交互;决策 docs/城市搜索设计决策.md Q8)。
    enum CitySearch {
        /// sheet 标题。zh: "出生城市";en: "Birth city"
        static let title = String(localized: "city.search.title")

        /// 搜索框占位。zh: "搜索出生城市";en: "Search birth city"
        static let placeholder = String(localized: "city.search.placeholder")

        /// 取消按钮。zh: "取消";en: "Cancel"
        static let cancel = String(localized: "city.search.cancel")

        /// 最近选择区标题。zh: "最近选择";en: "Recent"
        static let recents = String(localized: "city.search.recents")

        /// 热门城市区标题。zh: "热门城市";en: "Popular"
        static let hot = String(localized: "city.search.hot")

        /// 无结果文案(带查询词)。
        /// zh: "未找到「%@」,试试拼音或英文名";en: "No results for \"%@\" — try pinyin or English"
        static func noResults(_ query: String) -> String {
            String(format: String(localized: "city.search.noResults"), query)
        }

        // -- 自定义地点(S05:经度 + IANA 时区必填)--

        /// 自定义地点入口。zh: "找不到出生地?自定义地点";en: "Can't find it? Custom location"
        static let customEntry = String(localized: "city.search.custom.entry")

        /// 出生地卡片内自定义地点提示(BirthFormView)。
        /// zh: "搜不到?搜索页底部可自定义地点(经度 + 时区)。";en: "Can't find it? Custom location (longitude + time zone) at the bottom of search."
        static let customEntryHint = String(localized: "city.search.custom.entryHint")

        /// 经度字段标题。zh: "经度(东正西负)";en: "Longitude (E+/W−)"
        static let customLongitude = String(localized: "city.search.custom.longitude")

        /// 经度输入占位。zh: "如 116.4074 或 -118.24";en: "e.g. 116.4074 or -118.24"
        static let customLongitudeHint = String(localized: "city.search.custom.longitudeHint")

        /// 经度脚注。zh: "4 位小数足够(约 10 米);出生在医院基地、船上等冷门地点时使用"
        static let customLongitudeFooter = String(localized: "city.search.custom.longitudeFooter")

        /// 时区字段标题。zh: "时区(必选)";en: "Time zone (required)"
        static let customTimezone = String(localized: "city.search.custom.timezone")

        /// 时区选择占位。zh: "选择出生地时区";en: "Choose a time zone"
        static let customTimezonePrompt = String(localized: "city.search.custom.timezonePrompt")

        /// 确认按钮。zh: "使用自定义地点";en: "Use custom location"
        static let customConfirm = String(localized: "city.search.custom.confirm")

        /// 返回搜索按钮。zh: "返回搜索";en: "Back to search"
        static let customBack = String(localized: "city.search.custom.back")

        /// 经度校验错误。zh: "经度需为 -180 到 180 之间的数字"
        static let customErrorLongitude = String(localized: "city.search.custom.errorLongitude")

        /// 时区校验错误。zh: "请选择时区"
        static let customErrorTimezone = String(localized: "city.search.custom.errorTimezone")
    }

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

        /// 空态副标题 1(zh="未找到你的命盘存档。")
        static let emptySubtitle1 = String(localized: "dailyfortune.empty.subtitle1")

        /// 空态副标题 2(zh="可在「我的」重置命盘,重新填写出生信息。")
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

    // MARK: - Profile(2026-08-13 onboarding 三屏重构:立场/隐私完整版下沉到关于页)

    /// Profile 模块。
    enum Profile {
        /// 立场标题(为什么可信)。
        /// zh: "为什么可信";en: "Why trust it"
        static let aboutStanceTitle = String(localized: "profile.about.stanceTitle")

        /// 立场 1(排盘确定性)。
        /// zh: "同一组生辰,同一张盘";en: "Same birth data, same chart"
        static let aboutStance1 = String(localized: "profile.about.stance1")

        /// 立场 2(喜忌规则引擎)。
        /// zh: "喜忌由规则判,AI 只润色";en: "Rules decide, AI polishes"
        static let aboutStance2 = String(localized: "profile.about.stance2")

        /// 立场 3(特例如实标注)。
        /// zh: "命局有特例,如实标注";en: "Edge cases are labeled honestly"
        static let aboutStance3 = String(localized: "profile.about.stance3")

        /// 隐私标题。
        /// zh: "隐私与数据";en: "Privacy & data"
        static let aboutPrivacyTitle = String(localized: "profile.about.privacyTitle")

        /// 隐私 1(无账号无云同步)。
        /// zh: "命盘只在你手机上,无账号,无云同步"
        /// en: "Your chart lives on your phone. No account, no cloud sync"
        static let aboutPrivacy1 = String(localized: "profile.about.privacy1")

        /// 隐私 2(AI 走后端)。
        /// zh: "AI 解读走我们服务器,密钥保管在后端"
        /// en: "AI readings run on our servers; keys stay server-side"
        static let aboutPrivacy2 = String(localized: "profile.about.privacy2")

        /// 隐私 3(无跟踪)。
        /// zh: "没有跟踪,没有画像";en: "No tracking, no profiling"
        static let aboutPrivacy3 = String(localized: "profile.about.privacy3")
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
