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
        let existing = try context.fetch(desc).first

        if let link = existing {
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
