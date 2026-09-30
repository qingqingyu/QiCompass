# 合盘名单持久化修复 + 换人 sheet 三处小修 — 实施说明

> 日期:2026-09-30 · 状态:**已拍板,待实施**
> 来源:对 `e1ce3ad`(合盘结果页主页化 S1-S5)的 review
> 上游:`docs/合盘结果页主页化-plan.md`、`docs/合盘多选设计决策.md`(D5/D6)
> 本文件面向实施者(另一个 AI):读完即可开工。

---

## 0. 问题

结果页主页化之后,名单是用户换人的常驻入口,但名单的持久化还是 09-07 单选时代的写法:

- `CompatibilityViewModel.persistRosterState(summaries:)` 只在 `compute()` 成功后调,只存**本次算出的那一对**的 hash(单选 = 最多 1 个)。
- 临时对方只存 `resolvedHash`,**称呼(alias)、出生信息、出生地不存**。
- `removeRosterEntry` / `addTempToRoster` / `updateTempEntry` / 换人**都不写持久化**。

用户可见后果:

| # | 操作 | 现在的结果 |
|---|---|---|
| A | 加小王、妈妈、Lisa,来回换,杀 App 重开 | 名单只剩最后看的那一位 |
| B | 同上 | 剩下那一位的名字变成「对方 · 1989-06-18」,称呼丢了 |
| C | 最后一次合盘失败(断网)后重开 | 名单被存成空,回到首次进入填表页,所有人没了 |
| D | 移出当前对方后重开 | 被移出的人复活,并直接显示他的结果 |
| E | 刚加入还没算过的人,重开 | 消失(没有 resolvedHash,根本不在持久化里) |
| F | 换到一个以前算过的人,重开 | 恢复的可能是另一个人(「上次那位」按 CompatibilitySnapshot.createdAt 最新猜,换到老缓存对时 createdAt 不变) |

## 1. 决策(用户已拍板 2026-09-30)

- **R1 名单完整持久化到本地。** 名单的每一个成员都存,包括临时对方的完整出生信息(`PersonBInput`)、称呼(alias)、出生地(`PlaceSelection`)和已算出的 `resolvedHash`。
- **R2 每次名单或选中变化都立即写。** 触发点:添加、修改、移出、换人(选中变化)、resolvedHash 回填、补时辰 hash remap。**不再**依赖 `compute()` 成功。合盘失败不影响名单。
- **R3 持久化「当前选中的是谁」。** 重开时恢复这一位:它有 CompatibilitySnapshot 缓存 → 零请求直接显示结果;没有缓存 → 进结果壳 P6 态(头部显示「选择对方」,不自动发请求)。不再用 createdAt 猜「上次那位」,只在旧版数据迁移时兜底使用。
- **R4 仍然只存本地 UserDefaults,不进 SwiftData、不上云、不建 UserSnapshotLink。** D6 红线(临时对方不建 link、零 schema 演化、零 SyncManager 影响)不变;本次修订的只是 D6 里「名单只存 hash、alias 不持久化」这一条保守选择。
- **R5 旧数据迁移。** 老 key `compat.roster`(`[String]` hash 数组)读出后转成 `.archived(hash)` 成员写入新格式,然后删掉老 key。迁移只跑一次,迁移后「当前选中」按老逻辑(createdAt 最新)确定一次并写入。

## 2. 实现要点

### 2.1 数据格式

`CompatibilityRosterPersistence` 新增 key `compat.rosterV2`,存一个 Codable 结构:

```swift
struct PersistedRoster: Codable, Equatable {
    var entries: [PersistedRosterEntry]
    var selectedEntryID: String?   // RosterEntry.id;nil = 无选中(P6)
}

enum PersistedRosterEntry: Codable, Equatable {
    case archived(snapshotHash: String)
    case temp(input: PersonBInput, alias: String?, resolvedHash: String?, place: PlaceSelection)
}
```

- `PersonBInput`、`PlaceSelection` 已是 Codable,直接用。
- 不要让 `RosterEntry` 本身 Codable(它的 `==` 按 id 比较,Codable 与之混用容易埋坑)。在 `RosterEntry` 上加 `init(persisted:)` 和 `var persisted: PersistedRosterEntry` 互转即可。
- `personAHash` / `context` 两个 key 保持不变。
- 编码失败 / 解码失败:沿用现有做法,`AppLogger.persistence.error` + 视为空,损坏的 key 删除。**不能**静默用默认值掩盖(CLAUDE.md 错误显式传播)。

### 2.2 写入:VM 单一出口

