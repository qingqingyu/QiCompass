import Foundation
import SwiftData

/// D2:AI 解读缓存(客户端 SwiftData 一级)。
///
/// 缓存键:`(contentHash, module, promptVersion, targetDate)` 四元组。
/// 每日运势多一维 `targetDate`,其他 module 为 nil。
///
/// 注意:SwiftData 不支持复合 unique index。查询时按四元组 Predicate 校验,
/// 不依赖单字段 unique。prompt 改 → promptVersion +1 → 老缓存自然失效。
@Model
final class InterpretationCache {
    @Attribute(.unique) var id: UUID
    var contentHash: String
    var module: String
    var promptVersion: String
    var targetDate: Date?
    var interpretation: String
    var generatedAt: Date

    init(
        id: UUID = UUID(),
        contentHash: String,
        module: String,
        promptVersion: String,
        targetDate: Date? = nil,
        interpretation: String,
        generatedAt: Date = .now
    ) {
        self.id = id
        self.contentHash = contentHash
        self.module = module
        self.promptVersion = promptVersion
        self.targetDate = targetDate
        self.interpretation = interpretation
        self.generatedAt = generatedAt
    }
}
