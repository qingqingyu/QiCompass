import Foundation
import SQLite3

// MARK: - 城市记录

/// cities 表一行(countries/timezones join 后的展示视图)。
/// Parent 决策: docs/城市搜索设计决策.md Q4(客户端发物理真值)/ Q7(显示命名)。
/// Codable:合盘 TempDraftState 持久化 UserDefaults 需要(S04)。
struct CityRecord: Identifiable, Equatable, Sendable, Codable {
    let geonameId: Int
    /// GeoNames 主名(原文,如 "Xi'an" / "Corvallis")
    let name: String
    /// 中文名;缺失显原文(不强行音译,Q7)
    let nameZh: String?
    let countryCode: String
    /// 州/省显示名(中文优先,英文兜底)
    let admin1Name: String?
    let countryNameZh: String
    let latitude: Double
    let longitude: Double
    /// IANA 时区名(如 "Asia/Shanghai"),后端 zoneinfo 解释
    let timezone: String
    let population: Int
    let isCN: Bool

    var id: Int { geonameId }
    /// 结果行主名:中文优先(Q7)
    var displayName: String { nameZh ?? name }
    /// 结果行副标题:「admin1, 国家」(Cambridge · 马萨诸塞, 美国)
    var subtitle: String {
        if let admin = admin1Name, !admin.isEmpty {
            return "\(admin), \(countryNameZh)"
        }
        return countryNameZh
    }
    /// 表单回显:「城市, 国家」(Q8,只显示这两项)
    var displayLabel: String { "\(displayName), \(countryNameZh)" }
}

// MARK: - 出生地解析(城市 / 手动经度,单一事实源)

/// 出生地物理真值解析(S02 契约字段组;S04 review 抽出)。
///
/// 规则:**手动经度开关优先**——开启时用「设备时区 + 手动经度」(过渡语义,S05
/// 升级「自定义地点:经度+IANA 时区必填」后此分支整体换掉);残留 place(UI 开关
/// ON 时城市选择被隐藏,草稿还会恢复上次城市)不得静默覆盖手动值(错误显式传播)。
/// 深度解析 / onboarding / 合盘快速添加三入口共用,防各自实现漂移
/// (S04 合盘迁移时曾因双份实现漏改开关语义而回归,故收拢)。
enum BirthPlaceResolver {

    /// 解析结果(S02 契约五字段,timezone/longitude 必填,余为存档展示元数据)。
    struct Resolved {
        let timezone: String
        let longitude: Double
        let latitude: Double?
        let placeName: String?
        let geonameId: Int?
    }

    /// 出生地字段解析:城市优先;手动经度开启 → 设备时区 + 手动经度。
    static func resolve(
        place: CityRecord?,
        useManualLongitude: Bool,
        manualLongitude: Double
    ) -> Resolved {
        if !useManualLongitude, let place {
            return Resolved(
                timezone: place.timezone,
                longitude: place.longitude,
                latitude: place.latitude,
                placeName: place.displayName,
                geonameId: place.geonameId
            )
        }
        // 手动经度过渡路径(S05 升级):时区暂用设备时区
        return Resolved(
            timezone: TimeZone.current.identifier,
            longitude: manualLongitude,
            latitude: nil,
            placeName: nil,
            geonameId: nil
        )
    }

    /// 表盘 / 请求共用的 IANA 时区名(手动经度 → nil,调用方回退设备时区)。
    /// WYSIWYG:DatePicker 表盘时区必须与请求 timezone 同源,防「表盘城市时区 /
    /// 请求设备时区」分裂(钟面提取会错时辰)。
    static func effectiveTimezoneName(place: CityRecord?, useManualLongitude: Bool) -> String? {
        useManualLongitude ? nil : place?.timezone
    }
}

// MARK: - 搜索引擎

/// bundle 内 cities.sqlite 只读搜索(S01 产物)。
///
/// 归一化必须与构建侧 `tools/build_city_db.py: normalize_key` **完全同规则**
/// (NFC → NFKD → 去组合变音符 → 小写折叠 → 去非字母数字);两平台实现漂移由
/// S06 golden queries(XCTest 读同一份 JSON)兜底。
///
/// 排序公式(决策 Q6,与文档逐层一致;确定性 tiebreak 用 geonameId):
/// `匹配质量(前缀 > 包含) > 人口 > 输入脚本加权(汉字→中国优先,英文/拼音平等)`
/// 公式末层「最近选择」不参与结果排序,经空态「最近选择」区呈现(设计取舍:
/// 引擎保持纯函数,不耦合 UserDefaults)。
/// 归一化步骤: NFC → NFKD → 去组合变音符 → 只留字母数字 → 小写 + casefold 对齐(ß/ς)。
///
/// 错误显式传播:sqlite 打不开/查询失败 → throw,由 UI 显式报错态,不静默空列表。
final class CitySearchEngine {

