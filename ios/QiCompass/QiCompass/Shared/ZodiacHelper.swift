import Foundation

/// 生肖辅助:英文 asset name ↔ 中文汉字。
///
/// 后端 `BaziResponse.year_branch_zodiac` 字段是英文(对齐 iOS
/// `Assets.xcassets/Zodiac_*.imageset` 命名),iOS 文案显示需要中文汉字
/// (如 ZodiacRevealView 主标 `辰 · 龙` 的「龙」)。
///
/// 单一事实源:本表与 `backend/app/engine/pillars.py:ZODIAC_NAME` 一一对应。
/// 任一侧新增生肖需同时更新(目前固定 12 个,预期不会变)。
enum ZodiacHelper {
    /// 英文 asset name(如 "Dragon")→ 中文汉字(如 "龙")。
    private static let zodiacToChar: [String: String] = [
        "Rat": "鼠", "Ox": "牛", "Tiger": "虎", "Rabbit": "兔",
        "Dragon": "龙", "Snake": "蛇", "Horse": "马", "Goat": "羊",
        "Monkey": "猴", "Rooster": "鸡", "Dog": "狗", "Pig": "猪",
    ]

    /// 英文 asset name(如 "Dragon")→ 中文汉字(如 "龙")。
    ///
    /// 未知 zodiac → fatalError(对齐 CLAUDE.md "错误显式传播",不静默吞)。
    /// 仅发生在后端字段不规范或前后端 ZODIAC 表不同步时,属开发期 bug,
    /// 生产环境不应触发;若触发了应让 app crash 暴露问题,而非展示错误生肖。
    static func animalChar(forZodiac zodiac: String) -> String {
        guard let char = zodiacToChar[zodiac] else {
            fatalError("未知 zodiac asset name: \(zodiac)。检查后端 year_branch_zodiac 字段或 ZodiacHelper.zodiacToChar 表")
        }
        return char
    }

    /// 英文 asset name(如 "Dragon")→ 生肖人格文案(本地化,按 AppLanguage 切中英)。
    ///
    /// 2026-08-13 onboarding 三屏重构:反馈屏人格段落。
    /// 内容事实源:`L10n.Onboarding.personalityXxx`(12 条 × zh/en,静态善意正面画像)。
    /// 未知 zodiac → fatalError(同上,错误显式传播)。
    static func personalityText(forZodiac zodiac: String) -> String {
        switch zodiac {
        case "Rat":     return L10n.Onboarding.personalityRat
        case "Ox":      return L10n.Onboarding.personalityOx
        case "Tiger":   return L10n.Onboarding.personalityTiger
        case "Rabbit":  return L10n.Onboarding.personalityRabbit
        case "Dragon":  return L10n.Onboarding.personalityDragon
        case "Snake":   return L10n.Onboarding.personalitySnake
        case "Horse":   return L10n.Onboarding.personalityHorse
        case "Goat":    return L10n.Onboarding.personalityGoat
        case "Monkey":  return L10n.Onboarding.personalityMonkey
        case "Rooster": return L10n.Onboarding.personalityRooster
        case "Dog":     return L10n.Onboarding.personalityDog
        case "Pig":     return L10n.Onboarding.personalityPig
        default:
            fatalError("未知 zodiac asset name: \(zodiac)。检查后端 year_branch_zodiac 字段或 ZodiacHelper.zodiacToChar 表")
        }
    }

    /// chip 展示名:中文环境 → 汉字(如「龙」);英文环境 → 英文名(如 "Dragon")。
    /// 对齐 AppLanguage.current("zh"/"en")。
    static func displayName(forZodiac zodiac: String) -> String {
        AppLanguage.current == "zh" ? animalChar(forZodiac: zodiac) : zodiac
    }

