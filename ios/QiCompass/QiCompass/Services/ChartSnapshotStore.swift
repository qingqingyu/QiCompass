import Foundation
import SwiftData

/// ChartSnapshot upsert 结果(用于日志区分新建/覆盖)。
struct ChartSnapshotUpsertResult {
    let snapshot: ChartSnapshot
    let isNew: Bool
}

/// ChartSnapshot SwiftData CRUD 封装。
///
/// 内容寻址语义(D1):同一 contentHash 的 upsert 覆盖 payload/schemaVersion,
/// 保留 createdAt(快照首次创建时间)。
///
/// 错误显式传播:fetch/encode/save 失败直接 throw,不吞不返回 nil。
/// 日志:记录 contentHash / schemaVersion / 新建或覆盖标记。
@MainActor
final class ChartSnapshotStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// upsert:存在则覆盖 payload + schemaVersion(保留 createdAt),不存在则新建。
    ///
    /// - contentHash 来自 response(@Attribute(.unique) 自动去重)
    /// - cityLongitude 来自 response.calcRuleSnapshot.trueSolarLongitude
    ///   (后端 resolve_longitude 是经度单一事实源,客户端不查表 —— 决策 4.1)
    /// - payload = 整个 BaziResponse JSON(重建 UI 只需 decode BaziResponse)
    func upsert(response: BaziResponse, request: BaziCalculateRequest) throws -> ChartSnapshotUpsertResult {
        let hash = response.contentHash
        let desc = FetchDescriptor<ChartSnapshot>(
            predicate: #Predicate { $0.contentHash == hash }
        )
        let existing = try context.fetch(desc).first

        let payloadData = try APICoder.encoder.encode(response)
        let calcRuleData = try APICoder.encoder.encode(response.calcRuleSnapshot)
        let cityLongitude = response.calcRuleSnapshot.trueSolarLongitude

        if let snapshot = existing {
            // 覆盖:保留 createdAt
            snapshot.schemaVersion = response.calcRuleSnapshot.schemaVersion
            snapshot.birthSolarTime = request.birthDatetime
            snapshot.gender = request.gender
            snapshot.cityLongitude = cityLongitude
            snapshot.ziHourRule = request.ziHourRule
            snapshot.calcRuleSnapshot = calcRuleData
            snapshot.payload = payloadData
            try context.save()
            AppLogger.persistence.info(
                "op=chartSnapshot.upsert hash=\(hash, privacy: .public) result=updated schemaVersion=\(snapshot.schemaVersion)"
            )
            return ChartSnapshotUpsertResult(snapshot: snapshot, isNew: false)
        } else {
            let snapshot = ChartSnapshot(
                contentHash: hash,
                schemaVersion: response.calcRuleSnapshot.schemaVersion,
                birthSolarTime: request.birthDatetime,
                gender: request.gender,
                cityLongitude: cityLongitude,
                ziHourRule: request.ziHourRule,
                calcRuleSnapshot: calcRuleData,
                payload: payloadData
            )
            context.insert(snapshot)
            try context.save()
            AppLogger.persistence.info(
                "op=chartSnapshot.upsert hash=\(hash, privacy: .public) result=created schemaVersion=\(snapshot.schemaVersion)"
            )
            return ChartSnapshotUpsertResult(snapshot: snapshot, isNew: true)
        }
    }

    /// 按 contentHash 查询快照(nil = 未找到,非错误)。
    func get(contentHash: String) throws -> ChartSnapshot? {
        let hash = contentHash
        let desc = FetchDescriptor<ChartSnapshot>(
            predicate: #Predicate { $0.contentHash == hash }
        )
        return try context.fetch(desc).first
    }

    /// decode payload 回 BaziResponse(用于从快照重建 UI)。
    /// payload 损坏时 throw(老快照 schema 不兼容,由调用方决定重算策略)。
    func decodeResponse(from snapshot: ChartSnapshot) throws -> BaziResponse {
        do {
            return try APICoder.decoder.decode(BaziResponse.self, from: snapshot.payload)
        } catch {
            AppLogger.persistence.error(
                "op=chartSnapshot.decode hash=\(snapshot.contentHash, privacy: .public) failed error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }
}
