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
/// Text(L10n.DailyFortune.shortLabel)                        // 替代 Text("今日运势")
/// Text(L10n.DailyFortune.chongLabel(chong: "午", targets: []))  // 替代 Text("冲午")
/// ```
enum L10n {
    // MARK: - Onboarding(2026-08-13 三屏重构新增)

    /// Onboarding 模块。
    enum Onboarding {
        // -- Welcome 屏(O1,第 1 屏;i18n 补录 2026-08-29)--

        /// Welcome 副标题(墨圆/玄印之下)。
        /// zh: "读懂你的命局";en: "Know your chart"
        static let welcomeTagline = String(localized: "onboarding.welcome.tagline")

        /// 左滑提示(经文之下、系统翻页点之上)。
        /// zh: "左滑录入生辰 ›";en: "Swipe to enter birth details ›"
        static let welcomeSwipeHint = String(localized: "onboarding.welcome.swipeHint")

        // -- 表单页(第 2 屏)--

        /// 表单页标题。
        /// zh: "你的出生信息";en: "Your birth details"
        static let formTitle = String(localized: "onboarding.form.title")

        /// 表单页小副标(标题之下;i18n 补录 2026-08-29)。
        /// zh: "八字 · 由此起算";en: "Your BaZi starts here"
        static let formSubtitle = String(localized: "onboarding.form.subtitle")

        /// 隐私微文案(表单页底部,Q1 拆分下沉:隐私信息在用户交出生信息那一刻出现)。
        /// zh: "命盘只存你手机 · 无账号";en: "Your chart stays on your phone · No account"
        static let formPrivacyLine = String(localized: "onboarding.form.privacyLine")

        // -- 排盘布算屏(O3,水墨孤本 InkCalculatingView)--

        /// 布算主标(中文竖排 / 英文 VText 自动横排回退)。
        /// zh: "排盘布算中";en: "Charting your destiny"
        static let calculatingTitle = String(localized: "onboarding.calculating.title")

        /// 推演条目行。
        /// zh: "四柱 · 十神 · 神煞 · 大运";en: "Pillars · Ten Gods · Omens · Luck cycles"
        static let calculatingSteps = String(localized: "onboarding.calculating.steps")

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

        // -- 立春降级态(S08,D10 年柱歧义 → 生肖屏降级,不猜)--

        /// 告知句(一句,如实;两侧候选生肖都不展示——「可能是龙可能是蛇」属猜,禁止)。
        /// zh: "你的出生日在立春交界，需要准确时辰才能确定属相"
        /// en: "Your birthday falls on the Start-of-Spring boundary — the exact hour is needed to settle your zodiac sign"
        static let revealYearAmbiguousNotice = String(localized: "onboarding.reveal.yearAmbiguous.notice")

        /// 补时辰轻提示(D7 降级态例外触点——被迫告知;一期轻提示,S10 接线到补时辰流程)。
        /// zh: "想起出生时刻，随时可以补上";en: "Remember your birth hour later? You can add it anytime"
        static let revealYearAmbiguousHint = String(localized: "onboarding.reveal.yearAmbiguous.hint")

        /// 降级态 CTA(完成 onboarding 进 App,四柱页留白表达;正常态 CTA 不变)。
        /// zh: "继续";en: "Continue"
        static let revealCTADegraded = String(localized: "onboarding.reveal.cta.degraded")

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

    // MARK: - 出生信息表单(BirthFormView;i18n 补录 2026-08-29)

    /// 出生信息表单(onboarding O2 / 深度解析无存档兜底 / Profile 新建命盘三处复用)。
    /// 品牌/规则类字串不进本表:「問命」「玄」「玄机问道」、干支字符、「X时 ›」。
    enum BirthForm {
        /// "出生日期" 字段标签(日期行 + 确认 sheet 日期行共用;S03 拆双 picker)。
        /// zh: "出生日期";en: "Birth date"
        static let birthDateLabel = String(localized: "birthform.birthDate.label")

        /// "出生时刻" 字段标签(时刻行 + 确认 sheet 时刻行共用;S03 拆双 picker)。
        /// zh: "出生时刻";en: "Birth time"
        static let birthTimeLabel = String(localized: "birthform.birthTime.label")

