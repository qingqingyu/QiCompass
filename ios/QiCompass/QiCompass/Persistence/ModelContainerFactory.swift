import Foundation
import SwiftData

/// 构造 ModelContainer。
///
/// D1 决策:**不用** VersionedSchema / SchemaMigrationPlan。核心 schema 几乎不变,
/// 易变结构靠 `payload` JSON Data 承载 + lazy 重算。SwiftData 默认轻量迁移处理字段增删。
///
/// 错误显式传播:构造失败直接 throw,不吞不返回默认值。
enum ModelContainerFactory {
    static func make() throws -> ModelContainer {
        // 规则 2:函数入口日志。ModelContainer 是启动关键,失败会让 App 整体不可用。
        AppLogger.persistence.info("ModelContainerFactory.make 开始")
        let schema = SchemaRegistry.makeSchema()
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            cloudKitDatabase: .none,
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            AppLogger.persistence.info("ModelContainerFactory.make 完成")
            return container
        } catch {
            AppLogger.persistence.error("ModelContainer 构造失败: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// 仅供 Debug 验证 / 测试用:内存容器,不污染磁盘。
    static func makeInMemory() throws -> ModelContainer {
        AppLogger.persistence.info("ModelContainerFactory.makeInMemory 开始")
        let schema = SchemaRegistry.makeSchema()
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none,
        )
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            AppLogger.persistence.info("ModelContainerFactory.makeInMemory 完成")
            return container
        } catch {
            AppLogger.persistence.error("ModelContainer(in-memory)构造失败: \(String(describing: error), privacy: .public)")
            throw error
        }
    }
}