在 VM 里加一个私有方法 `persistRoster()`,读当前 `roster` + `selectedEntryIds.first` + `currentPersonAHash` 写入。所有改名单或选中的地方都调它,不要在各处直接拼 UserDefaults:

| 位置(`CompatibilityViewModel.swift`) | 触发 |
|---|---|
| `addTempToRoster()` | 加入成功后 |
| `updateTempEntry(_:)` | 替换成功后 |
| `removeRosterEntry(_:)` | 移出后 |
| `selectEntryExclusively(_:)` / `toggleEntrySelection(_:)` / `toggleArchived(hash:)` | 选中或取消选中后 |
| `backfillTempResolvedHash(...)` | 回填后 |
| `applyHashRemap(from:to:)` | remap 后 |
| `clearDetailKeepRoster()` | 不改名单,不用写 |

- `persistRosterState(summaries:)` 删除;`compute()` 成功路径改调 `persistRoster()`(只为同步 resolvedHash 和 A hash)。
- 恢复流程(`restoreRosterStateIfAvailable`)给 `roster` / `selectedEntryIds` 赋值的过程中**不要**触发写入,否则会把半成品写回去。做法:恢复期间置一个 `isRestoring` 标志,`persistRoster()` 遇到它直接返回;恢复完成后统一写一次(把清理掉的无效项落盘)。

### 2.3 读取与恢复

改 `restoreRosterStateIfAvailable()`:

1. 读 `compat.rosterV2`;不存在则按 R5 从老 key 迁移。
2. 逐条校验:
   - `.archived(hash)`:`chartStore.get(contentHash:)` 查不到 → 剔除(沿用现在的 cleanup 语义,显式 warning 日志)。
   - `.temp`:恒保留(有完整输入,随时能重排)。`resolvedHash` 非 nil 但快照查不到 → 把 `resolvedHash` 置 nil(下次合盘重新请求),记 warning。
   - 名单超过 `rosterMax` → 截断到前 8 个并记 error(理论不可达)。
3. `roster` = 校验后的成员;`selectedEntryIds` = `selectedEntryID` 在名单里就用它,否则清空。
4. 有选中 → 用这一位的 `resolvedContentHash` 在 `compatibilityStore.list(personAHash:context:)` 里找对应快照:
   - 找到 → `rebuildSummaryFromCache(entry: <名单里真实的 entry>, ...)` → `openDetail`。**必须传名单里的真实 entry**,不要像现在这样新造 `.archived(snapshotHash:)`,否则临时对方的称呼又会变回「对方 · 日期」。
   - 找不到 / 解码失败 → 记日志,留在 `.configuring`(结果壳 P6,头部显示当前对方名 + 可点;**不自动 compute**)。

   这里有个细节要处理:P6 态头部目前在「无选中」时才显示「选择对方」。有选中但没缓存时,头部显示这个人,内容区要给一行说明和一个「重新合盘」入口(调 `selectPartner(entry, force: true)`)。文案走 L10n 新键。
5. 无选中 → 名单空走 P5,名单非空走 P6,和现在一致。

`tryRestoreDetail()` 里按 createdAt 猜最新一对的逻辑,只在 R5 迁移时用一次来确定初始选中,之后删除或并入迁移函数。

### 2.4 补时辰 remap

- `CompatibilityRosterPersistence.remapHash(from:to:)`(`AddHourSheet.swift:219` 调用)改为操作 `compat.rosterV2`:`.archived` 的 hash 和 `.temp` 的 `resolvedHash` 命中老 hash 的都换,`selectedEntryID` 里内嵌的 `archived:<hash>` 同步换。personAHash 逻辑不变。
- VM 的 `applyHashRemap` 已处理内存侧,补一行 `persistRoster()`。

### 2.5 清理

- `clear()` 同时删 `compat.rosterV2` 和老 `compat.roster`。
- 更新 `CompatibilityRosterPersistence.swift` 文件头注释(现在写着「红线 D6:名单只存 hash,不存完整 RosterEntry」,要改成本次决策)。
- `RosterEntry.swift` 头注释里「alias 会话内显示」同步改。

## 3. 换人 sheet 顺带修的三处