    /// 热门城市种子(空态网格;id 来自 cities.sqlite,与 S01 check 脚本抽查同源)。
    static let hotGeonameIds: [Int] = [
        1816670, // 北京
        1796236, // 上海
        1809858, // 广州
        1795565, // 深圳
        1815286, // 成都
        1814906, // 重庆
        1808926, // 杭州
        1791247, // 武汉
        1790630, // 西安
        1799962, // 南京
        1792947, // 天津
        1886760, // 苏州
        1880252, // 新加坡
        1850147, // 东京
        1835848, // 首尔
        1819729, // 香港
        1668341, // 台北
        1821274, // 澳门
        5128581, // 纽约
        5368361, // 洛杉矶
        5391959, // 旧金山
        2643743, // 伦敦
        2988507, // 巴黎
        6167865, // 多伦多
        6173331, // 温哥华
        2147714, // 悉尼
        2158177, // 墨尔本
    ]

    private var db: OpaquePointer?

    // MARK: 生命周期

    /// bundle 内 cities.sqlite 打开(只读)。文件缺失/损坏 → throw(显式)。
    init(bundle: Bundle = .main) throws {
        guard let path = bundle.path(forResource: "cities", ofType: "sqlite") else {
            throw CitySearchError.databaseMissing
        }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw CitySearchError.databaseOpenFailed(code: rc)
        }
        self.db = handle
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: 归一化(与 build_city_db.py 同规则)

