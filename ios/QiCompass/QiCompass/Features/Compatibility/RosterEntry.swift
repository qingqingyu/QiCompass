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
/// S01 限:`.temp` 名单内最多 1 条(保留现有单临时人模式不回归);
/// S04 扩为多条 + 可选「称呼」字段 + 跨启动兜底名。
enum RosterEntry: Identifiable {
    /// 存档命盘(hash 软引用 `ChartSnapshot.contentHash`,与 `UserSnapshotLink.snapshotHash` 一致)。
    case archived(snapshotHash: String)
    /// 临时输入(模式 B 后端现排,落地 ChartSnapshot 不建 link)。
    /// - Parameters:
    ///   - input:模式 B 后端现排请求字段
    ///   - alias:可选称呼(会话内显示用);S01 默认 nil,S04 加 UI 字段
    case temp(input: PersonBInput, alias: String?)

    /// 稳定 id(用于 ForEach / diff)。
    /// 存档 = `"archived:\(hash)"`;临时 = 字段拼接(同输入产生同 id,S04 增量预查受益)。
    var id: String {
        switch self {
        case .archived(let hash):
            return "archived:\(hash)"
        case .temp(let input, let alias):
            let loc = input.city ?? "lon\(input.longitude ?? 0)"
            return "temp:\(Int(input.birthDatetime.timeIntervalSince1970)):\(input.gender):\(loc):\(alias ?? "")"
        }
    }

    /// 是否为临时人(用于 S01 限 1 条 / S04 多条上限合计判定)。
    var isTemp: Bool {
        if case .temp = self { return true }
        return false
    }

    /// 存档 hash(临时人返回 nil)。
    var archivedSnapshotHash: String? {
        if case .archived(let hash) = self { return hash }
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
