import Foundation
import SwiftData

/// 跨设备命盘同步管理器(PR3.2)。
///
/// **核心职责**:
/// - pull:登录用户拉云端所有命盘 → 合并到本地(本地缺失的 insert,本地已有的 alias 不覆盖)
/// - push:上传本地所有命盘到云端(全量 UPSERT)
///
/// **触发时机**(T3 接入):
/// - 登录后 pull(首次登录拉云端)
/// - 创建/修改命盘后 push
/// - App 启动(若已登录)→ pull(后台静默)
///
/// **合并策略**:
/// - 本地 alias 优先(用户在本地改的 alias 是最新意图)
/// - 云端命盘本地缺失 → 从云端创建 ChartSnapshot + UserSnapshotLink
/// - 同 contentHash 命盘本地已存在 → 不覆盖(ChartSnapshot 字段全相同,UserSnapshotLink.alias 本地优先)
///
/// **错误处理**:
/// 失败不阻断 UI(state.failed + 日志),下次 App 启动重试。
@Observable
@MainActor
final class SyncManager {

    enum State: Equatable {
        case idle
        case pulling
        case pushing
        case ok(lastAction: String)  // "pulled 3" / "pushed 2"
        case failed(String)
    }

    private(set) var state: State = .idle

    private let apiClient: APIClient
    private let accountManager: AccountManager
    private let modelContext: ModelContext

    init(apiClient: APIClient, accountManager: AccountManager, modelContext: ModelContext) {
        self.apiClient = apiClient
        self.accountManager = accountManager
        self.modelContext = modelContext
    }

    // MARK: - pull

    /// 拉云端所有命盘 → 合并到本地(本地缺失的 insert,本地已有的不覆盖)。
    func pull() async {
        guard accountManager.isLoggedIn else {
            AppLogger.app.info("sync.pull.skip reason=not_logged_in")
            return
        }
        state = .pulling
        AppLogger.app.info("sync.pull.start")

        do {
            let resp = try await apiClient.syncPull()
            let pulledCount = resp.charts.count
            let insertedCount = await mergeToLocal(resp.charts)
            state = .ok(lastAction: "pulled \(pulledCount) (inserted \(insertedCount))")
            AppLogger.app.info(
                "sync.pull.ok pulled=\(pulledCount, privacy: .public) inserted=\(insertedCount, privacy: .public)"
            )
        } catch {
            AppLogger.app.error(
                "sync.pull.failed error=\(String(describing: error), privacy: .public)"
            )
            state = .failed("同步拉取失败:\(error.localizedDescription)")
        }
    }

    /// 合并云端命盘到本地 SwiftData。
    /// 仅当本地缺失(contentHash 不存在)时 insert;已有的不动(本地 alias 优先)。
    private func mergeToLocal(_ remoteCharts: [ChartSyncData]) async -> Int {
        var inserted = 0
        for remote in remoteCharts {
            // 查本地是否已有此 contentHash
            let hash = remote.contentHash
            let pred = #Predicate<ChartSnapshot> { $0.contentHash == hash }
            let desc = FetchDescriptor<ChartSnapshot>(predicate: pred)
            let existing = (try? modelContext.fetch(desc)) ?? []
            if !existing.isEmpty {
                // 本地已有 → 不覆盖(本地 alias 优先,ChartSnapshot 字段确定性相同)
                continue
            }

            // 本地缺失 → 从云端创建 ChartSnapshot + UserSnapshotLink
            guard let snapshot = buildChartSnapshot(from: remote) else {
                AppLogger.app.warning(
                    "sync.pull.skip_chart reason=decode_failed hash=\(remote.contentHash.prefix(8), privacy: .public)"
                )
                continue
            }
            modelContext.insert(snapshot)

            let link = UserSnapshotLink(
                userId: UserIdentity.userLocalId,
                snapshotHash: remote.contentHash,
                alias: remote.alias
            )
            modelContext.insert(link)
            inserted += 1
        }

        if inserted > 0 {
            do {
                try modelContext.save()
                AppLogger.app.info("sync.pull.merge_saved inserted=\(inserted, privacy: .public)")
            } catch {
                AppLogger.persistence.error(
                    "sync.pull.merge_save_failed error=\(String(describing: error), privacy: .public)"
                )
            }
        }
        return inserted
    }

