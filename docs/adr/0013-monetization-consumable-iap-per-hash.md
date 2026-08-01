# 0013 — 付费 = 消耗型 IAP per-content_hash,不做订阅

Status: accepted (2026-07-18)

付费模型选**消耗型 IAP(Consumable)按 content_hash 绑定**,不做订阅 / 月费 / 自动续费。

- `com.qicompass.deep_analysis.single` — 单次深度解析解锁,$17.99,绑定一个 `content_hash`
- `com.qicompass.compatibility.single` — 单次合盘解锁,$11.99,绑定一个 `compatibility_hash`

修改生辰 → `content_hash` 变 → 新 entitlement 需要重新购买(旧 entitlement 不失效,还能看回旧命盘付费内容)。后端用 App Store Server API 二次校验 entitlement,退款 webhook 置 `is_active=0`。

**Why**:
1. 用户原话:"修改生辰要重新购买" — 严格按 content_hash 绑定
2. 订阅制对单人 side project 是负担(续费催收 / 退订挽留 / 家庭共享策略)
3. 消耗型 + per-hash 让"专业深度、定制、不水"的承诺跟价格对齐($18 单价对应"深度、定制、不水")

**Surprising without context**: 一般 App 走订阅(ARPU 高),QiCompass 故意做消耗型单次购买。看起来"赚得少",其实跟高端定位匹配 — 不靠走量,靠单价。

**越狱保护**: iOS 越 UI 绕过锁标 → 调 `/api/interpret bazi_deep_paid` → 后端检查 entitlement → 无 entitlement → 403。即使 reverse engineer iOS binary 也拿不到付费内容(prompt_hash + 后端 cache 拆分 + entitlement 三重保护)。

**Real trade-off**:
- ✅ 消耗型 IAP per-hash — 跟产品定位对齐 + 简单 + 越狱保护
- ❌ 订阅(月 / 年 / 终身)— 续费催收负担 + 跟"研究工具"定位违和
- ❌ 免费 + 广告 — 跟"专业不忽悠"完全冲突
- ❌ 一次性买断全解锁 — 失去按命盘变现的颗粒度

**新依赖**(已用户同意): Python `app-store-server-library`(苹果官方 SDK,封装 JWT 签名 + JWS 验证 + transaction 查询),iOS StoreKit 2(系统自带)。详见 `MONETIZATION.md`。

**Consequences**:
- 深度解析 prompt 拆 `bazi_deep_free`(2 章:性格底色 + 事业)+ `bazi_deep_paid`(5 章:财运 / 爱情 / 健康 / 六亲 / 晚年)
- 免费章节必须真 AI 内容(不是占位 / 缩水),让用户感知"AI 真有料"才肯买
- 合盘同形态(M4 slice 复制粘贴)
