import Foundation
import SwiftData
import CryptoKit

/// CompatibilitySnapshot upsert 结果(用于日志区分新建/覆盖)。
struct CompatibilitySnapshotUpsertResult {
    let snapshot: CompatibilitySnapshot
    let isNew: Bool
}

/// CompatibilitySnapshot SwiftData CRUD 封装。
///
/// 内容寻址语义(D13):
/// - `compatibilityHash`(主 key)= response.compatibilityHash,由后端用
///   `SHA-256(utf8len(h1):h1|utf8len(h2):h2|utf8len(ctx):ctx)` 规范化生成(h1=min,h2=max,utf8len=UTF-8 字节数),A/B 互换不产生重复快照
/// - `personAHash` / `personBHash` 保留**调用时 UI 顺序**(A=发起方,B=对端),便于展示
/// - `qualitativeAssessment` / `syncedFortune` 编码为 JSON Data 存
/// - `interpretation` 长期命书,默认 nil,AI 阶段写入后覆盖
///
/// 错误显式传播:fetch/encode/save 失败直接 throw,不吞不返回 nil。
@MainActor
final class CompatibilitySnapshotStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// upsert 定性评估结果(无 AI 文本,由 AI 阶段单独写入)。
    /// 主 key = `response.compatibilityHash`(后端已规范化)。
    /// personAHash / personBHash 按调用方传入的 UI 顺序记录(展示用)。
    func upsertQualitative(
        response: CompatibilityResponse,
        personAHash: String,
        personBHash: String,
        context: String
    ) throws -> CompatibilitySnapshotUpsertResult {
        let hash = response.compatibilityHash
        let desc = FetchDescriptor<CompatibilitySnapshot>(
            predicate: #Predicate { $0.compatibilityHash == hash }
        )
        let existing = try self.context.fetch(desc).first

        let assessmentData = try APICoder.encoder.encode(response.qualitativeAssessment)
        let syncedData = try APICoder.encoder.encode(response.syncedFortune)

        if let snapshot = existing {
            // 覆盖定性评估 + 流年(保留 interpretation + createdAt)
            snapshot.personAHash = personAHash
            snapshot.personBHash = personBHash
            snapshot.context = context
            snapshot.qualitativeAssessment = assessmentData
            snapshot.syncedFortune = syncedData
            try self.context.save()
            AppLogger.persistence.info(
                "op=compatibilitySnapshot.upsert hash=\(hash, privacy: .public) result=updated"
            )
            return CompatibilitySnapshotUpsertResult(snapshot: snapshot, isNew: false)
        } else {
            let snapshot = CompatibilitySnapshot(
                compatibilityHash: hash,
                personAHash: personAHash,
                personBHash: personBHash,
                context: context,
                qualitativeAssessment: assessmentData,
                syncedFortune: syncedData,
                interpretation: nil
            )
            self.context.insert(snapshot)
            try self.context.save()
            AppLogger.persistence.info(
                "op=compatibilitySnapshot.upsert hash=\(hash, privacy: .public) result=created"
            )
            return CompatibilitySnapshotUpsertResult(snapshot: snapshot, isNew: true)
        }
    }

    /// 按 compatibilityHash 查询(nil = 未找到,非错误)。
    func get(compatibilityHash: String) throws -> CompatibilitySnapshot? {
        let hash = compatibilityHash
        let desc = FetchDescriptor<CompatibilitySnapshot>(
            predicate: #Predicate { $0.compatibilityHash == hash }
        )
        return try context.fetch(desc).first
    }

    /// 同步更新 AI 解读文本(长期命书)。
    /// 不静默吞:快照缺失时 throw(让调用方知道 interpretation 未持久化)。
    func updateInterpretation(
        _ interpretation: String,
        forCompatibilityHash compatibilityHash: String
    ) throws {
        guard let snapshot = try get(compatibilityHash: compatibilityHash) else {
            AppLogger.persistence.error(
                "op=compatibilitySnapshot.updateInterpretation hash=\(compatibilityHash, privacy: .public) reason=snapshot_missing"
            )
            throw CompatibilitySnapshotError.snapshotMissing(compatibilityHash: compatibilityHash)
        }
        snapshot.interpretation = interpretation
        try context.save()
    }

    /// decode 定性评估(用于 View 展示)。
    func decodeQualitative(
        from snapshot: CompatibilitySnapshot
    ) throws -> QualitativeAssessmentDTO {
        do {
            return try APICoder.decoder.decode(
                QualitativeAssessmentDTO.self,
                from: snapshot.qualitativeAssessment
            )
        } catch {
            AppLogger.persistence.error(
                "op=compatibilitySnapshot.decodeQualitative hash=\(snapshot.compatibilityHash, privacy: .public) failed error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// decode 3 年流年同步(用于 View 展示)。
    func decodeSyncedFortune(
        from snapshot: CompatibilitySnapshot
    ) throws -> [SyncedFortuneDTO] {
        do {
            return try APICoder.decoder.decode(
                [SyncedFortuneDTO].self,
                from: snapshot.syncedFortune
            )
        } catch {
            AppLogger.persistence.error(
                "op=compatibilitySnapshot.decodeSyncedFortune hash=\(snapshot.compatibilityHash, privacy: .public) failed error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - 工具:规范化 hash(测试用 / 预查场景)

    /// 客户端 SHA-256 复刻后端 `compute_compatibility_hash`。
    /// 用于 A/B 已知但 API 未调用时预查(D13 对称性验证测试亦用)。
    /// 公式:`SHA-256(utf8len(h1):h1|utf8len(h2):h2|utf8len(ctx):ctx)`(h1=min,h2=max)。
    /// **长度必须按 UTF-8 字节数**(`.utf8.count`),与后端 `len(s.encode("utf-8"))` 对齐;
    /// 不能用 `.count`(字形簇数),否则 ZWJ emoji / 肤色调修饰等场景与 Python `len()`
    /// 不一致 → hash 分歧 → 预查 cache miss。
    static func canonicalKey(aHash: String, bHash: String, context: String) -> String {
        let h1 = aHash < bHash ? aHash : bHash
        let h2 = aHash < bHash ? bHash : aHash
        let payload = "\(h1.utf8.count):\(h1)|\(h2.utf8.count):\(h2)|\(context.utf8.count):\(context)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// CompatibilitySnapshotStore 领域错误。
enum CompatibilitySnapshotError: Error, LocalizedError {
    case snapshotMissing(compatibilityHash: String)

    var errorDescription: String? {
        switch self {
        case .snapshotMissing(let hash):
            return "合盘快照未找到(hash=\(hash))"
        }
    }
}
