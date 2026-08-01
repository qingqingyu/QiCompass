# 0012 — 每日运势按需生成 + 24h 缓存,不用 Background Tasks

Status: accepted (2026-07-09)

每日运势在 App 打开时按需生成(`POST /api/bazi/daily-fortune`),结果缓存 24h(`DailyFortuneSnapshot.cachedUntil`)。**不用 iOS Background Tasks 预生成**。子时换日触发三重保险(app active / scenePhase active / `NSCalendarDayChanged` notification)。

**Why**: iOS Background Tasks 不可靠 — 系统会延迟 / 合并 / 跳过,无法保证用户打开时已有当日运势。按需生成保证用户打开就能看到当日流日柱(瞬时显示,0 延迟)+ AI 解读异步流式追加(3-5 秒)。

**Surprising without context**: 每日运势看起来是"每天自动推送"的场景,直觉会用 Background Tasks。这里故意放弃自动性,换可靠性。

**Real trade-off**:
- ✅ 按需 + 24h 缓存 — 可靠 + 简单 + 缓存命中零成本
- ❌ Background Tasks 预生成 — iOS 不可靠 + 调试困难 + 用户体验断点
- ❌ 推送通知触发预生成 — 用户没开通知就没数据 + 权限摩擦

**Consequences**:
- 用户打开 App 等 3-5 秒看 AI 解读(瞬时显示流日基本信息兜底,见 Open Question 10)
- 离线时 fallback 本地缓存,显示"离线查看(展示本地缓存,不扣次数)"角标
- 历史 7 天可回看(读本地 snapshot,不重新生成)

子时换日三重触发是为了应对:app 一直开着跨过子时 / app 从后台恢复 / 系统日历切换。
