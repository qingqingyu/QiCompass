import XCTest
@testable import QiCompass

/// AppLanguage 覆盖/变体归一测试(S4,D6/D9;i18n-zh-hant-plan.md)。
///
/// 覆盖:
/// - override 优先级:显式覆盖 > 系统语言;system 档回落系统
/// - activeOverrideWire:system/坏值 → nil(请求层不发 X-QiCompass-Lang),
///   显式档 → wire 值与后端注册键逐字相等
/// - D4 变体归一(normalizeZhVariant):script 优先于 region 矩阵
final class AppLanguageTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
        super.tearDown()
    }

    // MARK: - override 优先级(D6)

    func testOverrideBeatsSystemLanguage() {
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        XCTAssertEqual(AppLanguage.current, .zhHant)
        XCTAssertEqual(AppLanguage.currentWire, "zh-hant")
    }

    func testSystemOverrideFallsBackToSystemLanguage() {
        UserDefaults.standard.set("system", forKey: AppLanguage.overrideDefaultsKey)
        XCTAssertNil(AppLanguage.activeOverrideWire)  // 跟随系统:不发 header
        // current == systemLanguage(测试环境语言不定,只断言是合法 case)
        XCTAssertTrue(AppLanguage.allCases.contains(AppLanguage.current))
    }

    func testNoOverrideFallsBackToSystemLanguage() {
        XCTAssertNil(AppLanguage.overrideValue)
        XCTAssertNil(AppLanguage.activeOverrideWire)
    }

    func testGarbageOverrideValueIgnored() {
        // 坏存储值防御:不 crash、不产出未注册语言,回落系统
        UserDefaults.standard.set("klingon", forKey: AppLanguage.overrideDefaultsKey)
        XCTAssertNil(AppLanguage.overrideValue)
        XCTAssertNil(AppLanguage.activeOverrideWire)
        XCTAssertTrue(AppLanguage.allCases.contains(AppLanguage.current))
    }

    // MARK: - activeOverrideWire 与后端注册键逐字相等(D3)

    func testOverrideWireValuesMatchBackendRegistry() {
        for (raw, expectedWire) in [
            ("zh", "zh"), ("zh-hant", "zh-hant"), ("en", "en"),
        ] {
            UserDefaults.standard.set(raw, forKey: AppLanguage.overrideDefaultsKey)
            XCTAssertEqual(AppLanguage.activeOverrideWire, expectedWire, raw)
        }
    }

    // MARK: - D4 zh 变体归一(script 优先于 region)

    func testNormalizeZhVariantMatrix() {
        func lang(_ id: String) -> Locale.Language { Locale.Language(identifier: id) }
        // 繁体侧
        XCTAssertEqual(AppLanguage.normalizeZhVariant(lang("zh-Hant")), .zhHant)
        XCTAssertEqual(AppLanguage.normalizeZhVariant(lang("zh-Hant-TW")), .zhHant)
        XCTAssertEqual(AppLanguage.normalizeZhVariant(lang("zh-Hant-HK")), .zhHant)
        XCTAssertEqual(AppLanguage.normalizeZhVariant(lang("zh-TW")), .zhHant)
        XCTAssertEqual(AppLanguage.normalizeZhVariant(lang("zh-HK")), .zhHant)
        XCTAssertEqual(AppLanguage.normalizeZhVariant(lang("zh-MO")), .zhHant)
        // 简体侧(script 显式压过 region;裸 zh/未知 region 不猜繁体)
        XCTAssertEqual(AppLanguage.normalizeZhVariant(lang("zh-Hans")), .zh)
        XCTAssertEqual(AppLanguage.normalizeZhVariant(lang("zh-Hans-TW")), .zh)
        XCTAssertEqual(AppLanguage.normalizeZhVariant(lang("zh-CN")), .zh)
        XCTAssertEqual(AppLanguage.normalizeZhVariant(lang("zh-SG")), .zh)
        XCTAssertEqual(AppLanguage.normalizeZhVariant(lang("zh")), .zh)
    }

    // MARK: - Override 档位(D6 四档)

    func testOverrideCasesAndLanguageMapping() {
        XCTAssertEqual(AppLanguage.Override.allCases.map(\.rawValue),
                       ["system", "zh", "zh-hant", "en"])
        XCTAssertNil(AppLanguage.Override.system.language)
        XCTAssertEqual(AppLanguage.Override.zh.language, .zh)
        XCTAssertEqual(AppLanguage.Override.zhHant.language, .zhHant)
        XCTAssertEqual(AppLanguage.Override.en.language, .en)
    }
}
