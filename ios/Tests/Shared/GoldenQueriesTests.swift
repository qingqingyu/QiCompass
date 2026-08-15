import XCTest
@testable import QiCompass

/// S06 golden queries — 搜索质量的单一事实源测试。
///
/// 数据源:`tools/city-data/golden_queries.json`(与 Python 预检器
/// `tools/check_golden_queries.py` 共用同一份;改排序公式必须显式过全表)。
/// 覆盖矩阵:简体前缀/包含、繁体、全拼、拼音首字母、英文、变音符折叠、
/// curated 别名(口语名/区县/历史地名)、同名消歧、县级市。
///
/// 语义:每条 entry 的所有 expect(name, cc) 必须出现在前 top N(默认 1)。
/// 失败时列出期望与实际前 6,便于区分「期望写错」vs「数据缺口(补
/// curated_aliases.tsv 回 S01 管线重建)」——禁止为单条 query 改排序公式特例。
final class GoldenQueriesTests: XCTestCase {

    private struct GoldenQuery {
        let query: String
        let expect: [(name: String, cc: String)]
        let top: Int
        let note: String
    }

    private var engine: CitySearchEngine!
    private var queries: [GoldenQuery] = []

    override func setUpWithError() throws {
        do {
            engine = try CitySearchEngine(bundle: .main)
        } catch {
            throw XCTSkip("cities.sqlite 不可用: \(error.localizedDescription)")
        }
        // golden_queries.json 注册在 QiCompassTests bundle 的 Copy Bundle Resources。
        // 资源缺失 = 守护栏失效(pbxproj 注册回归),必须硬失败而非 XCTSkip 静默跳过
        // (错误显式传播;cities.sqlite 的 skip 是 S03 环境限制惯例,JSON 专属测试 bundle 无此豁免)。
        guard let url = Bundle(for: GoldenQueriesTests.self)
            .url(forResource: "golden_queries", withExtension: "json") else {
            throw NSError(
                domain: "GoldenQueriesTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "golden_queries.json 不在测试 bundle — 检查 pbxproj QiCompassTests Resources 注册"]
            )
        }
        let data = try Data(contentsOf: url)
        struct RawEntry: Decodable {
            let query: String
            let expect: [[String]]
            let top: Int?
            let note: String?
        }
        let raw = try JSONDecoder().decode([RawEntry].self, from: data)
        queries = raw.map {
            GoldenQuery(
                query: $0.query,
                expect: $0.expect.map { (name: $0[0], cc: $0[1]) },
                top: $0.top ?? 1,
                note: $0.note ?? ""
            )
        }
    }

    func testGoldenQueriesAllPass() throws {
        XCTAssertGreaterThanOrEqual(queries.count, 80, "golden queries 应 ≥80 条(验收标准)")
        var failures: [String] = []
        for g in queries {
            let results = try engine.search(g.query)
            let top = results.prefix(g.top).map { ($0.name, $0.countryCode) }
            for e in g.expect {
                if !top.contains(where: { $0.0 == e.name && $0.1 == e.cc }) {
                    let topNames = results.prefix(6).map { "\($0.displayName)(\($0.countryCode))" }
                    failures.append("「\(g.query)」(\(g.note)) 期望 \(e.name)/\(e.cc) 进 top\(g.top),实际前 6:\(topNames)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, """
        golden queries \(failures.count) 条期望未命中:
        \(failures.joined(separator: "\n"))
        修复路径:数据缺口 → 补 tools/city-data/curated_aliases.tsv 后重跑 build_city_db.py;
        期望错误 → 修 golden_queries.json。禁止改排序公式迁就单条用例。
        """)
    }

    /// 排序公式冒烟:前缀 > 包含(同人口量级下)。
    func testRankingPrefixBeatsContains() throws {
        // "北" 前缀命中北京;包含层(如 «湖北» 类不含此例)不得插到前缀命中之前
        let results = try engine.search("北")
        XCTAssertEqual(results.first?.name, "Beijing", "前缀命中+最高人口必须第一")
    }
}