        /// 日期未选择占位(S03 日期必选:nil 初始态的日期行文案)。
        /// zh: "请选择日期";en: "Select a date"
        static let birthDatePlaceholder = String(localized: "birthform.birthDate.placeholder")

        /// 日期必选校验错误(S03/D8 默认日期洞修复)。
        /// zh: "请选择出生日期";en: "Please select your birth date"
        static let errorDateRequired = String(localized: "birthform.error.dateRequired")

        /// 日期+时刻合成失败防御性错误(理论不可达;错误显式传播用)。
        /// zh: "出生日期与时刻无法合成,请重新选择";en: "Couldn't combine date and time — please reselect"
        static let errorCombineFailed = String(localized: "birthform.error.combineFailed")

        /// 日期区教育微文案(D8 把矛盾变成教育;S04 补「时刻可跳过」半句)。
        /// zh: "日期决定年月柱与生肖;时刻决定时柱与喜忌;不知道时刻可先跳过"
        /// en: "Date sets year & month pillars and your zodiac; time sets the hour pillar and favorable elements; skip the time if unknown"
        static let dateEducationHint = String(localized: "birthform.date.educationHint")

        // -- 时辰未知入口(S04,D1 单一入口 + D3 二值半夜问题)--

        /// 「不知道出生时刻」入口(checkbox 文案;直说不弱智化,不用「跳过」)。
        /// zh: "不知道出生时刻";en: "I don't know my birth time"
        static let hourUnknownToggle = String(localized: "birthform.hourUnknown.toggle")

        /// 半夜二值问题(D3 唯一一问,用途 = 日柱歧义判断)。
        /// zh: "你是否在半夜(约 11 点之后)出生?";en: "Were you born late at night (after about 11 p.m.)?"
        static let lateNightQuestion = String(localized: "birthform.lateNight.question")

        /// 三态「是」。zh: "是";en: "Yes"
        static let lateNightYes = String(localized: "birthform.lateNight.yes")

        /// 三态「否」。zh: "否";en: "No"
        static let lateNightNo = String(localized: "birthform.lateNight.no")

        /// 三态「不确定」。zh: "不确定";en: "Not sure"
        static let lateNightUnsure = String(localized: "birthform.lateNight.unsure")

        /// 半夜问题用途微注(D3「用途对用户可见」,只讲日柱不讲玄)。
        /// zh: "半夜出生的人日柱可能落在次日;这一问只为确认日柱"
        /// en: "Born near midnight, the day pillar may fall on the next day — this only settles the day pillar"
        static let lateNightHint = String(localized: "birthform.lateNight.hint")

        /// 勾选「不知道」但三态未选的校验错误(不默认「不确定」,必须显式选)。
        /// zh: "请选择是否半夜出生";en: "Please answer the late-night question"
        static let errorLateNightRequired = String(localized: "birthform.error.lateNightRequired")

        /// 确认 sheet 无时辰时刻行(带三态答案)。
        /// zh: "未知(半夜:%@)";en: "Unknown (late night: %@)"
        static func confirmTimeUnknown(_ answer: String) -> String {
            String(format: String(localized: "birthform.confirm.timeUnknown"), answer)
        }

        /// 确认 sheet 无时辰且三态未答(诚实展示未答,提交被 formInvalid 拦)。
        /// zh: "未知(半夜:未答)";en: "Unknown (late night: unanswered)"
        static let confirmTimeUnknownNoAnswer = String(localized: "birthform.confirm.timeUnknownNoAnswer")

        /// "命盘别名" 字段标签(字段 Micro 标签与 TextField 标题共用同一 key)。
        /// zh: "命盘别名";en: "Chart name"
        static let aliasLabel = String(localized: "birthform.alias.label")

        /// 别名输入占位。
        /// zh: "我自己 / 妈妈 / 男友";en: "Me / Mom / Partner"
        static let aliasPlaceholder = String(localized: "birthform.alias.placeholder")

        /// 日期 wheel sheet 标题(亦作日期行 accessibilityLabel;S03 拆分后 date-only)。
        /// zh: "选择出生日期";en: "Birth date"
        static let datePickerTitleDate = String(localized: "birthform.datePicker.title.date")

