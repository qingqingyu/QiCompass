import Foundation
import SwiftData

/// ChartSnapshot upsert 结果(用于日志区分新建/覆盖)。
struct ChartSnapshotUpsertResult {
    let snapshot: ChartSnapshot
    let isNew: Bool
}

/// ChartSnapshotStore 错误(显式传播,不静默吞)。
enum ChartSnapshotStoreError: Error, LocalizedError {
    /// 时辰未知存档回退路径:请求钟面字符串按出生地时区解析失败(上游 bug,须暴露)
    case birthDatetimeUnparsable(birthDatetime: String, timezone: String)

    var errorDescription: String? {
        switch self {
        case .birthDatetimeUnparsable(let wall, let tz):
            return "出生钟面字符串按时区解析失败(存档回退路径): \(wall) @ \(tz)"
        }
    }
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
    ///   S03 起不再存输入墙钟——request.birthDatetime 已是 naive 字符串)。
    ///   S05 时辰未知:后端 true_solar_time=null(12:00 占位属假精度不漏响应)→
    ///   回退 request.birthDatetime(时辰未知时是 12:00 占位钟面)按出生地时区解析
    ///   ——存档字段承载的是「出生日期」锚点(合盘兜底名/Profile 年份),不是假精度
    ///   真太阳时;解析失败显式 throw(不存垃圾时间)
    /// - payload = 整个 BaziResponse JSON(重建 UI 只需 decode BaziResponse)
    ///   时辰未知存档(S04):hour_known 随后端 calc_rule_snapshot.hour_known 落 payload;
    ///   late_night 是用户输入、后端响应不回显 → 编码前从 request 注入(var lateNight,
    ///   nil 时 encodeIfPresent 省 key,老盘形状不变)
    func upsert(response: BaziResponse, request: BaziCalculateRequest) throws -> ChartSnapshotUpsertResult {
        let hash = response.contentHash
        let desc = FetchDescriptor<ChartSnapshot>(
            predicate: #Predicate { $0.contentHash == hash }
        )
        let existing = try context.fetch(desc).first

        var archivableResponse = response
        archivableResponse.lateNight = request.lateNight
        let payloadData = try APICoder.encoder.encode(archivableResponse)
        let calcRuleData = try APICoder.encoder.encode(response.calcRuleSnapshot)
        let cityLongitude = response.calcRuleSnapshot.trueSolarLongitude
        // S05:真太阳时 null(时辰未知)→ 出生日期锚点回退(见 docstring)
        let birthDate = try response.trueSolarTime ?? Self.parseBirthDate(from: request)

        if let snapshot = existing {
            // 覆盖:保留 createdAt
            snapshot.schemaVersion = response.calcRuleSnapshot.schemaVersion
            snapshot.birthSolarTime = birthDate
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
                birthSolarTime: birthDate,
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

    /// request.birthDatetime(裸钟面 yyyy-MM-dd'T'HH:mm:ss,时辰未知时 12:00 占位)
    /// 按出生地时区解析为 Date(S05 时辰未知存档回退路径)。
    /// 字符串/时区非法 → 显式 throw(上游 bug,不静默存垃圾时间)。
    private static func parseBirthDate(from request: BaziCalculateRequest) throws -> Date {
        guard let tz = TimeZone(identifier: request.timezone) else {
            throw ChartSnapshotStoreError.birthDatetimeUnparsable(
                birthDatetime: request.birthDatetime,
                timezone: request.timezone
            )
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = tz
        guard let date = formatter.date(from: request.birthDatetime) else {
            throw ChartSnapshotStoreError.birthDatetimeUnparsable(
                birthDatetime: request.birthDatetime,
                timezone: request.timezone
            )
        }
        return date
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

    /// S10 静默态 flag 写回 payload(`hour_unknown_accepted`,D7「我确实不知道」)。
    ///
    /// payload 是内容寻址数据,本字段是**纯 UI 提示偏好**(不参与排盘/喜忌/content_hash,
    /// 见 `BaziResponse.hourUnknownAccepted` 注),覆盖写不破坏「同一输入同一输出」——
    /// 排盘字段逐字节不动,decode→改 flag→encode 往返保持其余 payload 原样
    /// (生肖 null 透传等往返语义已有 S08 回归测试兜底)。
    /// 关闭静默(accepted=false)写 nil:encodeIfPresent 省 key,回到老盘 payload 形状。
    /// snapshot 缺失 → throw(触点状态错乱,显式暴露不静默)。
    func setHourUnknownAccepted(contentHash: String, accepted: Bool) throws {
        let desc = FetchDescriptor<ChartSnapshot>(
            predicate: #Predicate { $0.contentHash == contentHash }
        )
        guard let snapshot = try context.fetch(desc).first else {
            throw AddHourError.targetSnapshotMissing(contentHash: contentHash)
        }
        var response = try decodeResponse(from: snapshot)
        response.hourUnknownAccepted = accepted ? true : nil
        snapshot.payload = try APICoder.encoder.encode(response)
        try context.save()
        AppLogger.persistence.info(
            "op=chartSnapshot.setHourUnknownAccepted hash=\(contentHash, privacy: .public) accepted=\(accepted, privacy: .public)"
        )
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
    /// 时辰未知存档字段(hour_known / late_night)**不在此重建**——它们只活在
    /// payload(decodeResponse 可读,BaziResponse.isHourKnown / lateNight);
    /// display request 的 hourKnown 保持默认 true,不参与任何计算(见上用途边界)。
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

    /// S10 补时辰重算请求(编辑场景隔离,生肖决策 Q20:本入口只管补时辰)。
    ///
    /// 「原出生日期 + 新时辰 + 原 gender/place」→ `hourKnown=true`、`lateNight`
    /// 作废清 nil(补的是确定时辰,D3 二值问题只为日柱歧义判断,时辰确定后无意义)。
    ///
    /// **日期来源**(与 `archivedDisplayRequest` 的用途边界关键差异):本请求**会**
    /// 回传 /api/bazi/calculate,日期必须精确——时辰未知盘的 `birthSolarTime` 是
    /// request 的 12:00 占位钟面按出生地时区解析的「出生日期锚点」(S05 存档回退
    /// 路径),取其**日期分量**(出生地钟面)即用户当初输入的真实日期,不经真太阳时
    /// 近似。时辰分量由调用方传入(wheel/时辰快捷选的出生地钟面时分)。
    ///
    /// `cityTimezone` nil / 非法标识符 → 显式 throw:时辰未知盘不可能早于 S03
    /// (timezone 自 S03 起必存档),出现即数据损坏,不用设备时区静默兜底
    /// (CLAUDE.md 错误显式传播)。
    ///
    /// `geonameId` 不入存档 → nil(展示元数据,不参与 content_hash)。
    func addHourRequest(hour: Int, minute: Int) throws -> BaziCalculateRequest {
        guard let tzName = cityTimezone, let tz = TimeZone(identifier: tzName) else {
            throw AddHourError.timezoneMissing(contentHash: contentHash)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        var comps = calendar.dateComponents([.year, .month, .day], from: birthSolarTime)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard let combined = calendar.date(from: comps) else {
            throw AddHourError.combineFailed(contentHash: contentHash)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.timeZone = tz
        return BaziCalculateRequest(
            birthDatetime: formatter.string(from: combined),
            timezone: tzName,
            gender: gender,
            longitude: cityLongitude,
            latitude: cityLatitude,
            placeName: cityName,
            geonameId: nil,
            ziHourRule: ziHourRule,
            hourKnown: true,
            lateNight: nil
        )
    }
}
