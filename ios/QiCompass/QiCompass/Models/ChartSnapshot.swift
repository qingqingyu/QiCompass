import Foundation
import SwiftData

/// D1 核心:内容寻址命盘快照。
///
/// - `contentHash`:内容寻址 ID(**不含** schema_version),同一出生信息永远同一 hash
/// - `schemaVersion`:独立字段,从 1 递增(payload 结构演化时 +1)
/// - `payload`:JSON Data 承载易变结构(pillars/十神/纳音/神煞/喜忌/luck_pillars)
///
/// 关系策略:不放 `@Relationship` 到 UserSnapshotLink,通过 `contentHash` 字符串软引用,
/// 规避 iOS 17.2 `@Relationship` 边界 crash;hash 字段不被 relationship 绑死,schema 演化自由。
@Model
final class ChartSnapshot {
    @Attribute(.unique) var contentHash: String
    var schemaVersion: Int
    var birthSolarTime: Date
    var gender: String
    var cityLongitude: Double
    /// 出生地 IANA 时区(S03 契约;老快照 nil)
    var cityTimezone: String?
    /// 出生地显示名(如「北京」/「San Francisco」;自定义地点 nil)
    var cityName: String?
    /// 出生地纬度(存档用,下游计算不用;老快照 nil)
    var cityLatitude: Double?
    var ziHourRule: String
    var calcRuleSnapshot: Data
    var payload: Data
    var createdAt: Date

    init(
        contentHash: String,
        schemaVersion: Int = 1,
        birthSolarTime: Date,
        gender: String,
        cityLongitude: Double,
        cityTimezone: String? = nil,
        cityName: String? = nil,
        cityLatitude: Double? = nil,
        ziHourRule: String,
        calcRuleSnapshot: Data,
        payload: Data,
        createdAt: Date = .now
    ) {
        self.contentHash = contentHash
        self.schemaVersion = schemaVersion
        self.birthSolarTime = birthSolarTime
        self.gender = gender
        self.cityLongitude = cityLongitude
        self.cityTimezone = cityTimezone
        self.cityName = cityName
        self.cityLatitude = cityLatitude
        self.ziHourRule = ziHourRule
        self.calcRuleSnapshot = calcRuleSnapshot
        self.payload = payload
        self.createdAt = createdAt
    }
}