    /// NFC → NFKD → 去组合变音符(ü→u)→ 小写 → 只留字母数字(去空格/撇号/连字符)。
    static func normalizeKey(_ raw: String) -> String {
        let nfc = raw.precomposedStringWithCanonicalMapping
        let nfkd = nfc.decomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        for scalar in nfkd.unicodeScalars {
            // 组合变音符(combining class ≠ notReordered)= unicodedata.combining(c) != 0
            if scalar.properties.canonicalCombiningClass != .notReordered { continue }
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
            }
        }
        // Swift lowercased() 与 Python casefold() 的两处分歧需手工对齐:
        // ß→ss(德语 Weinstrasse 类城名)、ς→σ(希腊词尾 sigma)
        let lowered = String(scalars).lowercased()
        return lowered
            .replacingOccurrences(of: "ß", with: "ss")
            .replacingOccurrences(of: "ς", with: "σ")
    }

    /// 查询是否命中「中国优先」加权:含汉字 → 是;纯 ASCII(拼音/英文)→ 否。
    /// 拼音与英文归一化后无法区分,ASCII 输入统一不加权(英文输入者可能
    /// 就是在搜海外城市)。
    static func prefersChina(_ normalizedQuery: String) -> Bool {
        normalizedQuery.unicodeScalars.contains { isCJKIdeograph($0) }
    }

    private static func isCJKIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        // 基本区 CJK 统一表意文字(U+4E00-U+9FFF);扩展区出生地场景极少,
        // 归一化键主要来自简体/繁体名
        (0x4E00...0x9FFF).contains(scalar.value)
    }

    // MARK: 查询

    /// 搜索:前缀匹配优先,不足再补包含匹配;排序见类注释。空查询 → 空结果。
    func search(_ rawQuery: String, limit: Int = 30) throws -> [CityRecord] {
        let key = Self.normalizeKey(rawQuery)
        guard !key.isEmpty else { return [] }

        // 归一化键只含字母数字 → LIKE 通配符(%/_)不可能出现在 key 中,
        // 无需转义(SQL 参数化绑定防注入)
        let prefixRows = try fetch(keyLike: key + "%", limit: 150)
        let prefixIds = Set(prefixRows.map(\.geonameId))
        var ranked = rank(prefixRows, isPrefixMatch: true, query: key)

        if ranked.count < limit {
            let containsRows = try fetch(keyLike: "%" + key + "%", limit: 150)
                .filter { !prefixIds.contains($0.geonameId) }
            ranked += rank(containsRows, isPrefixMatch: false, query: key)
        }

        return ranked.sorted().prefix(limit).map(\.record)
    }

    /// 按 geonameId 批量取记录(热门网格 / 最近选择用);保持入参顺序。
    func records(ids: [Int]) throws -> [CityRecord] {
        guard !ids.isEmpty else { return [] }
        let byId = try fetch(byIds: ids)
        return ids.compactMap { byId[$0] }
    }

    // MARK: 排序(确定性)

    private struct RankedRecord: Comparable {
        let record: CityRecord
        let matchQuality: Int   // 0 = 前缀,1 = 包含
        let chinaBoost: Int     // 0 = 优先,1 = 平常

        static func < (lhs: RankedRecord, rhs: RankedRecord) -> Bool {
            // 层序严格对齐 Q6 公式:匹配质量 > 人口 > 脚本加权 > id(确定性)
            if lhs.matchQuality != rhs.matchQuality { return lhs.matchQuality < rhs.matchQuality }
            if lhs.record.population != rhs.record.population {
                return lhs.record.population > rhs.record.population
            }
            if lhs.chinaBoost != rhs.chinaBoost { return lhs.chinaBoost < rhs.chinaBoost }
            return lhs.record.geonameId < rhs.record.geonameId
        }
    }

    private func rank(_ rows: [CityRecord], isPrefixMatch: Bool, query: String) -> [RankedRecord] {
        let boostChina = Self.prefersChina(query)
        return rows.map { record in
            RankedRecord(
                record: record,
                matchQuality: isPrefixMatch ? 0 : 1,
                chinaBoost: (boostChina && !record.isCN) ? 1 : 0
            )
        }
    }

    // MARK: SQLite 访问(系统 SQLite3,零第三方依赖)

    /// SQLITE_TRANSIENT(让 sqlite 在 bind 后自己拷贝字符串;Swift 侧无此常量)
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static let baseSelect = """
        SELECT c.geoname_id, c.name, c.name_zh, c.country_code, c.admin1_name,
               co.name_zh, c.lat, c.lon, t.iana_name, c.population, c.is_cn
        FROM cities c
        JOIN timezones t ON t.tz_id = c.tz_id
        JOIN countries co ON co.country_code = c.country_code
        """

    private func fetch(keyLike: String, limit: Int) throws -> [CityRecord] {
        // 候选集按人口降序截断:宽前缀(如 new/san 数百命中)下若按 rowid 任意截断,
        // Q6 排序公式的「人口」优先级在内存归并前就失效(高人口城市整行出局)。
        // geoname_id 作次序保证确定性;匹配质量(前缀/包含)分层在内存 rank 完成。
        let sql = """
            \(Self.baseSelect)
            WHERE c.geoname_id IN (
                SELECT k.geoname_id
                FROM search_keys k JOIN cities pc ON pc.geoname_id = k.geoname_id
                WHERE k.key LIKE ?
                ORDER BY pc.population DESC, k.geoname_id ASC
                LIMIT ?
            )
            """
        return try sqliteStep(sql: sql, bind: { stmt in
            sqlite3_bind_text(stmt, 1, keyLike, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(limit))
        })
    }

    private func fetch(byIds ids: [Int]) throws -> [Int: CityRecord] {
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "\(Self.baseSelect) WHERE c.geoname_id IN (\(placeholders))"
        let out: [CityRecord] = try sqliteStep(sql: sql, bind: { stmt in
            for (idx, id) in ids.enumerated() {
                sqlite3_bind_int(stmt, Int32(idx + 1), Int32(id))
            }
        })
        return Dictionary(out.map { ($0.geonameId, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// 通用执行:bind → step 循环 → [CityRecord]。sqlite 错误 → throw(显式)。
    private func sqliteStep(sql: String, bind: (OpaquePointer) -> Void) throws -> [CityRecord] {
        guard let db else { throw CitySearchError.databaseMissing }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CitySearchError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)

        var rows: [CityRecord] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                // 中途错误(非 DONE 非 ROW)显式抛错,不静默返回部分行
                throw CitySearchError.queryFailed(message: String(cString: sqlite3_errmsg(db)))
            }
            func text(_ i: Int32) -> String {
                guard let cstr = sqlite3_column_text(stmt, i) else { return "" }
                return String(cString: cstr)
            }
            let nameZh = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : text(2)
            let admin1 = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : text(4)
            rows.append(CityRecord(
                geonameId: Int(sqlite3_column_int64(stmt, 0)),
                name: text(1),
                nameZh: nameZh,
                countryCode: text(3),
                admin1Name: admin1,
                countryNameZh: text(5),
                latitude: Double(sqlite3_column_int64(stmt, 6)) / 10_000.0,
                longitude: Double(sqlite3_column_int64(stmt, 7)) / 10_000.0,
                timezone: text(8),
                population: Int(sqlite3_column_int64(stmt, 9)),
                isCN: sqlite3_column_int(stmt, 10) == 1
            ))
        }
        return rows
    }
}

// MARK: - 错误

enum CitySearchError: LocalizedError {
    case databaseMissing
    case databaseOpenFailed(code: Int32)
    case queryFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .databaseMissing:
            return String(localized: "city.error.databaseMissing")
        case .databaseOpenFailed(let code):
            return String(localized: "city.error.queryFailed") + " (sqlite \(code))"
        case .queryFailed(let message):
            return String(localized: "city.error.queryFailed") + " (\(message))"
        }
    }
}

// MARK: - 最近选择(UserDefaults,上限 8)

enum CityRecentStore {
    private static let key = "citySearch.recentGeonameIds"
    private static let maxCount = 8

    static func load() -> [Int] {
        UserDefaults.standard.array(forKey: key) as? [Int] ?? []
    }

    static func record(_ geonameId: Int) {
        var ids = load().filter { $0 != geonameId }
        ids.insert(geonameId, at: 0)
        if ids.count > maxCount { ids = Array(ids.prefix(maxCount)) }
        UserDefaults.standard.set(ids, forKey: key)
    }
}
