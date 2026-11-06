import Foundation
import SwiftData

/// App Group 常量(TASK-05,2026-11-01)。
///
/// 持久化库放共享容器的动机:v2 做「今日宜忌」Widget 时免二次迁移;
/// TestFlight 既有用户的**必须**老数据迁移见 `LegacyStoreMigrator`。
///
/// ⚠️ 上线前置(真人步骤,已写入 PR 描述):Apple Developer 后台注册
/// 该 App Group + App ID 能力 + provisioning profile 刷新——未注册前
/// 真机/Archive 签名必失败(对齐 2026-10-28 devicecheck 教训 df027dc:
/// entitlement 与 profile 不匹配 = 签名期失败,不是运行期)。
enum AppGroup {
    static let identifier = "group.com.qicompass.app"
}

/// ModelContainerFactory 的显式错误(错误显式传播:不吞、不用默认值掩盖)。
enum ModelContainerFactoryError: Error {
    /// App Group 容器不可用(entitlement 未生效 / portal 未注册)。
    /// 此时**绝不**静默回落本地库——会分裂成两份数据,比启动失败更糟。
    case appGroupUnavailable(String)
}

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

        // TASK-05:持久化库迁入 App Group 共享容器。先搬老数据再开容器——
        // 容器一旦在共享容器新建空库,老数据就再无自动迁移窗口。
        guard let groupRoot = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier,
        ) else {
            AppLogger.persistence.fault(
                "App Group 容器不可用 identifier=\(AppGroup.identifier, privacy: .public)(entitlement 未生效或 portal 未注册;拒绝静默回落本地库)"
            )
            throw ModelContainerFactoryError.appGroupUnavailable(AppGroup.identifier)
        }
        let outcome = try LegacyStoreMigrator.migrate(
            sourceDirectory: legacyStoreDirectory(),
            destinationDirectory: groupRoot,
        )
        AppLogger.persistence.info(
            "legacy store 迁移完成 action=\(outcome.action.rawValue, privacy: .public)"
        )

        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .identifier(AppGroup.identifier),
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

    /// 老版库的默认 SwiftData 存放目录(App Application Support)。
    static func legacyStoreDirectory() -> URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask,
        )[0]
    }
}

/// 老默认路径 store → App Group 共享容器的迁移(TASK-05)。
///
/// 语义(任务书锁定):
/// - 源目录无任何 store 文件 → 无操作(noSource)
/// - 目标已有 `default.store` → 不迁、不动源文件(destinationExists,
///   覆盖安装竞态/重复启动的幂等路径)
/// - 迁移 = **先全量拷贝、全部成功后才删源**;任一步失败 → 清掉本次
///   拷进目标的文件、源文件原封不动、错误上抛——绝不留半迁库,也绝不
///   静默新建空库把老数据丢掉
///
/// 源/目标目录均可注入,单元测试用临时目录即可,不依赖真 App Group。
enum LegacyStoreMigrator {
    /// SwiftData 默认 store 文件名(主库 + SQLite WAL/SHM 边车)。
    static let storeFileNames = ["default.store", "default.store-wal", "default.store-shm"]

    enum Action: String, Equatable {
        case noSource
        case migrated
        case destinationExists
        /// 源目录只有孤立边车(-wal/-shm)、没有主库(TASK-11):不迁移
        /// 不删除,fault 日志留人工排查——孤立边车被拷过去会被新库当
        /// WAL 解析,行为不定且毁掉排查现场。
        case orphanSidecars
        /// 拷贝全部成功但部分源文件删除失败(TASK-11):数据已安全在
        /// 目标目录,leftoverSourceFiles 列出残留源文件,不阻断启动。
        case migratedWithLeftovers
    }

    struct Outcome: Equatable {
        let action: Action
        /// 实际搬运的文件名(迁移成功才有内容,诊断/日志用)。
        let movedFiles: [String]
        /// 拷贝成功但删源失败的残留源文件(仅 migratedWithLeftovers 非空)。
        let leftoverSourceFiles: [String]
    }

    static func migrate(
        sourceDirectory: URL,
        destinationDirectory: URL,
        fileManager: FileManager = .default,
    ) throws -> Outcome {
        let present = storeFileNames.filter {
            fileManager.fileExists(atPath: sourceDirectory.appendingPathComponent($0).path)
        }
        if present.isEmpty {
            return Outcome(
                action: .noSource, movedFiles: [], leftoverSourceFiles: [])
        }

        // TASK-11 边界 1:没有主库只有孤立边车 → 不迁不删,显式返回 +
        // fault 日志(不是静默忽略);下次启动同样结果,幂等。
        if !present.contains("default.store") {
            AppLogger.persistence.fault(
                "legacy store 源目录无主库仅孤立边车 files=\(present, privacy: .public)——不迁移不删除,留人工排查"
            )
            return Outcome(
                action: .orphanSidecars, movedFiles: [], leftoverSourceFiles: [])
        }

        let destinationStore = destinationDirectory
            .appendingPathComponent("default.store")
        if fileManager.fileExists(atPath: destinationStore.path) {
            AppLogger.persistence.info(
                "legacy store 迁移跳过:目标已有 store(源文件保留不动)"
            )
            return Outcome(
                action: .destinationExists, movedFiles: [], leftoverSourceFiles: [])
        }

        try fileManager.createDirectory(
            at: destinationDirectory, withIntermediateDirectories: true,
        )
        var copied: [URL] = []
        do {
            for name in present {
                let destination = destinationDirectory.appendingPathComponent(name)
                try fileManager.copyItem(
                    at: sourceDirectory.appendingPathComponent(name), to: destination,
                )
                copied.append(destination)
            }
        } catch {
            // 半途失败:目标回到无 store 状态(下次启动可重试完整迁移),
            // 源文件保留,原始错误上抛。清理自身失败不吞——记日志后同样上抛。
            AppLogger.persistence.error(
                "legacy store 迁移失败,回滚本次拷贝 error=\(String(describing: error), privacy: .public)"
            )
            for partial in copied {
                do {
                    try fileManager.removeItem(at: partial)
                } catch {
                    AppLogger.persistence.fault(
                        "legacy store 回滚失败(目标残留 \(partial.lastPathComponent, privacy: .public))请人工检查 \(partial.path, privacy: .private)"
                    )
                }
            }
            throw error
        }

        // 全部拷贝成功,才删除源文件(任务书:迁移成功后才删除旧文件)。
        // TASK-11 边界 2:删源失败不阻断启动——数据已完整在目标目录,
        // 下次启动走 destinationExists 正常打开;残留源文件显式返回 +
        // error 日志(不吞:有结果值、有日志、可人工跟进)。
        var leftovers: [String] = []
        for name in present {
            do {
                try fileManager.removeItem(
                    at: sourceDirectory.appendingPathComponent(name))
            } catch {
                leftovers.append(name)
                AppLogger.persistence.error(
                    "legacy store 删源失败(数据已安全在目标目录)file=\(name, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
            }
        }
        if leftovers.isEmpty {
            AppLogger.persistence.info(
                "legacy store 迁移成功 files=\(present, privacy: .public)"
            )
            return Outcome(
                action: .migrated, movedFiles: present, leftoverSourceFiles: [])
        }
        return Outcome(
            action: .migratedWithLeftovers, movedFiles: present,
            leftoverSourceFiles: leftovers)
    }
}
