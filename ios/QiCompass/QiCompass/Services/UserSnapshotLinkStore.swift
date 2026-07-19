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
    ///   - userId:用户本地 ID(`UserIdentity.userLocalId`)
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
}