        /// 时刻 wheel sheet 标题(亦作时刻行 accessibilityLabel;S03 拆分后 hourAndMinute)。
        /// zh: "选择出生时刻";en: "Birth time"
        static let datePickerTitleTime = String(localized: "birthform.datePicker.title.time")

        /// 时辰快捷选字段标签。
        /// zh: "时辰快捷选(可选)";en: "Quick hour pick (optional)"
        static let hourQuickPickLabel = String(localized: "birthform.hourQuickPick.label")

        /// 时辰快捷选 DisclosureGroup 提示。
        /// zh: "只知时辰不知精确时间?点此选";en: "Only know the rough hour? Tap to pick"
        static let hourQuickPickHint = String(localized: "birthform.hourQuickPick.hint")

        /// 性别字段标签。
        /// zh: "性别";en: "Gender"
        static let genderLabel = String(localized: "birthform.gender.label")

        /// 性别 chip「男」显示文案(tag 值 "male" 是后端契约,不本地化)。
        /// zh: "男";en: "Male"
        static let genderMale = String(localized: "birthform.gender.male")

        /// 性别 chip「女」显示文案(tag 值 "female" 是后端契约,不本地化)。
        /// zh: "女";en: "Female"
        static let genderFemale = String(localized: "birthform.gender.female")

        /// 出生地字段标签。
        /// zh: "出生地";en: "Birthplace"
        static let birthplaceLabel = String(localized: "birthform.birthplace.label")

        /// CTA 标题。
        /// zh: "开始排盘";en: "Chart my destiny"
        static let ctaStart = String(localized: "birthform.cta.start")

        /// CTA loading 文案。
        /// zh: "排盘布算中";en: "Charting…"
        static let ctaLoading = String(localized: "birthform.cta.loading")
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

        /// 页首短标签(V4 三行日期区第三行的 chip)。
        /// zh: "今日运势";en: "Daily Fortune"
        static let shortLabel = String(localized: "dailyfortune.header.shortLabel")

        /// 干支后缀(L2 行「丙子日」的「日」)。
        /// zh: "日";en: " Day"
        static let dayPillarSuffix = String(localized: "dailyfortune.header.dayPillarSuffix")

        /// 解读小注免责(V4 hero 文本区脚注尾部)。
        /// zh: "解读仅供参照";en: "For reference only"
        static let disclaimer = String(localized: "dailyfortune.hero.disclaimer")

        /// 插画生成中小字(hero 骨架态)。
        /// zh: "生图中";en: "Painting"
        static let heroGenerating = String(localized: "dailyfortune.hero.generating")

        /// 插画失败重试按钮。
        /// zh: "重试";en: "Retry"
        static let heroRetry = String(localized: "dailyfortune.hero.retry")

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

        /// 缓存标识(zh="24h 内已缓存,不消耗次数")
        static let interpretCached = String(localized: "dailyfortune.interpret.cached")

        /// 重试按钮(zh="重试", en="Retry")
        static let interpretRetry = String(localized: "dailyfortune.interpret.retry")

        /// CTA 说明文字(zh="点击生成今日流日解读(约 50-80 字)")
        static let interpretCTA = String(localized: "dailyfortune.interpret.cta")

        /// 加载中文字(zh="推演中…", en="Divining…")
        static let interpretLoading = String(localized: "dailyfortune.interpret.loading")

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

        /// S09 降级版末尾静默提示(D7 触点 2:一行文字,不是弹窗;S10 接线成可点击)。
        /// zh: "这份运势只用了你的日柱。补上时辰可以看到时辰运势与喜忌。"
        /// en: "This reading uses only your day pillar. Add your birth hour to see hourly fortune and favorable elements."
        static let degradedHint = String(localized: "dailyfortune.main.degradedHint")

        // -- History Lookback(2026-08-30,规则:免费 7 天 / 任意购买解锁全部) --

        /// 「更早」pill 标签。
        /// zh: "更早";en: "Earlier"
        static let historyEarlier = String(localized: "dailyfortune.history.earlier")

        /// 历史 sheet 标题(锁定态 + 清单态共用)。
        /// zh: "历史回看";en: "History"
        static let historySheetTitle = String(localized: "dailyfortune.history.sheetTitle")

