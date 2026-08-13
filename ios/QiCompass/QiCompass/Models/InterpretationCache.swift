import Foundation
import SwiftData

/// D2:AI 解读缓存(客户端 SwiftData 一级)。
///
/// 缓存键:`(contentHash, module, promptVersion, language, targetDate, provider, model)`。
/// 每日运势多一维 `targetDate`,其他 module 为 nil。
///
/// i18n 决策 3(i18n-implementation-plan.md § 2):新增 `language` 维度。
/// 同 content_hash + 不同 language = 独立缓存条目(避免英文用户拿到中文缓存)。
/// 字段类型:`String?`(optional)而非 `String`(required),原因:
/// - 老缓存行没有 language 字段,SwiftData 加 required 字段会破坏反序列化
/// - nil 视为 "zh"(Q13 决策:v1 之前的所有缓存都是中文,这是正确的回填值)
/// - 符合 D1 决策"不用 VersionedSchema / SchemaMigrationPlan,演化靠 lazy 重算"
///
/// 注意:SwiftData 不支持复合 unique index。查询时按完整业务键与身份校验,
/// 不依赖单字段 unique。prompt 改 → promptVersion +1 → 老缓存自然失效。
@Model
final class InterpretationCache {
    @Attribute(.unique) var id: UUID
    var contentHash: String
    var module: String
    var promptVersion: Int
    /// i18n 维度:规范化的语言代码("zh" / "en")。
    /// nil = 老缓存(视为 "zh",对齐 Q13 决策);新缓存必填。
    var language: String?
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
        language: String? = nil,
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
        self.language = language
        self.targetDate = targetDate
        self.provider = provider
        self.model = model
        self.interpretation = interpretation
        self.generatedAt = generatedAt
    }
}
