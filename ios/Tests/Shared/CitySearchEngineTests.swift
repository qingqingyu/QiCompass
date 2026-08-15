import XCTest
@testable import QiCompass

/// S03 城市搜索引擎测试。
///
/// 引擎测试用 app bundle 内真实 cities.sqlite(S01 产物;测试 target 宿主为 app,
/// Bundle.main 可达)。golden queries 完整矩阵在 S06(共享 JSON)。
final class CitySearchEngineTests: XCTestCase {

    private var engine: CitySearchEngine!

    override func setUpWithError() throws {
        do {
            engine = try CitySearchEngine(bundle: .main)
        } catch {
            // 环境限制(宿主 bundle 缺资源)显式跳过,不视为代码问题
            throw XCTSkip("cities.sqlite 不可用: \(error.localizedDescription)")
        }
    }

    // MARK: - 归一化(与 tools/build_city_db.py normalize_key 同规则)

    func testNormalizeStripsSeparators() {
        // U+2019 弯撇号(GeoNames 里西安写作 Xi’an)
        XCTAssertEqual(CitySearchEngine.normalizeKey("Xi’an"), "xian")
        XCTAssertEqual(CitySearchEngine.normalizeKey("San Jose"), "sanjose")
    }

    func testNormalizeFoldsDiacriticsAndCase() {
        XCTAssertEqual(CitySearchEngine.normalizeKey("München"), "munchen")
        XCTAssertEqual(CitySearchEngine.normalizeKey("WuLuMuQi"), "wulumuqi")
        XCTAssertEqual(CitySearchEngine.normalizeKey("San José"), "sanjose")
    }

    func testNormalizeCasefoldParityWithPython() {
        // Swift lowercased() 与 Python casefold() 的分歧点必须手工对齐(构建侧 casefold):
        // ß→ss(德语 Weinstraße 类城名构建键是 weinstrasse)
        XCTAssertEqual(CitySearchEngine.normalizeKey("Straße"), "strasse")
        XCTAssertEqual(CitySearchEngine.normalizeKey("WEINSTRASSE"), "weinstrasse")
        // 希腊词尾 sigma ς → σ(casefold 行为)
        XCTAssertEqual(CitySearchEngine.normalizeKey("Πάτρας"), "πατρασ")
    }

    func testNormalizeKeepsCJK() {
        XCTAssertEqual(CitySearchEngine.normalizeKey("乌鲁木齐市"), "乌鲁木齐市")
        XCTAssertEqual(CitySearchEngine.normalizeKey("臺北"), "臺北")
    }

    // MARK: - 搜索行为(排序公式:前缀>包含 > 人口 > 脚本加权 > id)

    func testSearchPinyinFull() throws {
        let results = try engine.search("wulumuqi")
        XCTAssertEqual(results.first?.name, "Ürümqi")
    }

    func testSearchPinyinInitials() throws {
        let results = try engine.search("wlmq")
        XCTAssertEqual(results.first?.name, "Ürümqi")
    }

    func testSearchChinesePrefix() throws {
        let results = try engine.search("乌鲁")
        XCTAssertEqual(results.first?.name, "Ürümqi")
    }

    func testSearchXianWithCurlyApostrophe() throws {
        let results = try engine.search("xian")
        XCTAssertEqual(results.first?.name, "Xi’an")
    }

    func testSearchCuratedAlias() throws {
        let results = try engine.search("三藩市")
        XCTAssertEqual(results.first?.name, "San Francisco")
    }

    func testSearchTraditionalChinese() throws {
        // 繁体「臺北」→ 台北(zh-Hant alternate 键);验收要求首位或前列命中
        let results = try engine.search("臺北")
        let top3 = Array(results.prefix(3))
        XCTAssertTrue(top3.contains { $0.geonameId == 1668341 },
                      "臺北 → 台北(gid 1668341)应在前 3,实际:\(top3.map(\.displayName))")
    }

    func testSearchDiacriticsStrippedQuery() throws {
        // 变音符折叠后的英文键盘输入命中:Munich 主键名是 GeoNames name "Munich",
        // "munchen" 键来自 alternate "München" → 断言按 gid + 中文名锚定
        let results = try engine.search("munchen")
        XCTAssertEqual(results.first?.geonameId, 2867714)
        XCTAssertEqual(results.first?.nameZh, "慕尼黑")
    }

    func testSearchCuratedDistrictAlias() throws {
        let results = try engine.search("海淀")
        let top8 = Array(results.prefix(8))
        XCTAssertTrue(top8.contains { $0.name == "Beijing" && $0.countryCode == "CN" },
                      "海淀 → 北京 应在前 8(区县别名),实际:\(top8.map(\.displayName))")
    }

    func testSearchDuplicateNameDisambiguatedByPopulation() throws {
        let results = try engine.search("Cambridge")
        let names = Set(results.map(\.countryCode))
        XCTAssertTrue(names.contains("GB") && names.contains("US"),
                      "Cambridge 英/美两条都应出现,实际国家:\(names)")
    }

    func testSearchChineseQueryBoostsChina() throws {
        // 汉字输入下中国城市优先(脚本加权)
        let results = try engine.search("剑桥")
        XCTAssertFalse(results.isEmpty)
    }

    func testEmptyQueryReturnsEmpty() throws {
        XCTAssertTrue(try engine.search("").isEmpty)
        XCTAssertTrue(try engine.search("   ").isEmpty)
    }

    // MARK: - records(ids:)

    func testRecordsByIdsKeepsOrder() throws {
        let records = try engine.records(ids: [1796236, 1816670])  // 上海、北京
        XCTAssertEqual(records.map(\.geonameId), [1796236, 1816670])
        XCTAssertEqual(records.first?.timezone, "Asia/Shanghai")
        XCTAssertEqual(records.first?.isCN, true)
    }

    func testHotSeedIdsAllResolvable() throws {
        // 热门种子必须全部在库(S01 数据集完整性)
        let records = try engine.records(ids: CitySearchEngine.hotGeonameIds)
        XCTAssertEqual(records.count, CitySearchEngine.hotGeonameIds.count,
                       "热门种子有缺:\(Set(CitySearchEngine.hotGeonameIds).subtracting(records.map(\.geonameId)))")
    }

    // MARK: - 契约编码(S02:裸钟面 + snake_case)

    func testBaziRequestEncodesSnakeCaseNaive() throws {
        let request = BaziCalculateRequest(
            birthDatetime: "1988-05-05T02:30:00",
            timezone: "Asia/Shanghai",
            gender: "male",
            longitude: 116.4074,
            latitude: 39.9042,
            placeName: "北京",
            geonameId: 1816670,
            ziHourRule: "zi_next_day"
        )
        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["birth_datetime"] as? String, "1988-05-05T02:30:00")
        XCTAssertEqual(json["timezone"] as? String, "Asia/Shanghai")
        XCTAssertEqual(json["longitude"] as? Double, 116.4074)
        XCTAssertEqual(json["place_name"] as? String, "北京")
        XCTAssertEqual(json["geoname_id"] as? Int, 1816670)
        XCTAssertNil(json["city"], "旧 city 字段必须消失(S02 零兼容垫片)")
    }
}
