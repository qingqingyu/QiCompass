# TASK-14 删除账号确认文案与实际行为对齐(P3)

## 背景

`Localizable.xcstrings` 里删除账号的两条文案与 4fa6be73 的实际行为不符:

1. `account.delete.confirmBody` 说「购买记录将被永久删除」。实际后端是**匿名化保留**交易台账
   (`backend/app/auth/account_deletion.py` 第 3、4 步),隐私政策 §「删除账号」也写的是保留。
2. 同一条又说「本机数据不受影响」。实际删除成功后会调用
   `EntitlementStore.deactivateAllForAccount`,本机已购章节会变成锁定。
3. `account.delete.done` 说「手机上的命盘已保留」,没提已购章节被锁定。

## 要做

只改下表两个 key 的三语值,不改 key、不改代码。

| key | zh-Hans | zh-Hant | en |
|---|---|---|---|
| `account.delete.confirmBody` | 服务器上与账号关联的数据将被永久删除:已同步的命盘、问事余额与问事记录。购买记录会与账号解除关联并失效,已购章节与问事余额删除后无法恢复。手机上的命盘会保留,可在「我的 → 重置命盘」单独清除。 | 伺服器上與帳號關聯的資料將被永久刪除:已同步的命盤、問事餘額與問事記錄。購買記錄會與帳號解除關聯並失效,已購章節與問事餘額刪除後無法恢復。手機上的命盤會保留,可在「我的 → 重置命盤」單獨清除。 | The data linked to your account on our servers will be permanently deleted: synced charts, question credits and question history. Purchase records will be unlinked from your account and deactivated, so purchased chapters and question credits can't be restored. Charts on this phone are kept; use Me → Reset charts to clear them. |
| `account.delete.done` | 账号已删除。手机上的命盘已保留,已购章节已失效。 | 帳號已刪除。手機上的命盤已保留,已購章節已失效。 | Your account has been deleted. Charts on this phone were kept; purchased chapters are no longer unlocked. |

改之前核对两件事,不符就按实际改文案并在 PR 里说明:

- 「我的 → 重置命盘」与 App 内该入口的实际按钮名一致(三语都核对)
- 隐私政策 `tmp/app-store-launch/privacy-policy.md` 的「删除账号」条与上表口径一致(删什么、留什么)

## 验收

- `confirmationDialog` 中英繁三语在最小屏完整显示(message 过长会被系统截断,真机或模拟器看一次)
- `python3 tools/build_songti_fonts.py --verify` PASS

## 全局约束(必读)

- 来源:2026-11-27 外部 review;开工前读 `CLAUDE.md` 全文
- commit 必须三段式 body:Why / What / Impact
- 新 UI 文案进 `Localizable.xcstrings`,zh-Hans / zh-Hant / en 三语齐全
