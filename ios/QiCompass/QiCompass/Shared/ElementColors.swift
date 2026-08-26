import SwiftUI

// MARK: - ElementColors

/// 五行色 token(木火土金水)。
///
/// 后端 `gan_element` / `zhi_element` 返回英文 `metal/wood/water/fire/earth`,
/// 本枚举的 rawValue 与之对齐,直接 `ElementColors(rawValue: dto.ganElement)` 即可取色。
///
/// 色值按传统五行色选取,降饱和 ~40% 压向墨色以适配水墨孤本气质(DESIGN.md §Color 五行色映射):
/// - 木(青绿)/ 火(赤)/ 土(黄)/ 金(白金)/ 水(玄蓝);Dark 各提亮约 20% 亮度保持识别。
enum ElementColors: String {
    case wood
    case fire
    case earth
    case metal
    case water

    /// 五行对应色(Light 降饱和 / Dark 提亮;dyn 复用 BaziTheme.dyn)。未知 rawValue 兜底为 inkMuted(不静默用主强调色,避免与金元素混淆)。
    var color: Color {
        switch self {
        case .wood:  return BaziTheme.dyn(Color(red: 0x46/255, green: 0x6F/255, blue: 0x46/255),
                                          Color(red: 0x6F/255, green: 0x9A/255, blue: 0x6F/255))
        case .fire:  return BaziTheme.dyn(Color(red: 0xA8/255, green: 0x5A/255, blue: 0x42/255),
                                          Color(red: 0xC9/255, green: 0x84/255, blue: 0x6E/255))
        case .earth: return BaziTheme.dyn(Color(red: 0xA6/255, green: 0x80/255, blue: 0x1E/255),
                                          Color(red: 0xC4/255, green: 0xA2/255, blue: 0x55/255))
        case .metal: return BaziTheme.dyn(Color(red: 0x80/255, green: 0x7E/255, blue: 0x76/255),
                                          Color(red: 0xA8/255, green: 0xA6/255, blue: 0x9E/255))
        case .water: return BaziTheme.dyn(Color(red: 0x3C/255, green: 0x55/255, blue: 0x68/255),
                                          Color(red: 0x6E/255, green: 0x8A/255, blue: 0x9E/255))
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
    /// 五行色便捷访问(通过 ElementColors 转发)。未知 key 兜底 inkMuted。
    static func elementColor(_ key: String) -> Color {
        ElementColors.from(key)?.color ?? inkMuted
    }

    /// 吉神 chip 描边色(墨青,DESIGN.md §Color)。
    static let shenshaAuspicious = jade

    /// 凶煞 chip 描边色(暗朱,与吉神墨青区分;水墨孤本下微调)。
    static let shenshaInauspicious = dyn(Color(red: 0x8a/255, green: 0x2b/255, blue: 0x2b/255),
                                         Color(red: 0xb0/255, green: 0x52/255, blue: 0x52/255))

    /// 流年压力警示色(合盘 SyncedFortuneTable 用,降饱和;区别于吉神墨青)。
    static let pressureWarning = dyn(Color(red: 0xb8/255, green: 0x5a/255, blue: 0x50/255),
                                     Color(red: 0xd0/255, green: 0x85/255, blue: 0x79/255))
}
