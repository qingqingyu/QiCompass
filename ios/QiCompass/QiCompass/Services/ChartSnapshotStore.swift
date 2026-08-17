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
    /// - cityLongitude 来自 response.calcRuleSnapshot.trueSolarLongitude(物理真值回填)
    /// - cityTimezone/cityName/cityLatitude 来自 request(S03:出生地存档元数据)
    /// - birthSolarTime = response.trueSolarTime(字段语义即「真太阳时出生时间」,
    ///   S03 起不再存输入墙钟——request.birthDatetime 已是 naive 字符串)
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
            snapshot.birthSolarTime = response.trueSolarTime
            snapshot.gender = request.gender
            snapshot.cityLongitude = cityLongitude
            snapshot.cityTimezone = request.timezone
            snapshot.cityName = request.placeName
            snapshot.cityLatitude = request.latitude
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
                birthSolarTime: response.trueSolarTime,
                gender: request.gender,
                cityLongitude: cityLongitude,
                cityTimezone: request.timezone,
                cityName: request.placeName,
                cityLatitude: request.latitude,
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
        let result = try context.fetch(desc).first
        // 规则 2:hit/miss 业务分支日志(排查"snapshot 找不到"问题)
        AppLogger.persistence.info("op=chartSnapshot.get hash=\(hash, privacy: .public) hit=\(result != nil, privacy: .public)")
        return result
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

// MARK: - 存档请求重建(2026-08-16 深度解析直读存档)

extension ChartSnapshot {

    /// 从存档字段重建 BaziCalculateRequest(与 `decodeResponse(from:)` 配对,
    /// 共同支撑「深度解析 Tab 直读存档,不重复填表」)。
    ///
    /// **用途边界(重要)**:此请求只喂给展示层与 prompt context 构建链路 ——
    /// 下游实际只消费 gender / placeName / longitude 三个字段
    /// (ChartHeaderView + PromptContextBuilder.build)。**绝不回传 /api/bazi/calculate**:
    /// birthDatetime 由真太阳时(birthSolarTime)在出生城市时区下派生,是近似钟面,
    /// 不是用户当初输入的裸墙钟(S02 契约),用它重排会得到错误的 contentHash。
    ///
    /// 字段映射:cityLongitude→longitude、cityLatitude→latitude、cityName→placeName、
    /// cityTimezone→timezone(老快照 nil 兜底设备时区)、geonameId 不入存档(→ nil,
    /// 属展示元数据,不参与任何计算)。
    var archivedDisplayRequest: BaziCalculateRequest {
        // 标识符只解析一次,timezone 字段与 formatter 共用同一结果:
        // cityTimezone 为 nil(老快照)或非法标识符(损坏数据)时统一兜底设备
        // 时区,避免「timezone 声明 X、birthDatetime 却按设备时区渲染」的自相矛盾。
        let resolvedTZ = cityTimezone.flatMap(TimeZone.init(identifier:)) ?? .current
        let tzName = resolvedTZ.identifier
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = resolvedTZ
        return BaziCalculateRequest(
            birthDatetime: formatter.string(from: birthSolarTime),
            timezone: tzName,
            gender: gender,
            longitude: cityLongitude,
            latitude: cityLatitude,
            placeName: cityName,
            geonameId: nil,
            ziHourRule: ziHourRule
        )
    }
}
