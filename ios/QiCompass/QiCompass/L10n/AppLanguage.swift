import Foundation

/// 当前 App 语言(基于系统 locale,v1 阶段无 App 内切换)。
///
/// i18n 决策 10(`i18n-implementation-plan.md` § 2)+ 繁体方案 D3/D4
/// (`i18n-zh-hant-plan.md`):
/// - **类型化枚举**(2026-09-21 T0):加语言 = 加 case,编译器强制全仓每个
///   语言分支显式走一遍——此前对字符串字面量的相等比较在加 zh-hant 时
///   会静默跑错(字体掉英文衬线 / 生肖出 Dragon)。
/// - **wire 格式全小写**(D3):`zh` / `zh-hant` / `en`,与后端注册键
///   (`TERM_TRANSLATIONS`)、`resolve_language` 归一结果逐字相等;
///   缓存键 / header / SwiftData language 字段统一走 `currentWire`。
///
/// zh 变体归一(D4,对齐 backend `resolve_language` 改造后的语义):
/// - `zh-Hant` / `zh-TW` / `zh-HK` / `zh-MO`(及 `zh-Hant-TW` 组合)→ `.zhHant`
/// - `zh-Hans` / `zh-CN` / `zh-SG` / 裸 `zh` → `.zh`(script 优先于 region:
///   `zh-Hans-TW` 归简体,`zh-Hant-CN` 归繁体)
/// - `en` → `.en`;其余未注册(ja / fr / …)→ fallback `.zh`(默认)
enum AppLanguage: String, CaseIterable {
    /// 简体中文(wire `zh`)。
    case zh = "zh"
    /// 繁体中文(wire `zh-hant`,全小写 D3)。
    case zhHant = "zh-hant"
    /// 英文(wire `en`)。
    case en = "en"

    /// 是否中文语系——供字体 / 生肖 / 宜忌列头等"只区分中文与否"的场景用。
    /// `zh` 与 `zhHant` 均 true;T5 将在 BaziFont 为 `zhHant` 分流 Kaiti TC。
    var isChinese: Bool {
        switch self {
        case .zh, .zhHant: return true
        case .en: return false
        }
    }

    /// 当前 App 语言(每次访问实时计算,用户可能中途改系统语言)。
    /// T5(App 内语言切换)在此接入:`override ?? systemLanguage`。
    static var current: AppLanguage {
        systemLanguage
    }

    /// wire 值:缓存键 / `X-QiCompass-Lang` header / SwiftData `language` 字段
    /// 统一用此值。**必须与后端注册键逐字相等**——漂移会导致缓存永不命中
    /// 且不报错(zh / en 两个旧值与改造前逐字相同,老缓存不受影响)。
    static var currentWire: String {
        current.rawValue
    }

    /// 系统语言解析(Locale.current → D4 归一,未注册 fallback `.zh`)。
    private static var systemLanguage: AppLanguage {
        let language = Locale.current.language
        guard let code = language.languageCode?.identifier.lowercased() else {
            return .zh
        }
        switch code {
        case "zh":
            // D4:script 优先于 region——script 显式存在时按 script 定简繁
            // (zh-Hans-TW 归简体,zh-Hant-CN 归繁体)。Foundation 对 zh 会
            // 补默认 script(裸 zh → Hans)并按 region 推断(zh-TW → Hant),
            // 因此正常路径都在此二分命中;script 罕见缺位时才看 region。
            if let script = language.script?.identifier {
                return script == "Hant" ? .zhHant : .zh
            }
            if let region = language.region?.identifier,
               ["TW", "HK", "MO"].contains(region) {
                return .zhHant
            }
            return .zh
        case "en":
            return .en
        default:
            return .zh
        }
    }
}
