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
}
