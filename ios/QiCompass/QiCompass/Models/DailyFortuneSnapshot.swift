import Foundation
import SwiftData

/// 每日运势快照(按需生成 + 日粒度缓存)。
///
/// `chartHash` 软引用 `ChartSnapshot.contentHash`,不用 `@Relationship`。
/// `hourPillars` 为 JSON Data(12 时辰条)。
/// `tomorrowPreview` 为 JSON Data(TomorrowPreviewDTO)。
///
/// 缓存策略(决策 §1.B):
/// - `cachedUntil` = target_date 本地 23:59:59 + 1s(日粒度,跨日立即重算)
/// - 24h AI 缓存语义由 `InterpretationCache`(generatedAt + 24h)独立保证,
///   两层职责分离
@Model
final class DailyFortuneSnapshot {
    @Attribute(.unique) var id: UUID
    var chartHash: String
    var targetDate: Date
    var dayPillar: String
    var dayRelation: String
    var dayChong: String?
    var dayChongTargets: [String]
    var hourPillars: Data
    var lunarDate: String
    var huangliYi: [String]
    var huangliJi: [String]
    var tomorrowPreview: Data
    var interpretation: String
    var interpretationProvider: String?
    var interpretationModel: String?
    var generatedAt: Date
    var cachedUntil: Date

    init(
        id: UUID = UUID(),
        chartHash: String,
        targetDate: Date,
        dayPillar: String,
        dayRelation: String,
        dayChong: String? = nil,
        dayChongTargets: [String] = [],
        hourPillars: Data,
        lunarDate: String = "",
        huangliYi: [String],
        huangliJi: [String],
        tomorrowPreview: Data = Data(),
        interpretation: String = "",
        interpretationProvider: String? = nil,
        interpretationModel: String? = nil,
        generatedAt: Date = .now,
        cachedUntil: Date
    ) {
        self.id = id
        self.chartHash = chartHash
        self.targetDate = targetDate
        self.dayPillar = dayPillar
        self.dayRelation = dayRelation
        self.dayChong = dayChong
        self.dayChongTargets = dayChongTargets
        self.hourPillars = hourPillars
        self.lunarDate = lunarDate
        self.huangliYi = huangliYi
        self.huangliJi = huangliJi
        self.tomorrowPreview = tomorrowPreview
        self.interpretation = interpretation
        self.interpretationProvider = interpretationProvider
        self.interpretationModel = interpretationModel
        self.generatedAt = generatedAt
        self.cachedUntil = cachedUntil
    }
}
