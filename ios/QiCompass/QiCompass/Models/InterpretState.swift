import Foundation

/// AI 解读子状态(三模块复用:bazi_deep / daily_fortune / compatibility)。
///
/// 关键解耦:AI 失败 ≠ 排盘/合盘失败。定性结果可见,AI 子状态独立可重试。
///
/// - idle:未触发(用户未点按钮)
/// - fetching:已发起 /api/interpret 调用
/// - ok(text, cached):成功,cached 标识是否命中缓存(命中不消耗次数)
/// - failed(message):独立 error 态,可单独重试
/// - dailyLimitReached(nextReset):全局每日 10 次已用完,**禁用生成按钮、不显示重试**,
///   用 `TimelineView(.everyMinute)` 渲染到本地午夜倒计时
enum InterpretState: Equatable {
    case idle
    case fetching
    case ok(text: String, cached: Bool)
    case failed(message: String)
    case dailyLimitReached(nextReset: Date)
}
