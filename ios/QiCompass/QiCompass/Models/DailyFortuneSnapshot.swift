import Foundation
import SwiftData

/// 每日运势快照(按需生成 + 24h 缓存)。
///
/// `chartHash` 软引用 `ChartSnapshot.contentHash`,不用 `@Relationship`。
/// `hourPillars` 为 JSON Data(12 时辰条)。
/// `cachedUntil` 为 24h 过期时间,过期后重新生成。
@Model
final class DailyFortuneSnapshot {
    @Attribute(.unique) var id: UUID
    var chartHash: String
    var targetDate: Date
    var dayPillar: String
    var dayRelation: String
    var hourPillars: Data
    var huangliYi: [String]
    var huangliJi: [String]
    var interpretation: String
    var cachedUntil: Date

    init(
        id: UUID = UUID(),
        chartHash: String,
        targetDate: Date,
        dayPillar: String,
        dayRelation: String,
        hourPillars: Data,
        huangliYi: [String],
        huangliJi: [String],
        interpretation: String,
        cachedUntil: Date
    ) {
        self.id = id
        self.chartHash = chartHash
        self.targetDate = targetDate
        self.dayPillar = dayPillar
        self.dayRelation = dayRelation
        self.hourPillars = hourPillars
        self.huangliYi = huangliYi
        self.huangliJi = huangliJi
        self.interpretation = interpretation
        self.cachedUntil = cachedUntil
    }
}
