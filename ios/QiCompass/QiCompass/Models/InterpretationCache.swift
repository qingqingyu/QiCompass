import Foundation
import SwiftData

/// D2:AI 解读缓存(客户端 SwiftData 一级)。
///
/// 缓存键:`(contentHash, module, promptVersion, targetDate, provider, model)`。
/// 每日运势多一维 `targetDate`,其他 module 为 nil。
///
/// 注意:SwiftData 不支持复合 unique index。查询时按完整业务键与身份校验,
/// 不依赖单字段 unique。prompt 改 → promptVersion +1 → 老缓存自然失效。
@Model
final class InterpretationCache {
    @Attribute(.unique) var id: UUID
    var contentHash: String
    var module: String
    var promptVersion: Int
    var targetDate: Date?
    /// 可选仅用于承接旧 SwiftData 行;nil 永不参与新缓存命中。
    var provider: String?
    var model: String?
    var interpretation: String
    var generatedAt: Date

    init(
        id: UUID = UUID(),
        contentHash: String,
        module: String,
        promptVersion: Int,
        targetDate: Date? = nil,
        provider: String? = nil,
        model: String? = nil,
        interpretation: String,
        generatedAt: Date = .now
    ) {
        self.id = id
        self.contentHash = contentHash
        self.module = module
        self.promptVersion = promptVersion
        self.targetDate = targetDate
        self.provider = provider
        self.model = model
        self.interpretation = interpretation
        self.generatedAt = generatedAt
    }
}