    /// 命理性别称谓:「乾造(男)」/「坤造(女)」。
    ///
    /// 2026-08-13 收拢:原 OnboardingView.subLabel 与 ChartHeaderView.genderLabel
    /// 两处重复 ternary,统一到本 helper(单一事实源,称谓规则变更只改一处)。
    /// 非本地化:乾造/坤造是命理术语,v1 中英 UI 均保留汉字(i18n 后续 slice 再议)。
    static func genderLabel(forGender gender: String) -> String {
        gender == "male" ? "乾造(男)" : "坤造(女)"
    }

    /// 生肖名是否在已知 12 生肖表内(S05 时辰未知)。
    /// 年柱歧义(S02/D10 立春日 + 时辰未知)→ yearBranchZodiac 为 null/空,
    /// `animalChar` / `personalityText` 对未知值 fatalError(错误显式传播),
    /// 调用方必须先经此谓词判空(S08 起由 `ZodiacRevealMode` / `ZodiacAvatarMode` 承接)。
    static func isKnownZodiac(_ zodiac: String?) -> Bool {
        guard let zodiac, !zodiac.isEmpty else { return false }
        return zodiacToChar[zodiac] != nil
    }

    // MARK: - 老缓存兜底(2026-08-15 排盘异常修复)

    /// 地支顺序(子→亥),三合组内两友按此序稳定输出(对齐 backend ZHI_ORDER)。
    private static let zhiOrder: [String] = "子丑寅卯辰巳午未申酉戌亥".map(String.init)

    /// 地支 → 英文生肖名(对齐 backend `app/engine/pillars.py:ZODIAC_NAME`)。
    private static let zhiToZodiac: [String: String] = [
        "子": "Rat", "丑": "Ox", "寅": "Tiger", "卯": "Rabbit",
        "辰": "Dragon", "巳": "Snake", "午": "Horse", "未": "Goat",
        "申": "Monkey", "酉": "Rooster", "戌": "Dog", "亥": "Pig",
    ]

    /// 六合(双向):子丑 / 寅亥 / 卯戌 / 辰酉 / 巳申 / 午未。
    private static let liuhe: [String: String] = [
        "子": "丑", "丑": "子", "寅": "亥", "亥": "寅",
        "卯": "戌", "戌": "卯", "辰": "酉", "酉": "辰",
        "巳": "申", "申": "巳", "午": "未", "未": "午",
    ]

    /// 六冲(双向):子午 / 丑未 / 寅申 / 卯酉 / 辰戌 / 巳亥。
    private static let liuchong: [String: String] = [
        "子": "午", "午": "子", "丑": "未", "未": "丑",
        "寅": "申", "申": "寅", "卯": "酉", "酉": "卯",
        "辰": "戌", "戌": "辰", "巳": "亥", "亥": "巳",
    ]

    /// 三合局(4 组,每组 3 支):申子辰 / 寅午戌 / 巳酉丑 / 亥卯未。
    private static let sanheGroups: [[String]] = [
        ["申", "子", "辰"], ["寅", "午", "戌"], ["巳", "酉", "丑"], ["亥", "卯", "未"],
    ]

    /// 年支 → (生肖, 好朋友 3 支, 六冲 1 支)英文生肖名。
    ///
    /// 用途:`year_branch_zodiac`(2026-08-11)与 `year_branch_friends/clash`
    /// (2026-08-13)上线**之前**落库的 ChartSnapshot.payload 不含这些 key,
    /// `BaziResponse.init(from:)` 强制解码 keyNotFound → 全模块「排盘异常」。
    /// 修复:缺 key 时从已解码的 `pillars.year.zhi` 本地查表兜底——三字段均为
    /// 年支的纯查表函数,兜底值与新响应后端计算值一致。
    ///
    /// 语义事实源对齐 backend `app/engine/branch_relations.py:compute_friends_and_clash`:
    /// 好朋友 = 六合 1 支(排第一)+ 三合 2 支(按地支顺序);需磨合 = 六冲 1 支。
    /// 新响应恒含这三字段,不走本路径;任一侧关系表变更需同步(命理固定关系,预期不变)。
    ///
    /// 未知地支 → nil(调用方抛 DecodingError,不静默吞)。
    static func legacyYearBranchFields(
        forYearZhi zhi: String
    ) -> (zodiac: String, friends: [String], clash: String)? {
        guard let zodiac = zhiToZodiac[zhi],
              let liuheZhi = liuhe[zhi],
              let clashZhi = liuchong[zhi] else {
            return nil
        }
        guard let sanheGroup = sanheGroups.first(where: { $0.contains(zhi) }) else {
            return nil
        }
        let sanheTwo = sanheGroup
            .filter { $0 != zhi }
            .sorted { zhiOrder.firstIndex(of: $0)! < zhiOrder.firstIndex(of: $1)! }
        let friends = ([liuheZhi] + sanheTwo).compactMap { zhiToZodiac[$0] }
        guard let clashZodiac = zhiToZodiac[clashZhi] else { return nil }
        // 3 支全部映射成功才算兜底数据完整(任一 nil 说明表不同步,显式失败)
        guard friends.count == 3 else { return nil }
        return (zodiac: zodiac, friends: friends, clash: clashZodiac)
    }
}

