import Foundation

/// 当前 App 语言(基于系统 locale,v1 阶段无 App 内切换)。
///
/// i18n 决策 10(`i18n-implementation-plan.md` § 2):
/// 客户端查询缓存时需要传 language,从 `Locale.current` 推断 + 规范化。
///
/// 规范化规则(对齐 backend/app/api/language.py resolve_language):
/// - 读取 `Locale.current.language.languageCode`,小写化
/// - 已支持 → 返回该语言("zh" / "en")
/// - 未支持(ja / fr / es / ...)→ fallback 到 defaultLanguage("zh")
///
/// v2 阶段加 App 内语言切换时(`X-QiCompass-Lang` header),
/// 改为 `userPreference ?? systemLanguage`。
enum AppLanguage {
    /// 已支持的语言集合(对齐 backend SUPPORTED_LANGUAGES)。
    /// 加新语言时同步更新此集合 + backend。
    static let supported: Set<String> = ["zh", "en"]

    /// 默认语言(对齐 backend DEFAULT_LANGUAGE)。
    static let defaultLanguage = "zh"

    /// 当前 App 语言(规范化为 "zh" / "en",未注册 locale fallback 到默认)。
    /// 每次访问实时计算(用户可能中途改系统语言)。
    static var current: String {
        let raw = Locale.current.language.languageCode?.identifier.lowercased()
            ?? defaultLanguage
        return supported.contains(raw) ? raw : defaultLanguage
    }
}
