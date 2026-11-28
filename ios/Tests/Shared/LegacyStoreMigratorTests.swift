import Foundation
import SwiftData
import XCTest
@testable import QiCompass

/// LegacyStoreMigrator 单元测试(TASK-05 四场景 + TASK-11 两边界 + TASK-20 布局锚定与补救)。
///
/// 迁移函数与补救函数的源/目标目录可注入,全部用临时目录,不依赖真 App Group;
/// 唯独布局锚定测试在模拟器上实测,锁定「迁移目标目录 == `ModelConfiguration.url`
/// 实际落盘目录」(TASK-20 起以 config.url 为准,新旧两种运行时布局都必须成立)
/// ——SwiftData 若再改内部布局,此测试先红。
final class LegacyStoreMigratorTests: XCTestCase {
    private var source: URL!
    private var destination: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-store-tests-\(UUID().uuidString)")
        source = root.appendingPathComponent("src")
        destination = root.appendingPathComponent("dst")
        try FileManager.default.createDirectory(
            at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(
            at: source.deletingLastPathComponent())
        try super.tearDownWithError()
    }

    private func writeStoreFiles(_ names: [String], content: String = "x") throws {
        for name in names {
            try content.write(
                to: source.appendingPathComponent(name),
                atomically: true, encoding: .utf8)
        }
    }

