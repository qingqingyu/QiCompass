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
}