        /// sheet 完成按钮。
        /// zh: "完成";en: "Done"
        static let historyDone = String(localized: "dailyfortune.history.done")

        /// 锁定态标题。
        /// zh: "免费回看 7 天";en: "Free: past 7 days"
        static let historyFreeTitle = String(localized: "dailyfortune.history.freeTitle")

        /// 锁定态说明(规则一句话)。
        /// zh: "完成任意一次购买,即可解锁全部历史回看。";en: "Any purchase unlocks your full lookback."
        static let historyUnlockNote = String(localized: "dailyfortune.history.unlockNote")

        /// 锁定态 CTA(打开付费墙;付费墙本身卖深度解析/合盘)。
        /// zh: "解锁全部历史";en: "Unlock full history"
        static let historyUnlockCTA = String(localized: "dailyfortune.history.unlockCTA")
    }

    // MARK: - 合盘模块(DualPillarsTable / SyncedFortuneTable;i18n 补录 2026-08-29)

    /// 合盘结果态(DualPillarsTable 双盘对比 + SyncedFortuneTable 流年同步)。
    /// 注:行内显示值(personA/personB/sync)来自后端中文真值,iOS 不本地化。
    enum Compatibility {
        // -- 双盘对比 --

        /// 区块 kicker。
        /// zh: "双盘对比";en: "Two charts, side by side"
        static let dualTitle = String(localized: "hepan.dual.title")

        /// 年柱位标签(DualPillarSource.from(a:b:) 生产数据用)。
        /// zh: "年柱";en: "Year Pillar"
        static let dualYearPillar = String(localized: "hepan.dual.yearPillar")

        /// 月柱位标签。
        /// zh: "月柱";en: "Month Pillar"
        static let dualMonthPillar = String(localized: "hepan.dual.monthPillar")

        /// 日柱位标签。
        /// zh: "日柱";en: "Day Pillar"
        static let dualDayPillar = String(localized: "hepan.dual.dayPillar")

        /// 时柱位标签。
        /// zh: "时柱";en: "Hour Pillar"
        static let dualHourPillar = String(localized: "hepan.dual.hourPillar")

        // -- 流年同步 --

        /// 区块 kicker。
        /// zh: "流年同步 · 未来三年";en: "Yearly sync · the next three years"
        static let syncedTitle = String(localized: "hepan.synced.title")

        /// 列头「年份」。
        /// zh: "年份";en: "Year"
        static let syncedYear = String(localized: "hepan.synced.year")

        /// 列头「A 流年」。
        /// zh: "A 流年";en: "A's year"
        static let syncedPersonAYear = String(localized: "hepan.synced.personAYear")

        /// 列头「B 流年」。
        /// zh: "B 流年";en: "B's year"
        static let syncedPersonBYear = String(localized: "hepan.synced.personBYear")

        /// 列头「同步」。
        /// zh: "同步";en: "Sync"
        static let syncedSync = String(localized: "hepan.synced.sync")
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

    // MARK: - M4 健康输入表单(HealthInputForm;i18n 补录 2026-08-29)

    /// M4 健康续航「生成前两问」输入 sheet。
    /// `required` / `cta.*` 与 M5 WealthInputForm 共用引用(key 不重复建)。
    /// 选项 value(睡眠/疲劳/体重/情绪/其他)是提交 payload,不本地化,不进本表。
    enum HealthForm {
        /// 章头 kicker。
        /// zh: "第 伍 章 · 生成前两问";en: "Chapter V · Two questions first"
        static let kicker = String(localized: "healthform.kicker")

        /// 章题。
        /// zh: "健康续航 · 因你而异";en: "Health & vitality · shaped by you"
        static let title = String(localized: "healthform.title")

        /// 副题(章题之下)。
        /// zh: "这一章结合你的年龄与近况推演,答案只影响本章内容。仅供参考,不替代医生。"
        /// en: "This chapter draws on your age and current state. Your answers shape this chapter only. For reference — not medical advice."
        static let subtitle = String(localized: "healthform.subtitle")

        /// Q1 问题名。
        /// zh: "你的年龄";en: "Your age"
        static let ageQuestion = String(localized: "healthform.age.question")

