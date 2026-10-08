import Foundation

/// AI 解读子状态(三模块复用:bazi_deep / daily_fortune / compatibility)。
///
/// 关键解耦:AI 失败 ≠ 排盘/合盘失败。定性结果可见,AI 子状态独立可重试。
///
/// M3 拆分(对齐 MONETIZATION.md):
/// - idle:未触发(用户未点按钮)
/// - fetching:已发起 /api/interpret 调用
/// - okFree(text, cached):免费内容成功(M2 `*_free` module)
/// - okPaid(text, cached):付费内容成功(M2 `*_paid` module,有 entitlement)
/// - lockedPaid(previewChapters):未购买付费内容,UI 显示锁标 + 章节 preview
/// - failed(message):独立 error 态,可单独重试
/// - offlineLegacy(text, languageNote):离线兜底(仅每日运势)——快照里的历史解读正文仍在,
///   但离线无法确认当前 AI 来源,不能冒充 okFree 的缓存命中语义。2026-09-28
///   修复:此前塞 .failed 会被失败降级渲染成引擎模板,「已保留历史解读」
///   名不副实(一边说还在一边换掉正文)
/// - dailyLimitReached(nextReset, serverPool):每日次数已用完,**禁用生成按钮、不显示重试**,
///   用 `TimelineView(.everyMinute)` 渲染倒计时(本地池到本地午夜/服务端池到 UTC 零点);
///   serverPool(2026-10-08):true = 服务端 429 共享池,渲染层据此在未登录时
///   附「登录后可获得独立额度」引导(本地池与登录无关,不引导)
enum InterpretState: Equatable {
    case idle
    case fetching
    case okFree(text: String, cached: Bool)
    case okPaid(text: String, cached: Bool)
    case lockedPaid(previewChapters: [String])
    case failed(message: String)
    /// languageNote(L6/F7):快照语言 ≠ 当前生效语言时的「离线 · 显示的是
    /// ××版本」小注;nil = 语言一致或未知,不显示。
    case offlineLegacy(text: String, languageNote: String?)
    case dailyLimitReached(nextReset: Date, serverPool: Bool)
    /// context_token 缺失/失效(2026-10-08):老快照无 token / secret 轮换,
    /// 解读请求必 403,重试无意义——渲染「重新排盘」出口而非通用重试
    /// (此前塞 .failed 会显示重试按钮,点了必然再 403;每日还会白跑一次
    /// 静默重试)。落态入口:各 VM catch 处 APIError.isContextTokenError。
    case contextTokenExpired
}
