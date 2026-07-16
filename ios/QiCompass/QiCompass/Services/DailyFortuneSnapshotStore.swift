import Foundation
import SwiftData

/// DailyFortuneSnapshot SwiftData CRUD 封装。
///
/// 缓存策略(决策 §1.B):
/// - `cachedUntil = target_date 本地 23:59:59 + 1s`(日粒度,跨日立即重算)
/// - 与 InterpretationCache 的 24h AI 缓存解耦,两层职责分离
///
/// 错误显式传播:fetch/save 失败直接 throw,不返回 nil 掩盖故障。
@MainActor
final class DailyFortuneSnapshotStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// upsert:同 (chartHash, targetDate) 覆盖;不存在则新建。
    /// `cachedUntil` 由调用方按 businessDate 本地 23:59:59 + 1s 计算。
    func upsert(
        chartHash: String,
        targetDate: Date,
        response: DailyFortuneResponse,
        interpretation: String,
        cachedUntil: Date
    ) throws {
        let hash = chartHash
        let td = targetDate
        let desc = FetchDescriptor<DailyFortuneSnapshot>(
            predicate: #Predicate { $0.chartHash == hash && $0.targetDate == td }
        )
        let existing = try context.fetch(desc).first

        let hourPillarsData = try APICoder.encoder.encode(response.hourPillars)
        let tomorrowData = try APICoder.encoder.encode(response.tomorrowPreview)

        if let snapshot = existing {
            // 覆盖(保留 id)
            snapshot.dayPillar = response.dayPillar
            snapshot.dayRelation = response.dayRelationToDayMaster
            snapshot.dayChong = response.dayChong
            snapshot.dayChongTargets = response.dayChongTargets
            snapshot.hourPillars = hourPillarsData
            snapshot.lunarDate = response.lunarDate
            snapshot.huangliYi = response.huangliYi
            snapshot.huangliJi = response.huangliJi
            snapshot.tomorrowPreview = tomorrowData
            snapshot.interpretation = interpretation
            // 此接口没有 AI 身份入参。确定性刷新写入空解读时必须同时清除
            // 旧来源,避免出现“空文本 + 旧 provider/model”的伪 provenance。
            snapshot.interpretationProvider = nil
            snapshot.interpretationModel = nil
            snapshot.generatedAt = .now
            snapshot.cachedUntil = cachedUntil
            try context.save()
            AppLogger.persistence.info(
                "op=dailyFortune.upsert hash=\(hash, privacy: .public) targetDate=\(td, privacy: .public) result=updated"
            )
        } else {
            let snapshot = DailyFortuneSnapshot(
                chartHash: hash,
                targetDate: td,
                dayPillar: response.dayPillar,
                dayRelation: response.dayRelationToDayMaster,
                dayChong: response.dayChong,
                dayChongTargets: response.dayChongTargets,
                hourPillars: hourPillarsData,
                lunarDate: response.lunarDate,
                huangliYi: response.huangliYi,
                huangliJi: response.huangliJi,
                tomorrowPreview: tomorrowData,
                interpretation: interpretation,
                cachedUntil: cachedUntil
            )
            context.insert(snapshot)
            try context.save()
            AppLogger.persistence.info(
                "op=dailyFortune.upsert hash=\(hash, privacy: .public) targetDate=\(td, privacy: .public) result=created"
            )
        }
    }

    /// 单日查询(nil = 未找到,非错误)。
    func get(chartHash: String, targetDate: Date) throws -> DailyFortuneSnapshot? {
        let hash = chartHash
        let td = targetDate
        let desc = FetchDescriptor<DailyFortuneSnapshot>(
            predicate: #Predicate { $0.chartHash == hash && $0.targetDate == td }
        )
        return try context.fetch(desc).first
    }

    /// 仅当 `cachedUntil > now` 才返回(日粒度 fresh 判据)。
    func getCachedIfFresh(
        chartHash: String,
        targetDate: Date,
        now: Date = .now
    ) throws -> DailyFortuneSnapshot? {
        guard let snapshot = try get(chartHash: chartHash, targetDate: targetDate) else {
            return nil
        }
        return snapshot.cachedUntil > now ? snapshot : nil
    }

    /// 7 天历史(按 targetDate DESC)。
    func getHistory(
        chartHash: String,
        limit: Int = 7,
        now: Date = .now
    ) throws -> [DailyFortuneSnapshot] {
        let hash = chartHash
        let desc = FetchDescriptor<DailyFortuneSnapshot>(
            predicate: #Predicate { $0.chartHash == hash },
            sortBy: [SortDescriptor(\.targetDate, order: .reverse)]
        )
        let all = try context.fetch(desc)
        // 只取 <= now 的(不展示未来日);最多 limit 条
        return all.filter { $0.targetDate <= now }.prefix(limit).map { $0 }
    }

    /// 删除过期快照(防 SwiftData 膨胀)。保留最近 14 天(给历史回看足够余地)。
    func deleteExpired(chartHash: String, now: Date = .now) throws {
        let cutoff = now.addingTimeInterval(-14 * 24 * 3600)
        let hash = chartHash
        let desc = FetchDescriptor<DailyFortuneSnapshot>(
            predicate: #Predicate { $0.chartHash == hash && $0.targetDate < cutoff }
        )
        let stale = try context.fetch(desc)
        for s in stale {
            context.delete(s)
        }
        if !stale.isEmpty {
            try context.save()
            AppLogger.persistence.info(
                "op=dailyFortune.deleteExpired hash=\(hash, privacy: .public) count=\(stale.count)"
            )
        }
    }

    /// decode 12 时辰条(用于 View 展示)。
    func decodeHourPillars(from snapshot: DailyFortuneSnapshot) throws -> [HourPillarDTO] {
        do {
            return try APICoder.decoder.decode([HourPillarDTO].self, from: snapshot.hourPillars)
        } catch {
            AppLogger.persistence.error(
                "op=dailyFortune.decodeHours hash=\(snapshot.chartHash, privacy: .public) failed error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// decode 明日预告。
    func decodeTomorrowPreview(from snapshot: DailyFortuneSnapshot) throws -> TomorrowPreviewDTO? {
        guard !snapshot.tomorrowPreview.isEmpty else { return nil }
        do {
            return try APICoder.decoder.decode(TomorrowPreviewDTO.self, from: snapshot.tomorrowPreview)
        } catch {
            AppLogger.persistence.error(
                "op=dailyFortune.decodeTomorrow hash=\(snapshot.chartHash, privacy: .public) failed error=\(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    /// 同步更新某条快照的 AI 解读文本(让 7 天历史回看直接显示原解读,不重调 AI)。
    /// 写失败必须 throw,不静默掩盖。
    func updateInterpretation(
        _ interpretation: String,
        forChartHash chartHash: String,
        targetDate: Date,
        provider: String,
        model: String
    ) throws {
        guard let snapshot = try get(chartHash: chartHash, targetDate: targetDate) else {
            // 不静默吞:阶段 2 完成但本地快照已不存在(罕见,可能被 deleteExpired 清掉)
            AppLogger.persistence.error(
                "op=dailyFortune.updateInterpretation hash=\(chartHash, privacy: .public) targetDate=\(targetDate, privacy: .public) reason=snapshot_missing"
            )
            throw DailyFortuneSnapshotError.snapshotMissing(
                chartHash: chartHash, targetDate: targetDate
            )
        }
        snapshot.interpretation = interpretation
        snapshot.interpretationProvider = provider
        snapshot.interpretationModel = model
        try context.save()
    }
}

/// DailyFortuneSnapshotStore 领域错误。
enum DailyFortuneSnapshotError: Error, LocalizedError {
    case snapshotMissing(chartHash: String, targetDate: Date)

    var errorDescription: String? {
        switch self {
        case .snapshotMissing(let hash, let date):
            return "每日运势快照未找到(hash=\(hash), date=\(date)),可能已被清理"
        }
    }
}
