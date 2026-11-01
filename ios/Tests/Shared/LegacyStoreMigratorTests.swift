import Foundation
import SwiftData
import XCTest
@testable import QiCompass

/// LegacyStoreMigrator 单元测试(TASK-05,任务书四场景 + 布局锚定)。
///
/// 迁移函数源/目标目录可注入,全部用临时目录,不依赖真 App Group;
/// 唯独布局锚定测试(共享容器根 = default.store 所在地)在模拟器上
/// 实测,锁定「迁移目标目录 == SwiftData groupContainer 实际落盘目录」
/// 这一假设——SwiftData 若改内部布局,此测试先红。
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

    // MARK: - 布局锚定:groupContainer 落盘位置 == 迁移目标目录

    /// 实测 SwiftData `groupContainer: .identifier(...)` 把 default.store
    /// 放在**共享容器根**——这正是 migrate 的 destinationDirectory。
    /// 该假设被 SwiftData 内部布局变化打破时,此测试先于用户数据变红。
    @MainActor
    func test_persistentGroupContainerStoreLocationPin() throws {
        guard let groupRoot = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppGroup.identifier) else {
            // 模拟器无 entitlement 场景 containerURL 也可用;真拿到 nil
            // 说明环境异常,显式失败而非跳过(布局假设未被验证)
            XCTFail("App Group 容器不可用,布局锚定无法验证")
            return
        }
        let storeURL = groupRoot.appendingPathComponent("default.store")
        let preExisting = FileManager.default.fileExists(atPath: storeURL.path)

        let schema = SchemaRegistry.makeSchema()
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .identifier(AppGroup.identifier),
            cloudKitDatabase: .none,
        )
        let container = try ModelContainer(for: schema, configurations: [config])

        // 容器初始化即落盘 store 文件(或本就存在);断言位置假设成立
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storeURL.path),
            "SwiftData groupContainer 落盘位置与迁移目标不一致,布局假设被打破"
        )

        // 清理:仅删除本次测试新建的文件(既有文件不动——可能是别的
        // 测试/迁移留下的合法库)。容器先释放再删,避免 SQLite 句柄未关。
        if !preExisting {
            container.deleteAllData()
            for name in LegacyStoreMigrator.storeFileNames {
                let url = groupRoot.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
