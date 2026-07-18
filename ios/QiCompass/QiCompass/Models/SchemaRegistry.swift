import Foundation
import SwiftData

/// 所有 @Model 类型的单一事实源。
/// 新增模型只改这一处 `modelTypes` 数组。
enum SchemaRegistry {
    static let modelTypes: [any PersistentModel.Type] = [
        ChartSnapshot.self,
        UserSnapshotLink.self,
        InterpretationCache.self,
        CompatibilitySnapshot.self,
        DailyFortuneSnapshot.self,
        Entitlement.self,  // M3a 新增:付费授权
    ]

    static func makeSchema() -> Schema {
        Schema(modelTypes)
    }
}
