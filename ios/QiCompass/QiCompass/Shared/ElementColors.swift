import SwiftUI

// MARK: - ElementColors

/// 五行色 token(木火土金水)。
///
/// 后端 `gan_element` / `zhi_element` 返回英文 `metal/wood/water/fire/earth`,
/// 本枚举的 rawValue 与之对齐,直接 `ElementColors(rawValue: dto.ganElement)` 即可取色。
///
/// 色值按传统五行色选取,并调暗以适配 App 暗金主题:
/// - 木(青绿)/ 火(赤)/ 土(黄)/ 金(白金)/ 水(玄蓝)
enum ElementColors: String {
    case wood
    case fire
    case earth
    case metal
    case water

    /// 五行对应色。未知 rawValue 兜底为 textDim(不静默用主金,避免与金元素混淆)。
    var color: Color {
        switch self {
        case .wood:  return Color(red: 0x4a/255, green: 0x9d/255, blue: 0x5f/255)
        case .fire:  return Color(red: 0xc4/255, green: 0x45/255, blue: 0x45/255)
        case .earth: return Color(red: 0xc9/255, green: 0xa0/255, blue: 0x3c/255)
        case .metal: return Color(red: 0xd4/255, green: 0xc8/255, blue: 0xa8/255)
        case .water: return Color(red: 0x3a/255, green: 0x6b/255, blue: 0x9c/255)
        }
    }

    /// 中文标签(展示用)。
    var label: String {
        switch self {
        case .wood:  return "木"
        case .fire:  return "火"
        case .earth: return "土"
        case .metal: return "金"
        case .water: return "水"
        }
    }

    /// 安全构造:未知字符串返回 nil(调用方决定降级策略,不静默兜底)。
    static func from(_ raw: String) -> ElementColors? {
        ElementColors(rawValue: raw)
    }

    /// 天干 → 五行英文 key(纯展示查表,非历法计算)。
    static func ofGan(_ gan: String) -> String? {
        switch gan {
        case "甲", "乙": return "wood"
        case "丙", "丁": return "fire"
        case "戊", "己": return "earth"
        case "庚", "辛": return "metal"
        case "壬", "癸": return "water"
        default: return nil
        }
    }

    /// 中文五行名(木火土金水)→ 英文 key。
    static func fromZh(_ zh: String) -> String? {
        switch zh {
        case "木": return "wood"
        case "火": return "fire"
        case "土": return "earth"
        case "金": return "metal"
        case "水": return "water"
        default: return nil
        }
    }

    /// 地支 → 五行英文 key(纯展示查表,非历法计算)。
    static func ofZhi(_ zhi: String) -> String? {
        switch zhi {
        case "子", "亥": return "water"
        case "寅", "卯": return "wood"
        case "巳", "午": return "fire"
        case "申", "酉": return "metal"
        case "辰", "戌", "丑", "未": return "earth"
        default: return nil
        }
    }
}

// MARK: - BaziTheme 扩展(五行色 + chip 样式)

extension BaziTheme {
    /// 五行色便捷访问(通过 ElementColors 转发)。
    static func elementColor(_ key: String) -> Color {
        ElementColors.from(key)?.color ?? textDim
    }

    /// 吉神 chip 背景描边色。
    static let shenshaAuspicious = gold

    /// 凶煞 chip 背景描边色(暗红,与吉神金色区分)。
    static let shenshaInauspicious = Color(red: 0x8a/255, green: 0x2b/255, blue: 0x2b/255)

    /// 卡片底色(半透明白叠加,用于命盘各区域分组)。
    static let cardBackground = Color.white.opacity(0.04)

    /// 卡片描边色(主金低透明度)。
    static let cardBorder = gold.opacity(0.25)

    /// 分隔线色。
    static let separator = Color.white.opacity(0.08)
}
