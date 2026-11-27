# TASK-17 真机删号走查记录(模板,生产后端配齐 APPLE_AUTH_* 后填)

> 前置:生产 `.env` 已配 `APPLE_AUTH_TEAM_ID / APPLE_AUTH_KEY_ID / APPLE_AUTH_PRIVATE_KEY`,
> 重启后启动日志**无** `apple.revocation.not_configured` warning。
> Apple 后台建 Key 步骤见任务书(TASK-17-apple-revoke-key-setup.md)。

| # | 步骤 | 结果(填 ✅/❌ + 备注) |
|---|---|---|
| 1 | 测试 Apple ID 登录 → 购买一次深度解析(沙盒)→ 同步一张命盘 | |
| 2 | 我的 → 设置 → 删除账号 → 系统弹 Apple 重认证 → 确认 → 看到完成提示 | |
| 3 | 后端日志出现 `apple.revocation.ok` 与 `account.deleted`;DB 核对:`user_chart_sync` 无该用户行、`entitlement` 对应行 `content_hash='deleted'` 且 `is_active=0` | |
| 4 | iPhone 设置 → Apple ID → 登录与安全 → 通过 Apple 登录:列表里**已无本 App**(Apple 侧吊销成功的直接证据) | |

走查人:________ 日期:________ 后端 commit:________
