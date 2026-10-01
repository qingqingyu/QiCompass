import Foundation

/// 当前 App 语言 = 显式覆盖(设置项)?? 系统语言(D6/D9)。
///
/// i18n 决策 10(`i18n-implementation-plan.md` § 2)+ 繁体方案 D3/D4/D6/D9
/// (`i18n-zh-hant-plan.md`):
/// - **类型化枚举**(2026-09-21 T0):加语言 = 加 case,编译器强制全仓每个
///   语言分支显式走一遍——此前对字符串字面量的相等比较在加 zh-hant 时
///   会静默跑错(字体掉英文衬线 / 生肖出 Dragon)。
/// - **wire 格式全小写**(D3):`zh` / `zh-hant` / `en`,与后端注册键
///   (`TERM_TRANSLATIONS`)、`resolve_language` 归一结果逐字相等;
///   缓存键 / header / SwiftData language 字段统一走 `currentWire`。
/// - **单一语言开关**(D9,2026-10-01):UI 文案、命盘术语(`BaziTerms`)、
///   三模块 AI 解读语言共用本枚举——**全仓只允许经 `AppLanguage.current` /
///   `currentWire` 取语言,禁止新增第二个语言来源**(拆开会同屏混语:
///   「Wealth Rival」标签配「劫財」正文)。
/// - **App 内切换**(D6,S4):`Override.system/zh/zhHant/en` 存
///   `UserDefaults`(key = `overrideDefaultsKey`),UI 层同时镜像写
///   `AppleLanguages` 并引导重启(String Catalog 走 Bundle 解析,重启生效
///   是方案 A 的既定代价);`current` 读覆盖值即时生效(解读语言/缓存键
///   不等重启——切换后新生成的解读已是目标语言)。
///
/// zh 变体归一(D4,对齐 backend `resolve_language` 的 `_matchLanguage`;
/// **S4 起接回**(止血期 2026-09-23~10-01 已随 S2 后端三语齐备而解除):
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

    // MARK: - App 内语言覆盖(D6)

    /// 语言设置项的四档值(存储字符串 = rawValue)。
    /// `system` = 跟随系统(不发 `X-QiCompass-Lang`,让 Accept-Language 说话);
    /// 其余三档为显式覆盖(UI + 解读 + 缓存键 + header 全链路一致,D9)。
    enum Override: String, CaseIterable {
        case system = "system"
        case zh
        case zhHant = "zh-hant"
        case en

        /// 覆盖档对应的具体语言;`system` → nil(回落系统语言)。
        var language: AppLanguage? {
            self == .system ? nil : AppLanguage(rawValue: rawValue)
        }

        /// 设置行右侧的当前值短标(如「跟随系统 ›」),文案走 xcstrings。
        var displayLabel: String {
            switch self {
            case .system: return String(localized: "跟随系统")
            case .zh: return String(localized: "简体中文")
            case .zhHant: return String(localized: "繁體中文")
            case .en: return String(localized: "English")
            }
        }
    }

    /// 覆盖值在 UserDefaults 的存储 key(D6:设置项与读取方共用,勿改字面量)。
    static let overrideDefaultsKey = "appLanguageOverride"

    /// 是否中文语系——供字体 / 生肖 / 宜忌列头等"只区分中文与否"的场景用。
    /// `zh` 与 `zhHant` 均 true;zhHant 在 BaziFont 分流 Kaiti TC(D7)。
    var isChinese: Bool {
        switch self {
        case .zh, .zhHant: return true
        case .en: return false
        }
    }

    /// wire 值的语言显示名(翻译提示条等场景;与 Override.displayLabel 同一套
    /// 词典 key)。未识别值原样透出(防御坏数据,不 crash)。
    static func displayName(forWire wire: String) -> String {
        switch wire {
        case "zh": return String(localized: "简体中文")
        case "zh-hant": return String(localized: "繁體中文")
        case "en": return String(localized: "English")
        default: return wire
        }
    }

    /// 当前 App 语言(每次访问实时计算):显式覆盖优先,否则系统语言。
    /// D9 约束:全仓取语言的唯一入口(含 `currentWire`)。
    static var current: AppLanguage {
        overrideValue?.language ?? systemLanguage
    }

    /// wire 值:缓存键 / `X-QiCompass-Lang` header / SwiftData `language` 字段
    /// 统一用此值。**必须与后端注册键逐字相等**——漂移会导致缓存永不命中
    /// 且不报错(zh / en 两个旧值与改造前逐字相同,老缓存不受影响)。
    static var currentWire: String {
        current.rawValue
    }

    /// 当前生效的显式覆盖(非法/缺失存储值 → nil,防御坏数据回落系统语言)。
    static var overrideValue: Override? {
        guard let raw = UserDefaults.standard.string(forKey: overrideDefaultsKey)
        else { return nil }
        return Override(rawValue: raw)
    }

    /// 显式覆盖的 wire 值(D6:override ≠ system 时请求层发 `X-QiCompass-Lang`;
    /// 跟随系统时 nil → 不发,后端按 Accept-Language + D4 变体解析)。
    /// 请求层只消费此单一入口,不自行读 UserDefaults。
    static var activeOverrideWire: String? {
        overrideValue?.language?.rawValue
    }

    /// 系统语言解析(Locale.current → D4 归一,未注册 fallback `.zh`)。
    /// AppleLanguages 被设置项镜像覆写后,重启的 Locale.current 即反映所选
    /// 语言(与 appLanguageOverride 双轨一致;current 以本轨为准兜底)。
    private static var systemLanguage: AppLanguage {
        let language = Locale.current.language
        guard let code = language.languageCode?.identifier.lowercased() else {
            return .zh
        }
        switch code {
        case "zh":
            // S4(2026-10-01)接回 D4 变体归一——S2 已注册后端 zh-hant
            // (TERM_TRANSLATIONS / prompts/zh-hant / resolve_language),
            // xcstrings zh-Hant 列已回列(S3),止血条件解除。
            return normalizeZhVariant(language)
        case "en":
            return .en
        default:
            return .zh
        }
    }

    /// D4 zh 变体归一(script 优先于 region)。
    /// script 显式存在时按 script 定简体(zh-Hans-TW 归简体,
    /// zh-Hant-CN 归繁体)。Foundation 对 zh 会补默认 script(裸 zh → Hans)
    /// 并按 region 推断(zh-TW → Hant),因此正常路径都在此二分命中;
    /// script 罕见缺位时才看 region。
    static func normalizeZhVariant(_ language: Locale.Language) -> AppLanguage {
        if let script = language.script?.identifier {
            return script == "Hant" ? .zhHant : .zh
        }
        if let region = language.region?.identifier,
           ["TW", "HK", "MO"].contains(region) {
            return .zhHant
        }
        return .zh
    }
}
