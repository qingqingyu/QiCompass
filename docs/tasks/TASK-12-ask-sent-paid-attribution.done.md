# TASK-12 `ask_sent.paid` 改为精确归因(TASK-06 复核小问题)

> 2026-11-06 复核闭环。

## 背景(复核发现)
`ios/QiCompass/QiCompass/Features/DailyFortune/DailyAskView.swift` 用 `余额 > 3` 近似「本次扣的是付费次数」。后端 `ask_wallet` 只有一个 `balance` 总数,分不清试用和购买,所以:
- 买过次数包的用户,用到余额 ≤3 后全被记成 `paid=false`(低估)
- 无法回答「付费用户是否在持续用问事」

## ✅ 账务口径已确认(用户 2026-11-02 同意)
退款扣回改为**只扣购买部分**(见下方「退款」),不再从总余额扣到试用次数。可直接实施。

## 方案:钱包拆试用 / 购买两部分,试用先扣
### 后端 `backend/app/ask/store.py`
- `ask_wallet` 增列 `trial_balance INTEGER NOT NULL DEFAULT 0`(`balance` 继续表示总余额,不改语义)
  - 增量迁移沿用 TASK-02 的 PRAGMA / ALTER 模式,含多 worker 并发 duplicate-column 收敛
  - 存量回填:该 owner 在 `ask_purchases` **无**购买记录 → `trial_balance = balance`;**有**购买记录 → `trial_balance = 0`(无法还原历史,按已付费处理;仅影响 TestFlight 期老用户,在注释里写明)
- `try_grant_trial`:入账时 `trial_balance` 同步加 credits
- `try_consume`:原子地扣 1,优先扣 `trial_balance`;返回扣费来源 `"trial"` / `"purchased"`(余额不足仍返回失败)。必须单事务原子(条件 UPDATE + RETURNING 或 `BEGIN IMMEDIATE` 内读改写),并发不双扣、不错标
- `refund_consume`:新增必传参数 `charged_from`,退回到原来源
- `refund_purchase`(退款):扣回上限改为 `min(balance - trial_balance, credits)`——只扣购买部分(用户 2026-11-02 已确认)

### 后端 `backend/app/api/daily_ask.py`
- 作答响应增字段 `charged_from: "trial" | "purchased" | null`(缓存命中 / 免费重放不扣费时为 null)
- 失败回补路径把 `try_consume` 的返回值传给 `refund_consume`

### iOS
- 对应 DTO 解码 `charged_from`(可选字段,兼容旧后端)
- `Analytics.askSent(paid:)` 改为 `charged_from == "purchased"`;为 null 时 `paid=false`
- 删掉 `余额 > 3` 的近似逻辑及其注释
- 事件名和参数值域不变(仍是 `paid: bool`),`AnalyticsContractTests` 不需要改值域

## 测试
- `backend/tests/test_ask_store.py`:试用先扣;试用扣完扣购买;并发扣费不错标;`refund_consume` 退回原来源;退款只扣购买部分;存量迁移回填两种情况
- `backend/tests/test_daily_ask_api.py`:响应含 `charged_from`,三种取值各一例;失败回补后余额与来源正确
- iOS:DTO 解码含 / 不含 `charged_from` 两例

## 验收
- `cd backend && pytest` 全绿(含 `tests/test_context_binding.py`)
- iOS 相关测试全绿;Release 构建成功
- 未改 SKU / entitlement 映射(`tools/check_sku_sync.py` 不触发);未改 `daily_ask` prompt 模板

## 全局约束(必读)

- 决策来源:`docs/上架清单拍板-2026-10-28.md`;开工前读 `CLAUDE.md` 全文(守护栏为强制项)
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 不得新增任何依赖
- 新 .swift / 资源文件须 `project.pbxproj` 4 处登记一致 24 位 ID(漏登记 = 静默不编译)
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全;含新 CJK 词条后跑 `python3 tools/build_songti_fonts.py --verify` PASS
- UI 改动先读 `DESIGN.md`(朱红仅印章级小元素 / CTA radius 5 / 纯色不渐变)
