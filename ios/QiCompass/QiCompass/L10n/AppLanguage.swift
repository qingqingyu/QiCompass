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
///   是方案 A 的既定代价)。
/// - **启动冻结生效语言**(L1/F2,2026-10-01 语言切换走查):`current` 不再
///   实时读覆盖值,改读**启动快照**(`launchSnapshotDefaultsKey`,App 启动时
///   由 `freezeLaunchSnapshot()` 写入)——重启前整个 App(术语 chip / 请求
///   header / 缓存键 / 新生成解读)保持旧语言,消除「界面旧语言 + 术语新
///   语言」的同屏混语(违反 D9 三者同语言);重启后快照重写为新选语言。
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

    /// 启动快照在 UserDefaults 的存储 key(L1/F2:与设置项双轨——设置项是
    /// 「用户选了什么」,快照是「本次进程生效什么」,两者在重启前允许不同)。
    static let launchSnapshotDefaultsKey = "appLanguageLaunchSnapshot"

    /// 是否中文语系——供字体 / 生肖 / 宜忌列头等"只区分中文与否"的场景用。
    /// `zh` 与 `zhHant` 均 true;zhHant 在 BaziFont 分流 Kaiti TC(D7)。
    var isChinese: Bool {
        switch self {
        case .zh, .zhHant: return true
        case .en: return false
        }
    }

    /// 语言的 endonym 自称名(**不经 xcstrings 翻译**,跨 UI 语言稳定)。
    /// 语言设置行显示「实际生效语言」用(F6,2026-10-01 Me 页):localized 名
    /// (EN UI 下「简体中文」key 译作 Simplified Chinese)会与界面语言错位,
    /// endonym 是语言自己的名字,永不随 UI 语言变。与 `Override.displayLabel`
    /// (档位名,走 xcstrings)分工不同,勿合并。
    var endonym: String {
        switch self {
        case .zh: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
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

    /// 当前 App 语言(L1/F2:读**启动快照**,不再实时读覆盖值)。
    /// 快照 = 启动时的覆盖档;system 档回落系统语言(`Locale.current` 进程内
    /// 恒定,与冻结语义一致)。D9 约束:全仓取语言的唯一入口(含 `currentWire`)。
    static var current: AppLanguage {
        launchOverride.language ?? systemLanguage
    }

    /// wire 值:缓存键 / `X-QiCompass-Lang` header / SwiftData `language` 字段
    /// 统一用此值。**必须与后端注册键逐字相等**——漂移会导致缓存永不命中
    /// 且不报错(zh / en 两个旧值与改造前逐字相同,老缓存不受影响)。
    static var currentWire: String {
        current.rawValue
    }

    /// 当前生效的显式覆盖(非法/缺失存储值 → nil,防御坏数据回落系统语言)。
    /// 注意:这是「用户现在选了什么」(实时),**不是**生效语言——生效语言看
    /// `launchOverride`。设置行右侧标签 / 重启前 pending 小注消费本值。
    static var overrideValue: Override? {
        guard let raw = UserDefaults.standard.string(forKey: overrideDefaultsKey)
        else { return nil }
        return Override(rawValue: raw)
    }

    /// 启动快照的覆盖档(L1/F2:本次进程冻结的生效档位)。
    /// 快照缺失(单测未走 App.init / 启动早期访问)→ 回落实时值:与冻结前
    /// 行为一致,且冻结前后的解析输入相同,语义无缝。
    /// 坏快照值(非法字符串)同样回落实时值,防御坏数据。
    static var launchOverride: Override {
        guard let raw = UserDefaults.standard.string(forKey: launchSnapshotDefaultsKey),
              let frozen = Override(rawValue: raw)
        else { return overrideValue ?? .system }
        return frozen
    }

    /// 冻结启动快照(QiCompassApp.init 首行调用,**每次启动无条件重写**):
    /// - 启动时:按当前存储值写入 → 本进程的 `current` / `activeOverrideWire` 锚定
    /// - 重启后:重写为新选语言 → 自然切换
    /// - 会话中:设置项变化不影响快照 → 重启前全 App 保持旧语言(半生效消除)
    static func freezeLaunchSnapshot() {
        let resolved = overrideValue ?? .system
        UserDefaults.standard.set(resolved.rawValue, forKey: launchSnapshotDefaultsKey)
    }

    /// 显式覆盖的 wire 值(D6:override ≠ system 时请求层发 `X-QiCompass-Lang`;
    /// 跟随系统时 nil → 不发,后端按 Accept-Language + D4 变体解析)。
    /// L1/F2:读启动快照——header 与 UI/缓存键同源,重启前三者一致;
    /// 请求层只消费此单一入口,不自行读 UserDefaults。
    static var activeOverrideWire: String? {
        launchOverride.language?.rawValue
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
