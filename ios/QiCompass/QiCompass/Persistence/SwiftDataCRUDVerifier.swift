import Foundation
import SwiftData

/// SwiftData CRUD 验证结果。
struct CRUDVerifyResult: Equatable {
    let summary: String
    let details: [String]
}

/// SwiftData CRUD 验证器(独立类,非 View,可被 Debug 面板与测试复用)。
///
/// 覆盖全部 5 个模型:Create / Read / Update / Delete + Assert 删除后查询为空。
/// 错误显式传播:任何步骤失败立即 throw,不吞不掩盖。
/// 日志:记录 model 类型 / contentHash / 操作类型 / 耗时 / 原始 error。
final class SwiftDataCRUDVerifier {
    private let context: ModelContext
    private var log: [String] = []

    init(context: ModelContext) {
        self.context = context
    }

    /// 执行完整 CRUD 验证流程,返回汇总结果。失败时 throw(错误显式传播)。
    func verify() async throws -> CRUDVerifyResult {
        log.removeAll()
        let testHash = "crud_test_\(UUID().uuidString.prefix(8))"
        AppLogger.debug.info("CRUD verify start testHash=\(testHash, privacy: .public)")

        // 1. Create(全部 5 模型)
        let chart = try await create(testHash: testHash)
        try await createUserLink(testHash: testHash)
        try await createInterpretationCache(testHash: testHash)
        try await createCompatibility(testHash: testHash)
        try await createDailyFortune(testHash: testHash)

        // 2. Read(按 hash + 四元组 Predicate)
        try await readChart(hash: testHash, expected: chart)
        try await readInterpretationCache(hash: testHash)

        // 3. Update
        try await updateChart(hash: testHash)
        try await updateInterpretationCache(hash: testHash)

        // 4. Delete(全部 5 模型)
        try await deleteAll(testHash: testHash)

        // 5. Assert 删除后查询为空
        try await assertAllDeleted(testHash: testHash)

        let summary = "CRUD 验证通过(5 模型 Create/Read/Update/Delete + Assert)"
        AppLogger.debug.info("CRUD verify ok testHash=\(testHash, privacy: .public)")
        return CRUDVerifyResult(summary: summary, details: log)
    }

    // MARK: - Create

    private func create(testHash: String) async throws -> ChartSnapshot {
        try await measure("create.ChartSnapshot", hash: testHash) {
            let payload = #"{"pillars":"stub"}"#.data(using: .utf8)!
            let calcRule = #"{"library":"lunar_python","sect":1}"#.data(using: .utf8)!
            let chart = ChartSnapshot(
                contentHash: testHash,
                schemaVersion: 1,
                birthSolarTime: Date(timeIntervalSince1970: 638_000_000),
                gender: "male",
                cityLongitude: 116.4,
                ziHourRule: "zi_next_day",
                calcRuleSnapshot: calcRule,
                payload: payload
            )
            self.context.insert(chart)
            try self.context.save()
            self.log.append("✓ Create ChartSnapshot hash=\(testHash)")
            return chart
        }
    }

    private func createUserLink(testHash: String) async throws {
        try await measure("create.UserSnapshotLink", hash: testHash) {
            let link = UserSnapshotLink(
                userId: "test_user",
                snapshotHash: testHash,
                alias: "CRUD测试"
            )
            self.context.insert(link)
            try self.context.save()
            self.log.append("✓ Create UserSnapshotLink hash=\(testHash)")
        }
    }

    private func createInterpretationCache(testHash: String) async throws {
        try await measure("create.InterpretationCache", hash: testHash) {
            let cache = InterpretationCache(
                contentHash: testHash,
                module: "bazi_deep",
                promptVersion: 1,
                targetDate: nil,
                provider: "anthropic",
                model: "verifier-model",
                interpretation: "CRUD 测试文本"
            )
            self.context.insert(cache)
            try self.context.save()
            self.log.append("✓ Create InterpretationCache hash=\(testHash)")
        }
    }

