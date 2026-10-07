import Foundation
import SwiftData

/// 合盘快照(内容寻址)。
///
/// `personAHash` / `personBHash` 软引用 `ChartSnapshot.contentHash`,不用 `@Relationship`。
/// `qualitativeAssessment` / `syncedFortune` 为 JSON Data(决策 A2:不给数字分,只给定性描述)。
/// `engineRuleVersion`(2026-10-07):算出本快照的引擎规则版本,与
/// `CompatibilitySnapshotStore.expectedEngineRuleVersion` 比对——失配即快照
/// 按旧规则算出,须重算(可选属性:老快照 nil = 过期;SwiftData 加列自动轻量迁移)。
/// `contextToken`(2026-10-07 P0 收口):后端签发的 compat 族 token,interpret/
/// translate 验签用;老快照 nil(可选属性自动轻量迁移,interpret 403 → 重算恢复)。
@Model
final class CompatibilitySnapshot {
    @Attribute(.unique) var compatibilityHash: String
    var personAHash: String
    var personBHash: String
    var context: String
    var qualitativeAssessment: Data
    var syncedFortune: Data
    var interpretation: String?
    var interpretationProvider: String?
    var interpretationModel: String?
    var engineRuleVersion: Int?
    var contextToken: String?
    var createdAt: Date

    init(
        compatibilityHash: String,
        personAHash: String,
        personBHash: String,
        context: String,
        qualitativeAssessment: Data,
        syncedFortune: Data,
        interpretation: String? = nil,
        interpretationProvider: String? = nil,
        interpretationModel: String? = nil,
        engineRuleVersion: Int? = nil,
        contextToken: String? = nil,
        createdAt: Date = .now
    ) {
        self.compatibilityHash = compatibilityHash
        self.personAHash = personAHash
        self.personBHash = personBHash
        self.context = context
        self.qualitativeAssessment = qualitativeAssessment
        self.syncedFortune = syncedFortune
        self.interpretation = interpretation
        self.interpretationProvider = interpretationProvider
        self.interpretationModel = interpretationModel
        self.engineRuleVersion = engineRuleVersion
        self.contextToken = contextToken
        self.createdAt = createdAt
    }
}