    /// ChartSyncData → ChartSnapshot(仅确定性字段)。
    /// 失败返 nil(Base64 解码失败 / ISO 8601 解析失败)。
    private func buildChartSnapshot(from data: ChartSyncData) -> ChartSnapshot? {
        guard let birthDate = SyncDateFormatter.parse(data.birthSolarTime),
              let createdAt = SyncDateFormatter.parse(data.createdAt),
              let calcRule = Data(base64Encoded: data.calcRuleSnapshotBase64),
              let payload = data.payloadJson.data(using: .utf8) else {
            return nil
        }
        return ChartSnapshot(
            contentHash: data.contentHash,
            schemaVersion: data.schemaVersion,
            birthSolarTime: birthDate,
            gender: data.gender,
            cityLongitude: data.cityLongitude,
            ziHourRule: data.ziHourRule,
            calcRuleSnapshot: calcRule,
            payload: payload,
            createdAt: createdAt
        )
    }

    // MARK: - push

    /// 上传本地所有命盘到云端(全量 UPSERT)。
    func push() async {
        guard accountManager.isLoggedIn else {
            AppLogger.app.info("sync.push.skip reason=not_logged_in")
            return
        }
        state = .pushing
        AppLogger.app.info("sync.push.start")

        do {
            let charts = collectLocalCharts()
            AppLogger.app.info(
                "sync.push.collect count=\(charts.count, privacy: .public)"
            )
            let resp = try await apiClient.syncPush(request: SyncPushRequest(charts: charts))
            state = .ok(lastAction: "pushed \(resp.upsertedCount) (total \(resp.totalCount))")
            AppLogger.app.info(
                "sync.push.ok upserted=\(resp.upsertedCount, privacy: .public) total=\(resp.totalCount, privacy: .public)"
            )
        } catch {
            AppLogger.app.error(
                "sync.push.failed error=\(String(describing: error), privacy: .public)"
            )
            state = .failed("同步上传失败:\(error.localizedDescription)")
        }
    }

    /// 收集本地所有命盘(UserSnapshotLink + 对应 ChartSnapshot)→ [ChartSyncData]。
    /// 缺失 ChartSnapshot 的 link 跳过(数据异常,不阻断同步)。
    private func collectLocalCharts() -> [ChartSyncData] {
        let linkDesc = FetchDescriptor<UserSnapshotLink>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let links = (try? modelContext.fetch(linkDesc)) ?? []
        var result: [ChartSyncData] = []
        for link in links {
            let hash = link.snapshotHash
            let pred = #Predicate<ChartSnapshot> { $0.contentHash == hash }
            let snapDesc = FetchDescriptor<ChartSnapshot>(predicate: pred)
            guard let snapshot = (try? modelContext.fetch(snapDesc))?.first else {
                AppLogger.persistence.warning(
                    "sync.push.skip_link reason=no_snapshot hash=\(hash.prefix(8), privacy: .public)"
                )
                continue
            }
            guard let data = toSyncData(link: link, snapshot: snapshot) else {
                continue
            }
            result.append(data)
        }
        return result
    }

    /// ChartSnapshot + UserSnapshotLink → ChartSyncData。
    /// 失败返 nil(编码异常)。
    private func toSyncData(link: UserSnapshotLink, snapshot: ChartSnapshot) -> ChartSyncData? {
        return ChartSyncData(
            contentHash: snapshot.contentHash,
            alias: link.alias,
            schemaVersion: snapshot.schemaVersion,
            birthSolarTime: SyncDateFormatter.format(snapshot.birthSolarTime),
            gender: snapshot.gender,
            cityLongitude: snapshot.cityLongitude,
            ziHourRule: snapshot.ziHourRule,
            calcRuleSnapshotBase64: snapshot.calcRuleSnapshot.base64EncodedString(),
            payloadJson: String(data: snapshot.payload, encoding: .utf8) ?? "{}",
            createdAt: SyncDateFormatter.format(link.createdAt)
        )
    }
}