    private func sourceExists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: source.appendingPathComponent(name).path)
    }

    private func destinationExists(_ name: String) -> Bool {
        FileManager.default.fileExists(
            atPath: destination.appendingPathComponent(name).path)
    }

    // MARK: - 场景 1:无旧库 → 无操作

    func test_noSourceIsNoOp() throws {
        let outcome = try LegacyStoreMigrator.migrate(
            sourceDirectory: source, destinationDirectory: destination)

        XCTAssertEqual(outcome.action, .noSource)
        XCTAssertEqual(outcome.movedFiles, [])
        XCTAssertFalse(destinationExists("default.store"))
    }

    // MARK: - 场景 2:有旧库 → 迁移成功(拷贝 → 删源;内容不丢)

    func test_migratesAllPresentFilesAndDeletesSource() throws {
        try writeStoreFiles(["default.store", "default.store-wal"],
                            content: "命盘数据")

        let outcome = try LegacyStoreMigrator.migrate(
            sourceDirectory: source, destinationDirectory: destination)

        XCTAssertEqual(outcome.action, .migrated)
        XCTAssertEqual(Set(outcome.movedFiles),
                       Set(["default.store", "default.store-wal"]))
        XCTAssertTrue(destinationExists("default.store"))
        XCTAssertTrue(destinationExists("default.store-wal"))
        XCTAssertFalse(destinationExists("default.store-shm"))
        // 全部成功后才删源:源里一个都不剩
        XCTAssertFalse(sourceExists("default.store"))
        XCTAssertFalse(sourceExists("default.store-wal"))
        // 内容真搬过去了(不是空文件)
        let migrated = try String(contentsOf: destination
            .appendingPathComponent("default.store"), encoding: .utf8)
        XCTAssertEqual(migrated, "命盘数据")
    }

    // MARK: - 场景 3:目标已有 store → 幂等跳过,源与目标都不动

    func test_destinationExistsKeepsEverythingUntouched() throws {
        try writeStoreFiles(["default.store"])
        try "目标已有库".write(to: destination.appendingPathComponent("default.store"),
                              atomically: true, encoding: .utf8)

        let outcome = try LegacyStoreMigrator.migrate(
            sourceDirectory: source, destinationDirectory: destination)

        XCTAssertEqual(outcome.action, .destinationExists)
        // 源文件保留(不删——删除只属于「迁移成功」分支)
        XCTAssertTrue(sourceExists("default.store"))
        // 目标内容不被覆盖
        let kept = try String(contentsOf: destination
            .appendingPathComponent("default.store"), encoding: .utf8)
        XCTAssertEqual(kept, "目标已有库")
    }

    // MARK: - 场景 4:迁移失败 → 源文件保留 + 目标回滚

    func test_failurePreservesSourceAndRollsBackDestination() throws {
        try writeStoreFiles(["default.store", "default.store-wal"])
        // 注入失败:目标预置一个与 -wal 同名的**目录**,第二个 copyItem
        // 必撞(destination 已存在)→ 触发半途失败路径
        try FileManager.default.createDirectory(
            at: destination.appendingPathComponent("default.store-wal"),
            withIntermediateDirectories: true)

        XCTAssertThrowsError(try LegacyStoreMigrator.migrate(
            sourceDirectory: source, destinationDirectory: destination))

        // 源文件原封不动(绝不删源)
        XCTAssertTrue(sourceExists("default.store"))
        XCTAssertTrue(sourceExists("default.store-wal"))
        // 半途拷进目标的主库被回滚(目标回到无 store,下次启动可完整重试)
        XCTAssertFalse(destinationExists("default.store"))
    }

    // MARK: - 布局锚定(TASK-20 改写):迁移目标 == SwiftData 实际落盘位置

    /// TASK-20:迁移目标不再假设「共享容器根」,而是取 `ModelConfiguration.url`
    /// 所在目录。锚定两件事:
    /// 1. `migrationDestination(for:)` 确实返回 config.url 所在目录(make() 用
    ///    它当迁移目标——契约不被平行实现漂移);
    /// 2. 打开容器后 store 文件**确实出现在 config.url**(新布局落
    ///    `<group>/Library/Application Support/`,旧布局落容器根——两种
    ///    运行时都必须成立,SwiftData 再改布局此测试先红,数据不会丢)。
    @MainActor
    func test_storeLocationPin_migrationTargetMatchesActualLandingDirectory() throws {
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier) != nil else {
            // 模拟器无 entitlement 场景 containerURL 也可用;真拿到 nil
            // 说明环境异常,显式失败而非跳过(布局假设未被验证)
            XCTFail("App Group 容器不可用，布局锚定无法验证")
            return
        }

        let schema = SchemaRegistry.makeSchema()
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .identifier(AppGroup.identifier),
            cloudKitDatabase: .none,
        )

        // 契约 1:迁移目标 == config.url 所在目录
        XCTAssertEqual(
            ModelContainerFactory.migrationDestination(for: config),
            config.url.deletingLastPathComponent(),
            "migrationDestination 必须与 config.url 所在目录同源")

        let preExisting = FileManager.default.fileExists(atPath: config.url.path)
        let container = try ModelContainer(for: schema, configurations: [config])

        // 契约 2:容器初始化即落盘 store 文件(或本就存在)于 config.url
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: config.url.path),
            "SwiftData 实际落盘位置与迁移目标(config.url)不一致，布局假设被打破")

        // 清理:仅删除本次测试新建的文件(既有文件不动——可能是别的
        // 测试/迁移留下的合法库)。容器先释放再删,避免 SQLite 句柄未关。
        if !preExisting {
            container.deleteAllData()
            for name in LegacyStoreMigrator.storeFileNames {
                let url = config.url.deletingLastPathComponent()
                    .appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    // MARK: - TASK-20 §2:groupRoot 错位库补救

    /// groupRoot 有 store、实际落盘目录没有 → 归位(源删除、目标内容完整)。
    func test_remediationMovesMisplacedGroupStoreToActualDirectory() throws {
        try writeStoreFiles(["default.store", "default.store-wal"],
                            content: "TestFlight 命盘")

        let outcome = try ModelContainerFactory.remediateMisplacedGroupStore(
            groupRoot: source, actualStoreDirectory: destination)

        XCTAssertEqual(outcome?.action, .migrated)
        XCTAssertTrue(destinationExists("default.store"))
        XCTAssertTrue(destinationExists("default.store-wal"))
        XCTAssertFalse(sourceExists("default.store"))
        // 内容真搬过去了(不是空文件)
        let moved = try String(contentsOf: destination
            .appendingPathComponent("default.store"), encoding: .utf8)
        XCTAssertEqual(moved, "TestFlight 命盘")
    }

    /// 两处都有 store → 都不动、不自动合并,显式返回 destinationExists。
    func test_remediationKeepsBothStoresWhenActualDirectoryAlreadyHasOne() throws {
        try writeStoreFiles(["default.store"], content: "错位库")
        try "实际库".write(to: destination.appendingPathComponent("default.store"),
                          atomically: true, encoding: .utf8)

        let outcome = try ModelContainerFactory.remediateMisplacedGroupStore(
            groupRoot: source, actualStoreDirectory: destination)

        XCTAssertEqual(outcome?.action, .destinationExists)
        // 两份数据都原封保留,内容不被覆盖
        XCTAssertTrue(sourceExists("default.store"))
        let keptActual = try String(contentsOf: destination
            .appendingPathComponent("default.store"), encoding: .utf8)
        XCTAssertEqual(keptActual, "实际库")
        let keptMisplaced = try String(contentsOf: source
            .appendingPathComponent("default.store"), encoding: .utf8)
        XCTAssertEqual(keptMisplaced, "错位库")
    }

    /// 旧布局运行时(落盘目录 == groupRoot)→ 补救不触发,返回 nil。
    func test_remediationNotTriggeredWhenActualDirectoryIsGroupRoot() throws {
        try writeStoreFiles(["default.store"])

        let outcome = try ModelContainerFactory.remediateMisplacedGroupStore(
            groupRoot: source, actualStoreDirectory: source)

        XCTAssertNil(outcome)
        XCTAssertTrue(sourceExists("default.store"))
    }

    /// groupRoot 没有 store → 无从归位,返回 nil(常态路径:干净设备)。
    func test_remediationNotTriggeredWhenGroupRootHasNoStore() throws {
        let outcome = try ModelContainerFactory.remediateMisplacedGroupStore(
            groupRoot: source, actualStoreDirectory: destination)

        XCTAssertNil(outcome)
    }

    // MARK: - TASK-11(2026-11-02 复核小问题):两处边界

    /// 删源失败注入桩:removeItem 恒抛(其余走真实实现;仅用于
    /// migratedWithLeftovers 路径——拷贝全部成功后才走到删源)。
    private final class RemoveFailingFileManager: FileManager {
        override func removeItem(at URL: URL) throws {
            throw NSError(
                domain: "test.remove-failure", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "注入的删源失败"])
        }
    }

    /// 只有 -wal/-shm、没有主库 → orphanSidecars:不迁移、不删源、
    /// 目标零文件(孤立边车拷过去会被新库当 WAL 解析,行为不定)。
    func test_orphanSidecarsWithoutMainStoreNotMigrated() throws {
        try writeStoreFiles(["default.store-wal", "default.store-shm"])

        let outcome = try LegacyStoreMigrator.migrate(
            sourceDirectory: source, destinationDirectory: destination)

        XCTAssertEqual(outcome.action, .orphanSidecars)
        XCTAssertEqual(outcome.movedFiles, [])
        XCTAssertEqual(outcome.leftoverSourceFiles, [])
        // 源文件原封不动(留人工排查),目标无任何文件
        XCTAssertTrue(sourceExists("default.store-wal"))
        XCTAssertTrue(sourceExists("default.store-shm"))
        XCTAssertFalse(destinationExists("default.store"))
        XCTAssertFalse(destinationExists("default.store-wal"))
        XCTAssertFalse(destinationExists("default.store-shm"))
    }

    /// 拷贝全部成功、删源全失败 → migratedWithLeftovers 不抛:
    /// 目标三文件齐全(数据已安全),残留源文件显式列出。
    func test_deleteSourceFailureReturnsMigratedWithLeftovers() throws {
        try writeStoreFiles(
            ["default.store", "default.store-wal", "default.store-shm"])

        let outcome = try LegacyStoreMigrator.migrate(
            sourceDirectory: source, destinationDirectory: destination,
            fileManager: RemoveFailingFileManager())

        XCTAssertEqual(outcome.action, .migratedWithLeftovers)
        XCTAssertEqual(
            Set(outcome.movedFiles),
            Set(["default.store", "default.store-wal", "default.store-shm"]))
        XCTAssertEqual(
            Set(outcome.leftoverSourceFiles),
            Set(["default.store", "default.store-wal", "default.store-shm"]))
        // 数据已完整落在目标目录
        for name in LegacyStoreMigrator.storeFileNames {
            XCTAssertTrue(destinationExists(name), "目标缺 \(name)")
        }
        // 删除被注入失败 → 源文件仍在
        XCTAssertTrue(sourceExists("default.store"))
    }
}