// MARK: - 生肖反馈屏展示模式(S08,D10 年柱歧义降级)

/// ZodiacRevealView(onboarding 第 3 屏)的展示模式。
///
/// 事实源:`docs/时辰未知设计决策.md` D10 命中后果 + `docs/时辰未知-slices/S08`。
/// 测试 target 无 ViewInspector,视图分支经此纯函数断言(对齐 `PillarSlotModel` 范式)。
enum ZodiacRevealMode: Equatable {
    /// 正常态:生肖 / 人格 / 好朋友 / 需磨合照常呈现。
    /// 含**无时辰但年柱确定**的盘(非立春日 ≈99.7% 用户)——无时辰用户的生肖反馈
    /// 是 onboarding 少数完全不受影响的奖励,保持「哇」时刻(S08 验收:正常路径零变化)。
    case full
    /// 立春降级态:年柱歧义(立春交界日 + 时辰未知)→ `year_branch_zodiac=null`,
    /// 生肖系内容(主标/人格/好朋友/需磨合)全部不展示——**不猜**,
    /// 两侧候选生肖都不给(「可能是龙可能是蛇」这种表达禁止)。
    case yearAmbiguous

    /// 判据 = `year_branch_zodiac == null`(S02 立春歧义;friends/clash 级联同源)。
    /// 有时辰用户(含立春日,时辰可判侧)后端恒给生肖 → 恒 full(完全现状行为)。
    static func resolve(zodiac: String?) -> ZodiacRevealMode {
        ZodiacHelper.isKnownZodiac(zodiac) ? .full : .yearAmbiguous
    }
}

// MARK: - 命主卡/账号头像展示模式(S08,D10 年柱歧义 → 通用墨点)

/// Profile 生肖图展示模式(命主卡 IdentityCard + 登录态账号头像两个消费点)。
enum ZodiacAvatarMode: Equatable {
    /// 正常态:生肖印章图(asset name 如 `Zodiac_Rat`)。
    case zodiac(String)
    /// 有命盘但年柱歧义(立春 + 时辰未知)→ 通用墨点(墨圆)表达:不猜属相、
    /// 不再整体隐藏命主卡(S05 兜底是隐藏,本态给正式表达)。
    case inkDot
    /// 无命盘 / payload decode 失败 → 不展示(既有降级,沿用;头像位留空)。
    case hidden

    /// 展示模式判定(纯函数,便于三态分支测试)。
    /// - Parameters:
    ///   - hasChart: 命盘是否存在且 payload 可解码(调用方 decode 失败时传 false)
    ///   - zodiac: decode 出的 `yearBranchZodiac`(nil = S02 显式 null,
    ///     或 legacy 缺 key 且年柱亦缺失、查表兜底不可达)
    static func resolve(hasChart: Bool, zodiac: String?) -> ZodiacAvatarMode {
        guard hasChart else { return .hidden }
        guard let zodiac, ZodiacHelper.isKnownZodiac(zodiac) else { return .inkDot }
        return .zodiac("Zodiac_\(zodiac)")
    }
}
