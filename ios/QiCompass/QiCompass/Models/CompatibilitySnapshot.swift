import Foundation
import SwiftData

/// 合盘快照(内容寻址)。
///
/// `personAHash` / `personBHash` 软引用 `ChartSnapshot.contentHash`,不用 `@Relationship`。
/// `qualitativeAssessment` / `syncedFortune` 为 JSON Data(决策 A2:不给数字分,只给定性描述)。
@Model
final class CompatibilitySnapshot {
    @Attribute(.unique) var compatibilityHash: String
    var personAHash: String
    var personBHash: String
    var context: String
    var qualitativeAssessment: Data
    var syncedFortune: Data
    var interpretation: String?
    var createdAt: Date

    init(
        compatibilityHash: String,
        personAHash: String,
        personBHash: String,
        context: String,
        qualitativeAssessment: Data,
        syncedFortune: Data,
        interpretation: String? = nil,
        createdAt: Date = .now
    ) {
        self.compatibilityHash = compatibilityHash
        self.personAHash = personAHash
        self.personBHash = personBHash
        self.context = context
        self.qualitativeAssessment = qualitativeAssessment
        self.syncedFortune = syncedFortune
        self.interpretation = interpretation
        self.createdAt = createdAt
    }
}
