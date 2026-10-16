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

    /// 最新 link(createdAt 倒序第一条)。**刻意不按 userId 过滤**——与深度 tab
    /// `resolveArchivedChart` / 每日运势取盘同口径(裸 fetch),登录迁移中间态
    /// (link.userId 已 backfill 到后端 id)不分叉。nil = 本机无任何 link。
    func latestLink() throws -> UserSnapshotLink? {
        let desc = FetchDescriptor<UserSnapshotLink>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(desc).first
    }

    /// 替换语义(2026-10-17 用户拍板):写新盘 link + 删旧盘 link,一步完成。
    ///
    /// 背景:重新排盘(改生辰)/ 补时辰会产出新 hash 新命盘。旧实现只 upsert
    /// 新 link、旧 link 原样保留——旧版本盘按「最新 link = 命主」规则降级进
    /// 「我的」名册。名册设计上是他人盘存档(v2 多人 UI),被自己的历史版本盘
    /// 污染,用户观感是"我的资料被挪走了"。
    ///
    /// 顺序保证:**先写新后删旧**。upsert 失败直接 throw、旧 link 不动(若先删
    /// 后写,删成功写失败会让本机一条 link 都不剩,深度/今日运势按 link 取盘
    /// 直接空转)。删旧失败也 throw,由调用方决定降级(新盘已可用,残留旧行可
    /// 由名册编辑态手删)。
    ///
    /// - `oldSnapshotHash` 传 nil / 与新 hash 相同(同盘重排)时无旧可删,no-op;
    ///   按 hash 匹配不到 link(老盘本就无 link,如合盘临时人)同样 no-op。
    ///
    /// ChartSnapshot 不动(内容寻址,历史解读缓存仍可回溯);合盘名单/深度输入
    /// 由调用方另行 remap 到新 hash。
    ///
    /// 已知缺口:sync push 是 UPSERT-only(无 delete endpoint),已登录用户下次
    /// pull 可能把已删 link 从云端复活(对齐 ProfileView.resetAllData 的同款
    /// TODO);v1 sync 未上生产,暂不阻断。
    ///
    /// 已知边界(老安装多人 link):`runCalculation` 以 latestLink 作「旧命主」,
    /// 而全 App 命主判定本就是「最新 link」(ProfileView primary / 深度 tab
    /// resolveArchivedChart 同款)。若老安装的**他人**存量 link(如「妈妈」,
    /// 09-05 前入口创建)恰比命主 link 新,经错误恢复出口重排第三人盘时会把
    /// 该他人 link 一并删除(名册行消失;ChartSnapshot/合盘 V2 名单仍可回溯)。
    /// 数据模型无「同人」判别字段,alias 守卫会在命主改名后失效误伤——按拍板
    /// 取「删最新」单一规则,单人世界(v1 常态)不受影响。
    func replaceLink(
        userId: String,
        newSnapshotHash: String,
        alias: String,
        oldSnapshotHash: String?
    ) throws {
        _ = try upsert(userId: userId, snapshotHash: newSnapshotHash, alias: alias)
        guard let oldSnapshotHash, oldSnapshotHash != newSnapshotHash else { return }
        let pred = #Predicate<UserSnapshotLink> { $0.snapshotHash == oldSnapshotHash }
        let desc = FetchDescriptor<UserSnapshotLink>(predicate: pred)
        let stale = try context.fetch(desc)
        guard !stale.isEmpty else { return }
        for link in stale {
            context.delete(link)
        }
        try context.save()
        AppLogger.persistence.info(
            "op=userLink.replaceLink oldHash=\(oldSnapshotHash, privacy: .public) newHash=\(newSnapshotHash, privacy: .public) removed=\(stale.count, privacy: .public)"
        )
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

    /// 按 snapshotHash 查展示别名(S10 补时辰:老盘 alias 继承到新盘 + sheet 标题展示)。
    ///
    /// 故意**不按 userId 过滤**:用途是「这张盘叫什么名字」——单用户下 hash 唯一
    /// 对应一条 link;合盘临时人盘(hash 无 link)返回 nil,正是调用方要区分的语义
    /// (nil → 新盘不建 link,D6 红线)。fetch 失败 throw,不吞。
    func findAlias(snapshotHash: String) throws -> String? {
        let pred = #Predicate<UserSnapshotLink> { $0.snapshotHash == snapshotHash }
        let desc = FetchDescriptor<UserSnapshotLink>(
            predicate: pred,
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let matches = try context.fetch(desc)
        return matches.first?.alias
    }
}
