import Foundation

/// 捌章目录行渲染模型(盘面小景 S4,仿 PillarSlotModel 范式):
/// 从 (module, moduleState, hasEntitlement) 纯派生行视觉与点击动作,
/// 视图层零分支判断——测试 target 无 ViewInspector,行状态经此模型断言。
enum ChapterRowModel: Equatable {
    /// 已读:实线圆徽 + 右缘墨点,点击进阅读页
    case read
    /// 免费未读:实线圆徽,点击开卷(起链 + 进章)
    case unreadFree
    /// 付费未解锁:虚线圆徽 + 章名弱化 + 付费标,点击付费墙
    /// (时辰未知时墙内自动转补时辰拦截态,S07)
    case lockedPaid
    /// 生成中:实线圆徽 + 右缘「生成中…」
    case generating
    /// 失败:进阅读页原地重试
    case retryable
    /// M4/M5 待输入:进阅读页页内两问表单
    case needsInput

    static func resolve(
        module: ModuleID,
        state: ModuleState?,
        hasEntitlement: Bool
    ) -> ChapterRowModel {
        if let state {
            switch state {
            case .ok:
                return .read
            case .fetching:
                return .generating
            case .failed:
                return .retryable
            case .needsInput:
                return .needsInput
            case .locked:
                return .lockedPaid
            case .pending:
                // 链上游 pending:视觉同未读免费/锁,点击进章显示布算中
                break
            }
        }
        if module.isPaid && !hasEntitlement {
            return .lockedPaid
        }
        return .unreadFree
    }

    /// 圆徽锁定视觉(虚线):付费未解锁章。
    var isBadgeLocked: Bool {
        self == .lockedPaid
    }

    /// 章名弱化(灰墨):付费未解锁。
    var isDim: Bool {
        self == .lockedPaid
    }
}

// OSLog 插值需要 CustomStringConvertible(带关联值的 enum 自动合成
// description 不满足 os_log 约束,显式提供稳定短名便于日志检索)
extension ChapterRowModel: CustomStringConvertible {
    var description: String {
        switch self {
        case .read: return "read"
        case .unreadFree: return "unreadFree"
        case .lockedPaid: return "lockedPaid"
        case .generating: return "generating"
        case .retryable: return "retryable"
        case .needsInput: return "needsInput"
        }
    }
}

/// 主页沉底 CTA 模型(盘面小景 S4):从模块状态 / 次数 / entitlement 纯派生,
/// 覆盖定稿 ①②③⑪ 四态 + 重读态。视图层只管渲染,不重复判定。
enum HomeCTAModel: Equatable {
    /// 开卷(一章未读):起链 + 进首章
    case openFirst(ModuleID)
    /// 续读(有已读,进首个未读章)
    case resume(ModuleID)
    /// 解印全本(免费尽 + 有付费未解锁)
    case unlockAll
    /// 重读(捌章全 ok;ghost)
    case reread
    /// 次数用尽(免费未读完 + remaining ≤ 0;ghost,已读章仍可重读)
    case limitReached

    static func resolve(
        moduleStates: [ModuleID: ModuleState],
        remainingReads: Int,
        hasEntitlement: Bool
    ) -> HomeCTAModel {
        let readCount = ModuleID.allCases.filter { moduleStates[$0]?.isOk == true }.count
        let hasLocked = ModuleID.allCases.contains { module in
            module.isPaid && moduleStates[module]?.isOk != true
        }

        // 捌章全 ok → 重读
        if readCount == ModuleID.allCases.count {
            return .reread
        }

        // 首个未读章(付费未解锁跳过——那是 unlockAll 的事)
        let next = ModuleID.allCases.first { module in
            moduleStates[module]?.isOk != true && !(module.isPaid && !hasEntitlement)
        }

        if let next {
            // 免费未读且次数耗尽 → 次数用尽 ghost(付费已解锁的章不受每日次数影响
            // 的口径不存在——v1 全模块计次,故 remaining≤0 即拦)
            if remainingReads <= 0 {
                return .limitReached
            }
            return readCount == 0 ? .openFirst(next) : .resume(next)
        }

        // 免费(已购全部)读尽仍有未 ok → 解印?无:无 next 且非全 ok 只剩
        // 付费未解锁(未购)或异常态;有锁 → 解印,否则(理论不可达)重读
        return hasLocked ? .unlockAll : .reread
    }
}

// MARK: - 链进度(2026-09-08 断点续跑:主页横幅纯派生)

/// v1 链进度与预计耗时(主页 chainBanner 消费,纯函数可测,与 ChapterRowModel
/// 同范式:视图层零分支)。
///
/// 口径:只统计「可跑」章——排除付费未解锁(locked 语义)与 M4/M5 未填输入
/// (needsInput 语义,它们等用户动作,不占生成时间);done 只数 runnable 中的
/// .ok(缓存回填的 ok 也算)。ETA 按每章 ~45s(实测 30-50s,90s 超时上限)
/// 向上取整分钟——宁多报不虚报。
enum ChainProgress {
    /// 单章预估耗时(LLM 实测 30-50s,取中位偏保守)。
    static let secondsPerChapter: TimeInterval = 45

    /// 剩余章数 → 预计分钟(向上取整;0 → 0)。
    static func estimatedMinutes(remaining: Int) -> Int {
        guard remaining > 0 else { return 0 }
        return Int(ceil(Double(remaining) * secondsPerChapter / 60))
    }

    /// 从模块状态派生进度四元组。
    static func resolve(
        moduleStates: [ModuleID: ModuleState],
        hasEntitlement: Bool,
        hasM4Input: Bool,
        hasM5Input: Bool
    ) -> (done: Int, total: Int, remaining: Int, estimatedMinutes: Int) {
        var done = 0
        var total = 0
        for module in ModuleID.allCases {
            let paidBlocked = module.isPaid && !hasEntitlement
            let inputBlocked = module.needsUserInput
                && (module == .m4 ? !hasM4Input : !hasM5Input)
            guard !paidBlocked, !inputBlocked else { continue }
            total += 1
            if moduleStates[module]?.isOk == true {
                done += 1
            }
        }
        let remaining = total - done
        return (done, total, remaining, estimatedMinutes(remaining: remaining))
    }
}