1. **管理模式下点行会误换人**(`PartnerPickerSheet.swift` → `partnerRow` 的 `onTap`)。管理模式下整行点击应当无效,只有「修改 / 移出」按钮响应。在 `onTap` 开头加 `guard !isManageMode else { return }`。选中圈在管理模式下已替换为按钮,行底选中色也已关闭,不用改。
2. **命主无时辰时「移出 / 修改」点不了**(`PartnerRow`)。外层 `Button` 的 `.disabled(isLocked || isFullBlocked)` 把行内按钮一起禁了。改成:外层行点击仍按原条件禁用;管理模式下的「移出 / 修改」不受 `isLocked` 影响(整理名单与能不能合盘无关)。注意内层按钮不能继承外层 disabled——把 `.disabled` 挪到只包行主体的部分,或者在管理模式下不给外层加 disabled。
3. **补时辰后多余的一次重算**(`CompatibilityView.refreshAfterAddHour`)。现在只要发生 remap 就强制重算当前对方。改成:remap 的 old hash 是**当前对方的 B hash** 或**命主 A hash** 才重算;补的是名单里别人的时辰就只 remap,不重算。

另外把两处裸字面量收进 L10n(zh-Hans + en,跟现有 `hepan.partner.*` 键同一组):`PartnerPickerSheet` 添加行副标题「不建档案 · 填出生信息即可」,以及 VM 里兜底名「对方 · %@」(出现在 `partnerDisplay(for:)` 和 `rebuildSummaryFromCache` 等多处,统一成一个 L10n 函数)。

## 4. 测试(`ios/Tests/Compatibility/`)

新增 `CompatibilityRosterPersistenceV2Tests.swift`,至少覆盖:

- 加 3 个临时对方(带称呼)+ 切换 → 新建 VM 恢复 → 名单 3 人,称呼都在,选中是最后换到的那位。(对应 A、B、F)
- 最后一次合盘失败 → 恢复后名单不变。(C)
- 移出当前对方 → 恢复后此人不在名单,无选中,不发请求。(D)
- 加入未算过的人 → 恢复后仍在名单,`resolvedHash == nil`。(E)
- 选中者有缓存 → 恢复直达 detail,displayName 是称呼不是兜底名,orchestrator 零调用。
- 选中者无缓存 → 恢复后 `.configuring` + 选中保留 + orchestrator 零调用。
- `.archived` 快照被删 → 恢复时剔除;`.temp` 的 resolvedHash 快照被删 → 保留成员、resolvedHash 置 nil。
- 老 key `compat.roster` 迁移:转成 `.archived` 成员、老 key 被删、选中按 createdAt 最新定。
- 损坏 JSON → 名单空 + key 被删 + 有 error 日志(不崩)。
- remap:`.archived` hash、`.temp` resolvedHash、`selectedEntryID` 三处都换。
- 恢复过程中不触发写入(恢复前后 UserDefaults 除清理外不变)。

`AddHourFlowTests.swift:307-320` 直接用了老的 `save(personAHash:context:rosterHashes:)` / `load()`,要按新 API 改写;`CompatibilityViewModelBatchTests` / `CompatibilitySelectPartnerTests` 里依赖「恢复只剩 hash」的断言按新行为调整,并在 commit Impact 段说明。

sheet 三处小修各加一条:管理模式点行不触发 `onPick`(可以把判断抽成纯函数测);命主无时辰时移出可用;补他人时辰不重算当前对方。

## 5. 约束

- 零后端、零 prompt 改动;不加依赖。
- UserDefaults 以外不新增存储;**不**把名单写进 SwiftData,**不**进 SyncManager。
- 错误显式传播:不空 catch,不用 `try?` 吞编码/解码错误。
- 新文案走 `L10n.swift` + `Localizable.xcstrings`(zh-Hans + en,与现有目录一致)。
- 新 .swift 文件 pbxproj 4 处登记一致 24 位 ID。
- commit 三段式(Why / What / Impact);建议拆两个 commit:名单持久化一个、sheet 三处小修一个。
- 文档回写:`docs/合盘多选设计决策.md` D5、D6 各追加一行「2026-09-30 修订 → 见 `docs/合盘名单持久化修复-plan.md` R1-R5」;`docs/合盘结果页主页化-plan.md` 顶部加一行指向本文件。

## 6. 验收(真机或模拟器手测)

1. 加小王(带称呼)、妈妈、Lisa,换到妈妈,杀 App 重开 → 直接显示和妈妈的结果;面板里 3 人都在,称呼都对。
2. 关网,换到 Lisa(失败),杀 App 重开 → 3 人都在,选中 Lisa,显示 P6 +「重新合盘」入口。
3. 移出 Lisa(当前对方),杀 App 重开 → Lisa 不在,头部「选择对方」。
4. 管理模式点行的空白处 → 什么都不发生。
5. 命主无时辰时,管理模式能移出人。
