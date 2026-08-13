import Foundation

/// 合盘结果列表单对摘要(决策 D9 列表卡片内容)。
///
/// 每张卡片用此结构。S01 基础字段(全成功态);
/// S03 加 `status: .computed / .failed(UserFacingError)` 支持对级错误隔离。
///
/// 红线 D9:不给数字分,只给定性两句话(五行互补 + 日主关系)。
struct PairSummary: Identifiable, Hashable {
    /// 列表稳定 id。
    /// S01 用 compatibilityHash(内容寻址,A/B 互换一致)。
    /// S03 单对失败时无 hash → 改用 entry.id 兜底(在 VM 内构造时决定)。
    let id: String
    /// 对应名单条目(回溯原始 entry,供 S03 单对重试构造请求)。
    let entry: RosterEntry
    /// 对方 resolved contentHash(模式 A = 存档 hash;模式 B = 隐式落地后 hash)。
    /// 供 S05 增量预查 + S06 持久化名单使用。
    let personBHash: String
    /// 卡片显示名(alias / 称呼 / 兜底名「对方」—— S04 兜底名扩为「对方+出生日期」)。
    let displayName: String
    /// 对方出生日期(存档已知;临时人从 ChartSnapshot.birthSolarTime 读)。
    let birthDate: Date?
    /// 对方日主(从 B ChartSnapshot 解出)。
    let dayMaster: String
    /// 五行互补一句话(`qualitativeAssessment.fiveElements`)。
    let fiveElements: String
    /// 日主关系一句话(`qualitativeAssessment.dayMasterRelation`)。
    let dayMasterRelation: String
    /// 合盘 hash(后端规范化,A/B 互换一致;详情页付费墙 entitlement 绑定用)。
    let compatibilityHash: String
    /// 是否已解读(`CompatibilitySnapshot.interpretation != nil`)。
    let isInterpreted: Bool
}