        /// 「必答」朱红小字(M4/M5 共用)。
        /// zh: "必答";en: "Required"
        static let required = String(localized: "healthform.required")

        /// 年龄减小按钮 accessibilityLabel。
        /// zh: "减小年龄";en: "Decrease age"
        static let ageDecrease = String(localized: "healthform.age.decrease")

        /// 年龄增大按钮 accessibilityLabel。
        /// zh: "增大年龄";en: "Increase age"
        static let ageIncrease = String(localized: "healthform.age.increase")

        /// stepper 年龄值(zh "30 岁" / en "30 yrs")。
        static func ageValue(_ age: Int) -> String {
            String(format: String(localized: "healthform.age.value"), age)
        }

        /// Q2 问题名。
        /// zh: "近来的身体状况";en: "How you've been feeling"
        static let concernQuestion = String(localized: "healthform.concern.question")

        /// chip「睡眠」短标。zh: "睡眠";en: "Sleep"
        static let concernSleep = String(localized: "healthform.concern.sleep")

        /// chip「疲劳」短标。zh: "疲劳";en: "Fatigue"
        static let concernFatigue = String(localized: "healthform.concern.fatigue")

        /// chip「体重」短标。zh: "体重";en: "Weight"
        static let concernWeight = String(localized: "healthform.concern.weight")

        /// chip「情绪」短标。zh: "情绪";en: "Mood"
        static let concernMood = String(localized: "healthform.concern.mood")

        /// chip「其他」短标。zh: "其他";en: "Other"
        static let concernOther = String(localized: "healthform.concern.other")

        /// 「睡眠」选中 detail 注。
        /// zh: "入睡难 / 醒得早 / 不解乏";en: "Hard to fall asleep / waking early / unrefreshed"
        static let concernSleepDetail = String(localized: "healthform.concern.sleep.detail")

        /// 「疲劳」选中 detail 注。
        /// zh: "工作日长期精力不济";en: "Running on empty on workdays"
        static let concernFatigueDetail = String(localized: "healthform.concern.fatigue.detail")

        /// 「体重」选中 detail 注。
        /// zh: "代谢 / 食欲 / 体型";en: "Metabolism / appetite / body shape"
        static let concernWeightDetail = String(localized: "healthform.concern.weight.detail")

        /// 「情绪」选中 detail 注。
        /// zh: "焦虑 / 低落 / 易怒";en: "Anxiety / low mood / irritability"
        static let concernMoodDetail = String(localized: "healthform.concern.mood.detail")

        /// 「其他」选中 detail 注。
        /// zh: "暂无法填细节,仅告知大类";en: "No details for now — just the category"
        static let concernOtherDetail = String(localized: "healthform.concern.other.detail")

        /// 提交 CTA 标题(M4/M5 共用)。
        /// zh: "生成本章";en: "Generate this chapter"
        static let ctaGenerate = String(localized: "healthform.cta.generate")

        /// 提交 CTA loading(M4/M5 共用)。
        /// zh: "生成中…";en: "Divining…"
        static let ctaLoading = String(localized: "healthform.cta.loading")

        /// CTA 之下「稍后」Micro 注(M4/M5 共用)。
        /// zh: "稍后在章节内补答也可";en: "You can also answer later in the chapter"
        static let ctaLater = String(localized: "healthform.cta.later")
    }

    // MARK: - M5 财富输入表单(WealthInputForm;i18n 补录 2026-08-29)

    /// M5 财富结构「生成前两问」输入 sheet。
    /// 章头「取消」走 `L10n.Common.cancel`,「必答」/「生成本章」等走 `L10n.HealthForm`(共用)。
    /// preference value(保守/平衡/进攻)是提交 payload,不本地化,不进本表。
    enum WealthForm {
        /// 章头 kicker。
        /// zh: "第 陆 章 · 生成前两问";en: "Chapter VI · Two questions first"
        static let kicker = String(localized: "wealthform.kicker")

        /// 章题。
        /// zh: "财富结构 · 因你而异";en: "Wealth & structure · shaped by you"
        static let title = String(localized: "wealthform.title")

