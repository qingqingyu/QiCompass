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
    ///   排盘入参存档(G 条 2026-10-08):archived_birth_datetime(钟面)/
    ///   archived_geoname_id 同款从 request 注入——未来「自动重签」的原料,
    ///   本期只存不改行为;老 payload 缺 key → nil(decodeIfPresent)
    func upsert(response: BaziResponse, request: BaziCalculateRequest) throws -> ChartSnapshotUpsertResult {
        let hash = response.contentHash
        let desc = FetchDescriptor<ChartSnapshot>(
            predicate: #Predicate { $0.contentHash == hash }
        )
        let existing = try context.fetch(desc).first

        var archivableResponse = response
        archivableResponse.lateNight = request.lateNight
        // 排盘入参存档(G 条 2026-10-08 拍板「只补存字段,行为不变」):钟面
        // birth_datetime + geoname_id 注入 payload——未来「自动重签」的原料
        // (真太阳时不可逆推钟面,见 BaziResponse.archived* 注释)
        archivableResponse.archivedBirthDatetime = request.birthDatetime
        archivableResponse.archivedGeonameId = request.geonameId
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

    // MARK: - 老盘自动重签(附八拍板②,2026-10-09;2026-10-10 入口重定位)

    /// 同 hash 在飞重签任务(2026-10-10 接线补强):深度 403 摄入点与每日
    /// 403 重试对同一张盘并发触发 refresh 时,同 hash 只发一次 /calculate,
    /// 后到者直接搭车等结果(任务为非结构化 Task,不随首个调用方取消)。
    private var inFlightReSigns: [String: Task<BaziResponse?, Never>] = [:]

    /// 本会话内**注定失败**的盘(2026-10-10 接线补强):hash 不一致 /
    /// 后端不回 token / 无原料三类结局由后端状态决定,重试必然同结果——
    /// 记住后本会话不再重发(每日 403 重试路径无 VM 层「一次/盘/会话」
    /// 预算,hash 不一致的盘每次进今日页都会白发一次注定失败的排盘)。
    /// 网络类失败(calculate_failed)**不记忆**:离线恢复后可再试。
    private var reSignHopelessHashes: Set<String> = []

    /// 失效期重签:token 在档但被服务端拒(403,如 JWT 密钥轮换)时由调用方
    /// 在 **403 摄入点**显式触发——无条件重排换新 token。成功返回带新
    /// token 的 response;无原料 / 排盘失败 / hash 不一致 / 新响应仍无
    /// token → **nil**(调用方维持既有 403 出口语义,不新增错误面)。
    ///
    /// 加载期 ensure 入口已删(2026-10-10 外评核实为不可达死代码):
    /// token 上线(10-07)早于补存排盘入参(10-08),「有重签原料但缺
    /// token」的快照在时间线上不存在——有入参的快照必已有 token,无
    /// token 的老快照必无入参。重签统一收敛到 403 之后的路径。
    func refreshContextTokens(
        snapshot: ChartSnapshot, apiClient: APIClient
    ) async throws -> BaziResponse? {
        let response = try decodeResponse(from: snapshot)
        return try await reSign(
            snapshot: snapshot, response: response, apiClient: apiClient,
            reason: "refresh")
    }

    /// 重签入口(会话级注定失败短路 + 同 hash 在飞去重后进 `performReSign`)。
    private func reSign(
        snapshot: ChartSnapshot,
        response: BaziResponse,
        apiClient: APIClient,
        reason: String,
    ) async throws -> BaziResponse? {
        let hash = snapshot.contentHash
        if reSignHopelessHashes.contains(hash) {
            AppLogger.persistence.info(
                "op=chartSnapshot.re_sign skip reason=session_hopeless hash=\(hash, privacy: .public) trigger=\(reason, privacy: .public) — 本会话已判注定失败,不再重发(重新排盘即恢复)"
            )
            return nil
        }
        if let inFlight = inFlightReSigns[hash] {
            AppLogger.persistence.info(
                "op=chartSnapshot.re_sign dedup_join hash=\(hash, privacy: .public) trigger=\(reason, privacy: .public) — 搭乘同 hash 在飞重签"
            )
            return await inFlight.value
        }
        // 非结构化 Task:不继承调用方取消(搭车者仍需结果);本类 @MainActor,
        // Task 同在主 actor,落档无跨线程问题
        let task = Task { [weak self] () -> BaziResponse? in
            await self?.performReSign(
                snapshot: snapshot, response: response,
                apiClient: apiClient, reason: reason) ?? nil
        }
        inFlightReSigns[hash] = task
        defer { inFlightReSigns[hash] = nil }
        return await task.value
    }

    /// 重签核心(refresh 入口专用;原 ensure 加载期入口已删,2026-10-10):
    /// 重建排盘请求 → 静默 POST /api/bazi/calculate(确定性,不烧 LLM)→
    /// **断言新旧 contentHash 一致才接受**(G 条断言保险:排盘确定性下同
    /// 输入必同 hash;不一致 = 后端规则演化或原料损坏,重签结果属于
    /// 「另一张盘」,静默换 token 会张冠李戴破坏内容寻址与缓存/购买绑定)。
    /// 任一失败路径 → nil(refresh 的调用方据此维持既有 403 出口)。
    /// decode 失败在入口上抛——那是快照本体损坏,不是重签能修的。
    /// **落档是尽力而为**(2026-10-10):save/encode 失败不反噬重签——
    /// 返回值仍带新 token 服务本次生成,存档保持旧貌下次再试,错误显式
    /// 记日志(重签本就是 best-effort 恢复,落档失败把已到手的恢复抹成
    /// 「整盘加载失败」才是放大事故)。
    private func performReSign(
        snapshot: ChartSnapshot,
        response: BaziResponse,
        apiClient: APIClient,
        reason: String,
    ) async -> BaziResponse? {
        guard let request = Self.reSignRequest(
            snapshot: snapshot, response: response)
        else {
            reSignHopelessHashes.insert(snapshot.contentHash)
            AppLogger.persistence.info(
                "op=chartSnapshot.re_sign skip reason=no_materials hash=\(snapshot.contentHash, privacy: .public) trigger=\(reason, privacy: .public) — 更早快照无排盘入参,维持既有「重新排盘」出口"
            )
            return nil
        }
        let fresh: BaziResponse
        do {
            fresh = try await apiClient.calculateBazi(request: request)
        } catch {
            // 网络类失败不进 hopeless 集:离线恢复后仍可重试
            AppLogger.app.info(
                "op=chartSnapshot.re_sign skip reason=calculate_failed hash=\(snapshot.contentHash, privacy: .public) error=\(String(describing: error), privacy: .public) — 老盘维持既有 403 出口"
            )
            return nil
        }
        guard fresh.contentHash == snapshot.contentHash else {
            // G 条断言保险:不一致 = 换盘而非重签,绝不静默接受新 token;
            // 结局确定性(后端规则演化)→ 本会话不再重试
            reSignHopelessHashes.insert(snapshot.contentHash)
            AppLogger.app.warning(
                "op=chartSnapshot.re_sign hash_mismatch old=\(snapshot.contentHash, privacy: .public) new=\(fresh.contentHash, privacy: .public) trigger=\(reason, privacy: .public) — 不接受新 token,既有「重新排盘」出口接管"
            )
            return nil
        }
        guard let freshTokens = fresh.contextTokens, !freshTokens.isEmpty else {
            reSignHopelessHashes.insert(snapshot.contentHash)
            AppLogger.app.info(
                "op=chartSnapshot.re_sign skip reason=fresh_without_tokens hash=\(snapshot.contentHash, privacy: .public) — 后端未回 token,不覆盖存档"
            )
            return nil
        }
        // 后端不回显的存档侧字段补齐后再落档/返回:lateNight/archived* 由
        // upsert 从 request 注入 payload;hourUnknownAccepted(S10 静默偏好)
        // 无注入路径,须显式带上防覆盖丢失——**落盘前重读当前 payload**
        // (2026-10-10):重签网络等待期间用户可能刚切换「我确实不知道」
        // (setHourUnknownAccepted 已落盘),用请求前的旧值覆盖会静默丢
        // 用户设置;重读失败(等待期间 payload 被写坏,理论不可达)留痕
        // 沿用入口值,不反噬重签。createdAt 由 upsert 保留。
        var archivable = fresh
        do {
            archivable.hourUnknownAccepted = try decodeResponse(from: snapshot)
                .hourUnknownAccepted
        } catch {
            AppLogger.persistence.error(
                "op=chartSnapshot.re_sign reread_accepted_failed hash=\(snapshot.contentHash, privacy: .public) error=\(String(describing: error), privacy: .public) — 静默偏好沿用重签前值"
            )
            archivable.hourUnknownAccepted = response.hourUnknownAccepted
        }
        do {
            _ = try upsert(response: archivable, request: request)
        } catch {
            AppLogger.persistence.error(
                "op=chartSnapshot.re_sign persist_failed hash=\(snapshot.contentHash, privacy: .public) trigger=\(reason, privacy: .public) error=\(String(describing: error), privacy: .public) — 新 token 仅本次返回生效,存档未更新(下次加载再试)"
            )
        }
        archivable.lateNight = response.lateNight
        archivable.archivedBirthDatetime = request.birthDatetime
        archivable.archivedGeonameId = request.geonameId
        AppLogger.persistence.info(
            "op=chartSnapshot.re_sign hash=\(snapshot.contentHash, privacy: .public) trigger=\(reason, privacy: .public) — 老盘 token 重签落档 families=\(freshTokens.keys.sorted().joined(separator: ","), privacy: .public)"
        )
        return archivable
    }

    /// 重签排盘请求重建(与 `archivedDisplayRequest` 的关键差异:本请求**会**
    /// 回传 /api/bazi/calculate)。birthDatetime 用存档的原钟面
    /// (archived_birth_datetime,3695b6a 起 upsert 注入;真太阳时派生的
    /// 近似钟面在 DST 边界不可靠,不用),geonameId 用 archived_geoname_id;
    /// hourKnown/lateNight 从 payload 回读(时辰未知盘的 12:00 占位钟面 +
    /// hourKnown=false + lateNight 同输入必同 hash)。原料缺失 → nil
    /// (更早快照,调用方走既有出口)。
    private static func reSignRequest(
        snapshot: ChartSnapshot, response: BaziResponse
    ) -> BaziCalculateRequest? {
        guard let wall = response.archivedBirthDatetime,
              let tzName = snapshot.cityTimezone,
              TimeZone(identifier: tzName) != nil
        else { return nil }
        return BaziCalculateRequest(
            birthDatetime: wall,
            timezone: tzName,
            gender: snapshot.gender,
            longitude: snapshot.cityLongitude,
            latitude: snapshot.cityLatitude,
            placeName: snapshot.cityName,
            geonameId: response.archivedGeonameId,
            ziHourRule: snapshot.ziHourRule,
            hourKnown: response.isHourKnown,
            lateNight: response.lateNight
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