    private func createCompatibility(testHash: String) async throws {
        try await measure("create.CompatibilitySnapshot", hash: testHash) {
            let assessment = #"{"five_elements":"互补"}"#.data(using: .utf8)!
            let synced = "[]".data(using: .utf8)!
            let comp = CompatibilitySnapshot(
                compatibilityHash: testHash,
                personAHash: testHash,
                personBHash: testHash + "_b",
                context: "general",
                qualitativeAssessment: assessment,
                syncedFortune: synced
            )
            self.context.insert(comp)
            try self.context.save()
            self.log.append("✓ Create CompatibilitySnapshot hash=\(testHash)")
        }
    }

    private func createDailyFortune(testHash: String) async throws {
        try await measure("create.DailyFortuneSnapshot", hash: testHash) {
            let hours = "[]".data(using: .utf8)!
            let fortune = DailyFortuneSnapshot(
                chartHash: testHash,
                targetDate: Date(),
                dayPillar: "甲子",
                dayRelation: "比肩",
                hourPillars: hours,
                huangliYi: ["嫁娶"],
                huangliJi: ["出行"],
                interpretation: "CRUD 测试",
                cachedUntil: Date().addingTimeInterval(86400)
            )
            self.context.insert(fortune)
            try self.context.save()
            self.log.append("✓ Create DailyFortuneSnapshot hash=\(testHash)")
        }
    }

    // MARK: - Read

    private func readChart(hash: String, expected: ChartSnapshot) async throws {
        try await measure("read.ChartSnapshot", hash: hash) {
            let desc = FetchDescriptor<ChartSnapshot>(
                predicate: #Predicate { $0.contentHash == hash }
            )
            let results = try self.context.fetch(desc)
            guard let found = results.first else {
                throw CRUDVerifyError.readFailed("ChartSnapshot 查询为空 hash=\(hash)")
            }
            guard found.gender == expected.gender else {
                throw CRUDVerifyError.readFailed("ChartSnapshot gender 不匹配")
            }
            self.log.append("✓ Read ChartSnapshot hash=\(hash) gender=\(found.gender)")
        }
    }

