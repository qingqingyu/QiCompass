import Foundation
import SwiftData

/// UserSnapshotLink SwiftData CRUD 封装。
///
/// 业务语义(bazi-app-design-doc.md §Data Model):
/// - "我自己 / 妈妈 / 男友" 这类展示别名挂在 link 上,ChartSnapshot 本身不归属用户
/// - 深度解析完成必须写 link,否则合盘 / 每日运势查不到命盘
/// - 合盘模式 B 隐式落地的 B 盘**不写** link(对方不是"我自己",
///   CompatibilityOrchestrator 的 `user_link=false` 注释是有意为之)
///
/// 错误显式传播:fetch/save 失败直接 throw,不吞不返回 nil。
@MainActor
final class UserSnapshotLinkStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// upsert:按 (userId, snapshotHash) 去重。
    /// 已存在 → 更新 alias(保留 createdAt);不存在 → 新建。
    ///
    /// - Parameters:
    ///   - userId:用户身份 ID。Slice 6 起调用方应传 `UserIdentity.currentUserId`
    ///     (已登录返后端 user_id,未登录兜底返 userLocalId);老代码传 userLocalId
    ///     由 SyncManager.backfillLocalLinks 在登录后批量迁移到 user_id。
    ///   - snapshotHash:命盘 contentHash
    ///   - alias:展示别名("我自己" / "妈妈" / "男友")
    /// - Returns:(link, isNew)
    @discardableResult
    func upsert(
        userId: String, snapshotHash: String, alias: String
    ) throws -> (link: UserSnapshotLink, isNew: Bool) {
        let pred = #Predicate<UserSnapshotLink> {
            $0.userId == userId && $0.snapshotHash == snapshotHash
        }
        let desc = FetchDescriptor<UserSnapshotLink>(predicate: pred)
        let matches = try context.fetch(desc)

        // 防御:fetch+insert 之间若被并发逻辑(将来合盘 B 盘 link 写入等)
        // 插入重复 (userId, snapshotHash),取 first 并 cleanup 多余记录。
        // 当前调用方(DeepAnalysisOrchestrator)由 calculateTask 串行化,
        // 实际无双 insert,但本层应自保。
        if matches.count > 1 {
            AppLogger.persistence.warning(
                "op=userLink.upsert user=\(userId.prefix(8), privacy: .public) hash=\(snapshotHash, privacy: .public) duplicate_count=\(matches.count, privacy: .public) cleaning_up"
            )
            // 保留最早的那条(createdAt 最小),删其余。count > 1 保证 min 非空。
            guard let keep = matches.min(by: { $0.createdAt < $1.createdAt }) else {
                // 理论不可达(matches.count > 1 已保证),防御式 throw 让上层感知
                throw NSError(
                    domain: "UserSnapshotLinkStore",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "matches.count>1 但 min 返回 nil(不应发生)"]
                )
            }
            for extra in matches where extra.persistentModelID != keep.persistentModelID {
                context.delete(extra)
            }
            keep.alias = alias
            try context.save()
            return (keep, false)
        }

        if let link = matches.first {
            // alias 可能用户后续修改("我自己" → "妈妈"),保留 createdAt
            link.alias = alias
            try context.save()
            AppLogger.persistence.info(
                "op=userLink.upsert user=\(userId.prefix(8), privacy: .public) hash=\(snapshotHash, privacy: .public) result=updated alias=\(alias, privacy: .public)"
            )
            return (link, false)
        } else {
            let link = UserSnapshotLink(
                userId: userId,
                snapshotHash: snapshotHash,
                alias: alias
            )
            context.insert(link)
            try context.save()
            AppLogger.persistence.info(
                "op=userLink.upsert user=\(userId.prefix(8), privacy: .public) hash=\(snapshotHash, privacy: .public) result=created alias=\(alias, privacy: .public)"
            )
            return (link, true)
        }
    }

    /// 按 userId 取所有 link(按 createdAt DESC)。
    /// 合盘 / 每日运势读取"当前用户的命盘列表"用。
    func list(userId: String) throws -> [UserSnapshotLink] {
        let pred = #Predicate<UserSnapshotLink> { $0.userId == userId }
        let desc = FetchDescriptor<UserSnapshotLink>(
            predicate: pred,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(desc)
    }

    /// 删除 link(ChartSnapshot 不动,历史解读缓存可回溯;今日运势 fallback 到次新命盘)。
    /// 用户在 ProfileView swipe 删除时调。
    func delete(linkId: UUID) throws {
        let pred = #Predicate<UserSnapshotLink> { $0.id == linkId }
        let desc = FetchDescriptor<UserSnapshotLink>(predicate: pred)
        let matches = try context.fetch(desc)
        guard let link = matches.first else {
            // 防御:fetch 不到说明 UI 状态过期(link 已被其他流程删),log + 不抛错
            // (UI 不需要区分"已删" vs "刚删",只看 list 刷新后是否消失)
            AppLogger.persistence.warning(
                "op=userLink.delete linkId=\(linkId, privacy: .public) result=not_found_skip"
            )
            return
        }
        context.delete(link)
        try context.save()
        AppLogger.persistence.info(
            "op=userLink.delete linkId=\(linkId, privacy: .public) alias=\(link.alias, privacy: .public) result=deleted"
        )
    }

    /// 更新 alias(只改 alias,不动 snapshotHash / createdAt / userId)。
    /// 用户在 ProfileView swipe 改名时调。
    func updateAlias(linkId: UUID, newAlias: String) throws {
        let trimmed = newAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // alias 不能为空,显式抛错(对齐 CLAUDE.md "错误显式传播")
            throw NSError(
                domain: "UserSnapshotLinkStore",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "alias 不能为空"]
            )
        }
        let pred = #Predicate<UserSnapshotLink> { $0.id == linkId }
        let desc = FetchDescriptor<UserSnapshotLink>(predicate: pred)
        guard let link = try context.fetch(desc).first else {
            throw NSError(
                domain: "UserSnapshotLinkStore",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "linkId=\(linkId) 不存在"]
            )
        }
        link.alias = trimmed
        try context.save()
        AppLogger.persistence.info(
            "op=userLink.updateAlias linkId=\(linkId, privacy: .public) newAlias=\(trimmed, privacy: .public)"
        )
    }
}
