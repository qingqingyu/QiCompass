import Foundation

/// 合盘对方名单成员(决策 D2:混合名单 = 存档勾选 + 临时输入)。
///
/// 上限 8 人(决策 D2,全局池 10 次/天配套:8 对方全 AI = 8 次不触顶)。
///
/// 红线 D6:`.temp` 成员**不建 UserSnapshotLink**——
/// - 零 SwiftData schema 演化(项目对演化保守)
/// - 零 SyncManager 影响(避免临时人上云成脏数据)
/// - ProfileView/命主卡零改动
///
/// S04 改造:
/// - `.temp` 支持多条(不再限 1 条)
/// - 加可选「称呼」字段(会话内显示)
/// - 加 `resolvedHash` 字段:首次计算成功后回填(S05 增量预查 / S06 跨启动持久化铺路)
/// - 跨启动兜底名策略由 PairSummary.displayName 体现(临时人无 alias → 「对方+出生日期」)
enum RosterEntry: Identifiable {
    /// 存档命盘(hash 软引用 `ChartSnapshot.contentHash`,与 `UserSnapshotLink.snapshotHash` 一致)。
    case archived(snapshotHash: String)
    /// 临时输入(模式 B 后端现排,落地 ChartSnapshot 不建 link)。
    /// - Parameters:
    ///   - input:模式 B 后端现排请求字段
    ///   - alias:可选称呼(会话内显示用),nil 或空字符串时走兜底名
    ///   - resolvedHash:首次计算成功后的 B contentHash(供 S05 增量预查 + S06 持久化名单用);
    ///     首次输入时 nil,computePair 成功后 VM 替换为带值版本
    case temp(input: PersonBInput, alias: String?, resolvedHash: String?)

    /// 稳定 id(用于 ForEach / diff / roster 内部管理)。
    /// 存档 = `"archived:\(hash)"`;临时 = 字段拼接(同输入产生同 id,S05 增量预查受益)。
    /// resolvedHash **不入 id**:计算后回填 resolvedHash 时 id 不变 → ForEach 不重建。
    var id: String {
        switch self {
        case .archived(let hash):
            return "archived:\(hash)"
        case .temp(let input, let alias, _):
            // 经度并入 id:同名同市区城市(同 placeName + 同 timezone)靠经度消歧,
            // 避免误判「名单已存在相同的对方」(S04 review)
            let loc = "\(input.placeName ?? "lon")@\(input.longitude)"
            return "temp:\(input.birthDatetime):\(input.timezone):\(input.gender):\(loc):\(alias ?? "")"
        }
    }

    /// 是否为临时人。
    var isTemp: Bool {
        if case .temp = self { return true }
        return false
    }

    /// 存档 hash(临时人返回 nil)。
    var archivedSnapshotHash: String? {
        if case .archived(let hash) = self { return hash }
        return nil
    }

    /// resolved contentHash(存档 = snapshotHash;临时 = resolvedHash,首次计算前 nil)。
    /// 供 S05 增量预查 / S06 持久化名单使用。
    var resolvedContentHash: String? {
        switch self {
        case .archived(let hash): return hash
        case .temp(_, _, let resolved): return resolved
        }
    }

    /// 临时人 alias(非 temp 返回 nil)。
    var tempAlias: String? {
        if case .temp(_, let alias, _) = self { return alias }
        return nil
    }

    /// 临时人 input(非 temp 返回 nil)。
    var tempInput: PersonBInput? {
        if case .temp(let input, _, _) = self { return input }
        return nil
    }
}

// MARK: - Hashable / Equatable(基于 id,因 PersonBInput 不是 Hashable)

extension RosterEntry: Hashable, Equatable {
    static func == (lhs: RosterEntry, rhs: RosterEntry) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
