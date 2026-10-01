import XCTest
@testable import QiCompass

/// AppLanguage 覆盖/变体归一测试(S4,D6/D9;i18n-zh-hant-plan.md)+ 启动冻结
/// (L1/F2,2026-10-01 语言切换走查)。
///
/// 覆盖:
/// - override 优先级:显式覆盖 > 系统语言;system 档回落系统
/// - activeOverrideWire:system/坏值 → nil(请求层不发 X-QiCompass-Lang),
///   显式档 → wire 值与后端注册键逐字相等
/// - 启动冻结:快照存在 → current/activeOverrideWire 读快照,会话中改
///   覆盖值不影响生效语言;重新 freeze(= 重启)才切换;快照缺失回落实时
/// - D4 变体归一(normalizeZhVariant):script 优先于 region 矩阵
final class AppLanguageTests: XCTestCase {

    override func setUp() {
        // 快照 key 必须先清:测试宿主(App)init 会 freezeLaunchSnapshot 写入
        // 进程启动档位,不清会让「快照缺失回落实时」类用例读到宿主的冻结值
        UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppLanguage.overrideDefaultsKey)
        super.setUp()
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppLanguage.launchSnapshotDefaultsKey)
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

    // MARK: - 启动冻结生效语言(L1/F2,2026-10-01)

    func testFreezePinsLanguageUntilRestart() {
        // 启动时覆盖 en → 冻结;会话中改选 zh-hant → 生效语言仍是 en(半生效消除)
        UserDefaults.standard.set("en", forKey: AppLanguage.overrideDefaultsKey)
        AppLanguage.freezeLaunchSnapshot()
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        XCTAssertEqual(AppLanguage.current, .en)
        XCTAssertEqual(AppLanguage.currentWire, "en")
        XCTAssertEqual(AppLanguage.activeOverrideWire, "en")
        // 模拟重启:重新 freeze → 切到新选语言
        AppLanguage.freezeLaunchSnapshot()
        XCTAssertEqual(AppLanguage.current, .zhHant)
        XCTAssertEqual(AppLanguage.activeOverrideWire, "zh-hant")
    }

    func testFreezeSystemSendsNoHeaderAndFollowsSystem() {
        // 启动时跟随系统 → 冻结 system 档;header 不发,生效语言=系统语言
        UserDefaults.standard.set("system", forKey: AppLanguage.overrideDefaultsKey)
        AppLanguage.freezeLaunchSnapshot()
        XCTAssertNil(AppLanguage.activeOverrideWire)
        XCTAssertTrue(AppLanguage.allCases.contains(AppLanguage.current))
        // 会话中改显式覆盖也不影响(直到重启)
        UserDefaults.standard.set("en", forKey: AppLanguage.overrideDefaultsKey)
        XCTAssertNil(AppLanguage.activeOverrideWire)
    }

    func testSnapshotMissingFallsBackToLiveResolve() {
        // 快照缺失(未走 App.init 的调用时序/单测环境)→ 回落实时解析,
        // 与冻结前行为一致(存量测试与旧客户端时序的兼容锚点)
        UserDefaults.standard.set("zh-hant", forKey: AppLanguage.overrideDefaultsKey)
        XCTAssertEqual(AppLanguage.current, .zhHant)
        XCTAssertEqual(AppLanguage.activeOverrideWire, "zh-hant")
    }

    func testGarbageSnapshotFallsBackToLiveResolve() {
        // 坏快照值防御:不 crash、不产出未注册档位,回落实时值
        UserDefaults.standard.set("klingon", forKey: AppLanguage.launchSnapshotDefaultsKey)
        UserDefaults.standard.set("en", forKey: AppLanguage.overrideDefaultsKey)
        XCTAssertEqual(AppLanguage.current, .en)
        XCTAssertEqual(AppLanguage.activeOverrideWire, "en")
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
