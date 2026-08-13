import Foundation

/// 合盘结果列表单对摘要(决策 D9 列表卡片内容 + S03 对级错误隔离)。
///
/// 每张卡片用此结构。S01 基础字段;S03 加 `status` 支持对级错误隔离 + 单对重试。
///
/// 红线 D9:不给数字分,只给定性两句话(五行互补 + 日主关系)。
/// 红线 D10:单对失败 → 该卡片 `.failed` 态 + 重试按钮,不拖垮列表。
struct PairSummary: Identifiable, Equatable {
    /// 列表稳定 id。
    /// 成功 = compatibilityHash(内容寻址);失败 = `"failed:\(entryId)"`(无 hash 时用 entry id 兜底)。
    let id: String
    /// 对应名单条目(回溯原始 entry,供 S03 单对重试构造请求)。
    let entry: RosterEntry
    /// 对方 resolved contentHash(模式 A = 存档 hash;模式 B = 隐式落地后 hash)。
    /// 失败时为空字符串(API 未返回);重试成功后填上。
    let personBHash: String
    /// 卡片显示名(alias / 称呼 / 兜底名「对方」—— S04 兜底名扩为「对方+出生日期」)。
    let displayName: String
    /// 对方出生日期(存档已知;临时人从 ChartSnapshot.birthSolarTime 读;失败时可能 nil)。
    let birthDate: Date?
    /// 对方日主(失败时为占位「—」,卡片不展示)。
    let dayMaster: String
    /// 五行互补一句话(`qualitativeAssessment.fiveElements`)。失败时占位。
    let fiveElements: String
    /// 日主关系一句话(`qualitativeAssessment.dayMasterRelation`)。失败时占位。
    let dayMasterRelation: String
    /// 合盘 hash(后端规范化,A/B 互换一致;详情页付费墙 entitlement 绑定用)。
    /// 失败时为空字符串(无法进详情)。
    let compatibilityHash: String
    /// 是否已解读(`CompatibilitySnapshot.interpretation != nil`)。
    let isInterpreted: Bool
    /// S03:对级状态(.computed / .failed(message))。
    let status: Status

    /// 对级状态(决策 D10 对级错误隔离)。
    enum Status: Equatable {
        /// 该对成功完成确定性合盘,卡片正常展示。
        case computed
        /// 该对失败(网络 / 后端 / decode 等),卡片显示失败态 + 单对重试按钮。
        /// 单对重试不触碰付费 / 次数 / 后端(S03 红线)。
        case failed(UserFacingError)
    }

    /// 是否成功(便利 computed)。
    var isComputed: Bool {
        if case .computed = status { return true }
        return false
    }
}