        /// 副题(章题之下)。
        /// zh: "这一章结合你的资产概况与风险偏好推演,答案只影响本章内容。自我认知参考,不构成投资建议。"
        /// en: "This chapter draws on your assets and risk appetite. Your answers shape this chapter only. Self-knowledge only — not investment advice."
        static let subtitle = String(localized: "wealthform.subtitle")

        /// Q1 问题名(问题标签与 TextField 标题共用同一 key)。
        /// zh: "资产 / 收入概况";en: "Assets & income snapshot"
        static let assetsQuestion = String(localized: "wealthform.assets.question")

        /// Q1 输入占位。
        /// zh: "如:中等收入,有积蓄,无房产";en: "e.g. median income, some savings, no property"
        static let assetsPlaceholder = String(localized: "wealthform.assets.placeholder")

        /// Q1 脚注(计数器左侧)。
        /// zh: "可粗略,不需精确数字";en: "Rough is fine — no exact numbers"
        static let assetsHint = String(localized: "wealthform.assets.hint")

        /// Q2 问题名。
        /// zh: "风险偏好";en: "Risk appetite"
        static let riskQuestion = String(localized: "wealthform.risk.question")

        /// chip「保守」短标。zh: "保守";en: "Conservative"
        static let riskConservative = String(localized: "wealthform.risk.conservative")

        /// chip「平衡」短标。zh: "平衡";en: "Balanced"
        static let riskBalanced = String(localized: "wealthform.risk.balanced")

        /// chip「进攻」短标。zh: "进攻";en: "Aggressive"
        static let riskAggressive = String(localized: "wealthform.risk.aggressive")

        /// 「保守」选中 hint 注。
        /// zh: "保本为先,不愿承担亏损";en: "Capital first — no losses please"
        static let riskConservativeHint = String(localized: "wealthform.risk.conservative.hint")

        /// 「平衡」选中 hint 注。
        /// zh: "中等风险,稳健增长";en: "Moderate risk, steady growth"
        static let riskBalancedHint = String(localized: "wealthform.risk.balanced.hint")

        /// 「进攻」选中 hint 注。
        /// zh: "高波动换高回报可能";en: "High volatility for a shot at high returns"
        static let riskAggressiveHint = String(localized: "wealthform.risk.aggressive.hint")
    }

    // MARK: - 付费墙时辰未知拦截态(S07,iOS 一期临时态)

    /// 付费墙/内容拦截态文案(docs/时辰未知设计决策.md D5/D6)。
    /// 水墨克制表达:一句话 + 占位入口,无红色警示;CTA 一期占位,S10 接线补时辰 sheet。
    enum PaywallGate {
        /// 拦截态主句(付费墙 sheet,日柱确定的无时辰用户)。
        /// zh: "补充出生时刻后解锁";en: "Add your birth hour to unlock"
        static let title = String(localized: "paywall.hourUnknown.title")

        /// 为什么一句(付费墙 sheet):时辰缺失影响喜忌分析精度。
        /// zh: "时辰缺失会影响喜忌分析的精度";en: "A missing birth hour reduces the precision of the favorable-elements reading"
        static let reason = String(localized: "paywall.hourUnknown.reason")

        /// 日柱歧义整拦态主句(深度解析不进内容页)。
        /// zh: "缺出生时辰,暂时无法解读";en: "Your birth hour is needed before this chart can be read"
        static let dayAmbiguousTitle = String(localized: "paywall.hourUnknown.dayAmbiguous.title")

        /// 日柱歧义为什么一句:子夜前后无时辰定不了日柱。
        /// zh: "你的生日落在子夜前后,没有时辰无法确定日柱——日柱是所有解读的起点"
        /// en: "Born near midnight? Without the hour, the day pillar — the anchor of every reading — can't be settled"
        static let dayAmbiguousReason = String(localized: "paywall.hourUnknown.dayAmbiguous.reason")

        /// 合盘对级拦截态主句(任一方无时辰,整对拦)。
        /// zh: "缺出生时辰 · 此对暂不可合盘";en: "Missing birth hour · this pair can't be read yet"
        static let compatibilityTitle = String(localized: "paywall.hourUnknown.compatibility.title")