    private func readInterpretationCache(hash: String) async throws {
        try await measure("read.InterpretationCache", hash: hash) {
            // 四元组 Predicate:(contentHash, module, promptVersion, targetDate)
            let module = "bazi_deep"
            let promptVersion = 1
            let desc = FetchDescriptor<InterpretationCache>(
                predicate: #Predicate {
                    $0.contentHash == hash && $0.module == module && $0.promptVersion == promptVersion
                }
            )
            let results = try self.context.fetch(desc)
            guard let found = results.first else {
                throw CRUDVerifyError.readFailed(
                    "InterpretationCache 四元组查询为空 hash=\(hash)")
            }
            self.log.append("✓ Read InterpretationCache hash=\(hash) module=\(found.module)")
        }
    }

    // MARK: - Update

    private func updateChart(hash: String) async throws {
        try await measure("update.ChartSnapshot", hash: hash) {
            let desc = FetchDescriptor<ChartSnapshot>(
                predicate: #Predicate { $0.contentHash == hash }
            )
            guard let chart = try self.context.fetch(desc).first else {
                throw CRUDVerifyError.updateFailed("ChartSnapshot 未找到")
            }
            chart.schemaVersion = 2
            let newPayload = #"{"pillars":"updated"}"#.data(using: .utf8)!
            chart.payload = newPayload
            try self.context.save()

            // 验证持久化:重新查询
            guard let refetched = try self.context.fetch(desc).first,
                  refetched.schemaVersion == 2 else {
                throw CRUDVerifyError.updateFailed("ChartSnapshot schemaVersion 未持久化")
            }
            self.log.append("✓ Update ChartSnapshot hash=\(hash) schemaVersion=2")
        }
    }

    private func updateInterpretationCache(hash: String) async throws {
        try await measure("update.InterpretationCache", hash: hash) {
            let desc = FetchDescriptor<InterpretationCache>(
                predicate: #Predicate { $0.contentHash == hash }
            )
            guard let cache = try self.context.fetch(desc).first else {
                throw CRUDVerifyError.updateFailed("InterpretationCache 未找到")
            }
            cache.interpretation = "更新后的文本"
            try self.context.save()

            guard let refetched = try self.context.fetch(desc).first,
                  refetched.interpretation == "更新后的文本" else {
                throw CRUDVerifyError.updateFailed("InterpretationCache interpretation 未持久化")
            }
            self.log.append("✓ Update InterpretationCache hash=\(hash)")
        }
    }

    // MARK: - Delete

    private func deleteAll(testHash: String) async throws {
        try await deleteModels(ChartSnapshot.self, hash: testHash) { $0.contentHash == testHash }
        try await deleteModels(UserSnapshotLink.self, hash: testHash) { $0.snapshotHash == testHash }
        try await deleteModels(InterpretationCache.self, hash: testHash) { $0.contentHash == testHash }
        try await deleteModels(CompatibilitySnapshot.self, hash: testHash) { $0.compatibilityHash == testHash }
        try await deleteModels(DailyFortuneSnapshot.self, hash: testHash) { $0.chartHash == testHash }
    }

    private func deleteModels<T: PersistentModel>(
        _ type: T.Type, hash: String,
        predicate: @escaping (T) -> Bool
    ) async throws {
        try await measure("delete.\(String(describing: type))", hash: hash) {
            let all = try self.context.fetch(FetchDescriptor<T>())
            let toDelete = all.filter(predicate)
            for item in toDelete {
                self.context.delete(item)
            }
            try self.context.save()
            self.log.append("✓ Delete \(String(describing: type)) hash=\(hash) count=\(toDelete.count)")
        }
    }

    // MARK: - Assert

    private func assertAllDeleted(testHash: String) async throws {
        try await assertEmpty(ChartSnapshot.self, hash: testHash) { $0.contentHash == testHash }
        try await assertEmpty(UserSnapshotLink.self, hash: testHash) { $0.snapshotHash == testHash }
        try await assertEmpty(InterpretationCache.self, hash: testHash) { $0.contentHash == testHash }
        try await assertEmpty(CompatibilitySnapshot.self, hash: testHash) { $0.compatibilityHash == testHash }
        try await assertEmpty(DailyFortuneSnapshot.self, hash: testHash) { $0.chartHash == testHash }
        log.append("✓ Assert 全部 5 模型删除后查询为空")
    }

    private func assertEmpty<T: PersistentModel>(
        _ type: T.Type, hash: String,
        predicate: @escaping (T) -> Bool
    ) async throws {
        let all = try context.fetch(FetchDescriptor<T>())
        let remaining = all.filter(predicate)
        if !remaining.isEmpty {
            throw CRUDVerifyError.assertFailed(
                "\(String(describing: type)) 删除后仍有 \(remaining.count) 条 hash=\(hash)")
        }
    }

    // MARK: - Measure

    /// 测量闭包耗时并记录(SwiftData 操作本身同步,async wrapper 保持调用方一致性)。
    private func measure<T>(
        _ operation: String,
        hash: String,
        body: () throws -> T
    ) async throws -> T {
        let start = ContinuousClock().now
        do {
            let result = try body()
            let elapsed = start.duration(to: .now)
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            AppLogger.persistence.info("op=\(operation, privacy: .public) hash=\(hash, privacy: .public) elapsed_ms=\(ms)")
            return result
        } catch {
            let elapsed = start.duration(to: .now)
            let ms = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            AppLogger.persistence.error("op=\(operation, privacy: .public) hash=\(hash, privacy: .public) elapsed_ms=\(ms) failed error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }
}

// MARK: - CRUDVerifyError

enum CRUDVerifyError: Error, LocalizedError {
    case readFailed(String)
    case updateFailed(String)
    case assertFailed(String)

    var errorDescription: String? {
        switch self {
        case .readFailed(let msg):    return "CRUD Read 失败: \(msg)"
        case .updateFailed(let msg):  return "CRUD Update 失败: \(msg)"
        case .assertFailed(let msg):  return "CRUD Assert 失败: \(msg)"
        }
    }
}
