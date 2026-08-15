import Foundation

/// 跨设备同步的命盘数据(PR3.2,对齐后端 backend/app/models/sync.py ChartSyncData)。
///
/// 合并 ChartSnapshot + UserSnapshotLink 字段(同步一次往返,避免 join)。
/// Data 字段序列化:
/// - calcRuleSnapshot(Data)→ Base64 字符串
/// - payload(Data,本身是 JSON)→ UTF-8 字符串
/// - birthSolarTime / createdAt(Date)→ ISO 8601 字符串
struct ChartSyncData: Codable, Sendable, Equatable {
    let contentHash: String
    let alias: String
    let schemaVersion: Int
    let birthSolarTime: String       // ISO 8601
    let gender: String
    let cityLongitude: Double
    /// 出生地 IANA 时区(S03;老数据 nil → 后端可空)
    var cityTimezone: String? = nil
    let ziHourRule: String
    let calcRuleSnapshotBase64: String
    let payloadJson: String
    let createdAt: String            // ISO 8601

    enum CodingKeys: String, CodingKey {
        case contentHash = "content_hash"
        case alias
        case schemaVersion = "schema_version"
        case birthSolarTime = "birth_solar_time"
        case gender
        case cityLongitude = "city_longitude"
        case cityTimezone = "city_timezone"
        case ziHourRule = "zi_hour_rule"
        case calcRuleSnapshotBase64 = "calc_rule_snapshot_base64"
        case payloadJson = "payload_json"
        case createdAt = "created_at"
    }
}

/// POST /api/sync/pull 响应(PR3.2)。
struct SyncPullResponse: Codable, Sendable {
    let userId: String
    let charts: [ChartSyncData]

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case charts
    }
}

/// POST /api/sync/push 请求(PR3.2)。
struct SyncPushRequest: Codable, Sendable {
    let charts: [ChartSyncData]
}

/// POST /api/sync/push 响应(PR3.2)。
struct SyncPushResponse: Codable, Sendable {
    let userId: String
    let upsertedCount: Int
    let totalCount: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case upsertedCount = "upserted_count"
        case totalCount = "total_count"
    }
}

// MARK: - ISO 8601 日期编解码 helper(对齐后端 Python datetime.isoformat)

/// iOS 端 ISO 8601 编解码统一入口(对齐后端 backend datetime.isoformat())。
/// Python isoformat() 含时区偏移(+00:00),iOS ISO8601DateFormatter 默认 [.withInternetDateTime]
/// 解析 RFC 3339(2026-08-09T12:00:00Z)和带偏移的 ISO 8601(2026-08-09T12:00:00+00:00)。
enum SyncDateFormatter {
    /// 解析 ISO 8601 字符串 → Date(支持 Z 后缀和 +HH:MM 偏移)。
    static func parse(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                                   .withColonSeparatorInTime, .withTimeZone]
        return formatter.date(from: iso)
    }

    /// Date → ISO 8601 字符串(RFC 3339 格式,带 Z 后缀)。
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate,
                                   .withColonSeparatorInTime, .withTimeZone]
        return formatter.string(from: date)
    }
}