        /// 合盘为什么一句:需要双方时柱与喜忌。
        /// zh: "合盘需要双方的时柱与喜忌;补上时辰即可解锁"
        /// en: "Compatibility needs both hour pillars and favorable elements — add the missing hour to unlock"
        static let compatibilityReason = String(localized: "paywall.hourUnknown.compatibility.reason")

        /// CTA 占位(一期轻提示,S10 接线到补时辰 sheet)。
        /// zh: "补上出生时刻";en: "Add your birth hour"
        static let cta = String(localized: "paywall.hourUnknown.cta")

        /// CTA 占位点击后的轻提示(S10 上线前的诚实表达)。
        /// zh: "补时辰入口即将开放";en: "The add-hour flow is coming soon"
        static let ctaHint = String(localized: "paywall.hourUnknown.ctaHint")

        /// 日柱歧义整拦页的逃生口(回表单重填)。
        /// zh: "返回表单";en: "Back to form"
        static let backToForm = String(localized: "paywall.hourUnknown.backToForm")

        /// 每日运势日柱歧义整拦态主句(S09,D5 全拦:免费降级亦不成立)。
        /// zh: "缺出生时辰,暂时无法看每日运势";en: "Your birth hour is needed before daily fortune can be read"
        static let dailyFortuneTitle = String(localized: "paywall.hourUnknown.dailyFortune.title")

        /// 每日运势为什么一句:日柱定不了,运势的起点就没了。
        /// zh: "你的生日落在子夜前后,没有时辰无法确定日柱——每日运势以日柱为起点"
        /// en: "Born near midnight? Without the hour, the day pillar — the anchor of daily fortune — can't be settled"
        static let dailyFortuneReason = String(localized: "paywall.hourUnknown.dailyFortune.reason")
    }

    // MARK: - 合盘 roster 不可合盘标记(S11)

    /// 合盘配置态名单标记文案(docs/时辰未知-slices/S11)。
    /// 水墨克制表达:置灰/留白记号 + 一句解释,无红色警示,无重试按钮。
    enum CompatibilityRosterGate {
        /// roster 行 / 存档多选行的「不可合盘」短标(他人无时辰 → 该对不可用)。
        /// zh: "时辰未知 · 不可合盘";en: "Hour unknown · can't pair yet"
        static let mark = String(localized: "compatibility.roster.hourUnknown.mark")

        /// 点击被标记行 / 被拦勾选时的轻提示一句(比发起后报错更早一层 UX)。
        /// zh: "这位命盘缺出生时辰,补上后即可合盘";en: "This chart is missing its birth hour — add it to unlock pairing"
        static let hint = String(localized: "compatibility.roster.hourUnknown.hint")

        /// 自己无时辰:名单整体标记解释行(全部对不可用 +「开始合盘」不可发起)。
        /// zh: "你的命盘缺出生时辰,所有对暂不可合盘;补上时刻即可恢复"
        /// en: "Your chart is missing its birth hour — all pairs are on hold until it's added"
        static let selfBanner = String(localized: "compatibility.roster.hourUnknown.selfBanner")
    }

    // MARK: - 共享组件

    /// 共享文案(跨模块复用:CountdownResetLabel / DailyLimitReachedView / M4-M5 章头取消)。
    enum Common {
        /// 取消按钮(M4/M5 输入 sheet 章头等)。
        /// zh: "取消";en: "Cancel"
        static let cancel = String(localized: "common.cancel")

        /// 达上限提示(zh="今日机缘已尽,明日再来")
        static let limitReached = String(localized: "common.limitReached")

        /// 倒计时完整标签(zh="距重置:3 时 15 分", en="Resets in 3h 15m")
        static func countdownLabel(hours: Int, minutes: Int) -> String {
            let timeStr = String(
                format: String(localized: "common.countdown.timeFormat"), hours, minutes
            )
            return String(format: String(localized: "common.countdown"), timeStr)
        }

        /// 时辰未知(S05 时辰未知系列:柱留白 VoiceOver 标签 / 真太阳时行)。
        /// 中性陈述不是错误提示(无红字无感叹号,留白是水墨表达)。
        /// zh: "时辰未知";en: "Birth hour unknown"
        static let hourUnknown = String(localized: "common.hourUnknown")
    }
}
