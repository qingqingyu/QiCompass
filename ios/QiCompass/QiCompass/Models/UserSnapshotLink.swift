import Foundation
import SwiftData

/// 用户与命盘快照的关联(多 snapshot 支持,v1 数据层支持,UI 进 v2)。
///
/// `snapshotHash` 软引用 `ChartSnapshot.contentHash`,不用 `@Relationship`。
@Model
final class UserSnapshotLink {
    @Attribute(.unique) var id: UUID
    var userId: String
    var snapshotHash: String
    var alias: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        userId: String,
        snapshotHash: String,
        alias: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.userId = userId
        self.snapshotHash = snapshotHash
        self.alias = alias
        self.createdAt = createdAt
    }
}
