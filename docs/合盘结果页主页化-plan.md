# 合盘「结果页主页化 + 人物牌换人」— 评估与实施计划

> 日期:2026-09-29 · 状态:**方向已采纳,待实施**
> 参考交互稿:https://claude.ai/artifact/1ArvwigqyRxQk5vzu4ykxn(只借**交互**,不借视觉/数据)
> 上游决策:`docs/合盘多选设计决策.md`(D1-D13)、`docs/时辰未知设计决策.md`(S07/S10/S11)、`DESIGN.md`(水墨孤本)
> 本文件面向实施者(另一个 AI):读完即可开工,每个 slice 独立可 demo。
> **后续修订(2026-09-30)**:名单持久化仍是 09-07 单选时代写法,已由
> `docs/合盘名单持久化修复-plan.md`(R1-R5)修订——完整名单 + 选中持久化到
> `compat.rosterV2`,本文件的 S1-S5 不受影响。

---

## 0. 评估结论

**采纳。** 交互稿把「选人」从一个整页配置态收进结果页顶部的人物牌 + 底部 sheet,换人不离开结果页。这与 2026-09-07「单选直达 detail + 跨启动恢复上次那位」的演进方向一致——现在结果页事实上已是主路径,配置页只是中转;本改动把它做彻底。

| 维度 | 现状 | 交互稿 | 判断 |
|---|---|---|---|
| 换人路径 | detail → 左上「编辑名单」→ 配置页勾人 → 「开始合盘」→ 推演 → detail(4 步,离页) | 点人物牌 → sheet 点人 → 原地刷新(2 步,不离页) | **采纳** |
| 首次进入(有命主、名单空) | 配置页空名单 + 「开始合盘」CTA(置灰) | 页面直接给添加表单,提交即合盘 | **采纳** |
| 日主关系表达 | 双柱中轴只有「合」印;关系词在评估卡 | 中轴写明「甲木生丁火 · 相生」 | **采纳**(方向客户端派生,见 S4) |
| 解读卡「移到 tab bar 上方」 | 系统 TabView,ScrollView 自动避让 | Web 稿 tab bar 是浮层才需要 | **不适用**,不做 |
| 视觉(Noto 字体 / 实底卡片 / 胶囊 CTA / 1.35 印章) | 水墨孤本 token | 偏离 DESIGN.md | **不采纳**,全部沿用现有 token |
| 表单(称呼/日期/时辰默认「不确定」/性别默认女) | 称呼/日期/时刻/性别(未选)/出生地(必选) | 字段缺出生地,默认值替用户做决定 | **不采纳**,沿用现有表单 |
| 同步标签(一强一稳/需要磨合) | 后端枚举:同步走强/同步承压/运势分化/难以定性 | 编造 | **不采纳**,UI 只显示后端值 |
| 解读卡(「本月 3 次 · 6 章」) | 按日重置;免费章 + 付费 4 章锁 + 多态 | 过度简化 | **不采纳**,沿用 `CompatibilityInterpretationSection` |

---

## 1. 决策(本次拍板,实施者按此执行)

- **P1 主页 = 结果页。** 合盘 tab 在「有已选对方」时恒显示结果壳(`ResultShell`):顶部人物牌头 + 下方内容区。内容区随 VM 状态切换:推演中 / 结果 / 单对失败 / 时辰拦截——**全部原地呈现,不跳页**。
- **P2 人物牌头(`PartnerHeader`)。** 左「我」(日主 + 生日,纯展示;命主无时辰时显示「补时辰」入口,沿用 S07 语义);中「合」SealStamp;右对方牌(称呼 + 日主 + 生日 + ▾),点击开 `PartnerPickerSheet`。无已选对方时右侧为 dashed「＋ 添加对方」占位(dashed = 临时态,符合 DESIGN.md)。
- **P3 换人 = 选中 + 立即合盘。** sheet 内点一位 → 关 sheet → `vm.selectPartner(entry)`(内部:单选让位 + `compute()`)。点当前已选者 = 仅关 sheet,不重算。推演中再换人 → 复用 `compute()` 内已有的 `computeTask?.cancel()`。
- **P4 从 sheet 添加 = 加入即选中并合盘。** **修订 2026-09-03「添加与勾选解耦 / 新行未勾选」**:旧解耦的前提是「配置页上先攒名单再点开始合盘」,新模型没有「开始合盘」这一步,用户在 sheet 里添加一个人的意图就是「看和他的合盘」。名单成员资格与勾选的**数据层**解耦保留(移出 ≠ 取消勾选),只是添加成功后由 UI 调 `selectPartner`。
- **P5 首次进入(命主存在、名单为空、无可恢复 detail)。** 结果壳头部 + 内联添加表单(与 sheet 内同一表单组件),提交 = 加入 + 选中 + 合盘。**不再出现「开始合盘」按钮与空名单页。**
- **P6 名单非空但无已选(恢复失败 / 刚移出当前对方)。** 结果壳头部(右侧「选择对方 ▾」)+ 一行留白说明「点右上选择对方」,不自动弹 sheet。移出当前对方时**不自动选下一个**(避免隐式发起合盘请求)。
- **P7 「编辑名单」toolbar 按钮删除**;`.configuring` 整页配置视图退役;`.list` 兜底态并入结果壳内容区(单对失败卡 / 拦截卡)。
- **P8 `.empty`(0 存档,无命主盘)保持现状**(`CompatibilityEmptyView` 引导去深度解析),本次不动。
- **P9 零后端 / 零 prompt 改动。** 不动 `backend/`、`app/ai/prompts.py`、`PromptContextBuilder*.swift`、`ModuleDefinitions.swift` → 无需跑 `check_prompt_sync.py` / evalkit。若实施中发现必须动,**停下来问用户**。

### 红线(继承,不可破)

- D4:每对独立 entitlement / 付费墙 / 次数池,零改动
- D6:临时人隐式落地 ChartSnapshot **不建 UserSnapshotLink**
- D10:单对失败隔离 + 单对重试(不触付费/次数)
- D13:切 tab / 换人 → cancel 进行中的 computeTask
- S07/S10/S11:任一方无时辰 → 整对拦截(免费亦拦),拦截态给补时辰 CTA;命主无时辰 → 名单全锁
- 名单上限 `rosterMax = 8`
- 错误显式传播(CLAUDE.md):不静默吞,不用默认值掩盖

---

## 2. 目标状态机与视图结构

VM 枚举 `CompatibilityViewState` **不改 case**(降低风险;`.configuring` / `.list` 保留作语义状态),只改渲染映射与入口:

| VM state | 条件 | 渲染 |
|---|---|---|
| `.loading` | — | 不变 |
| `.empty` | 0 存档 | 不变(P8) |
| `.configuring` | 名单空 | `ResultShell` + 内联添加表单(P5) |
| `.configuring` | 名单非空、无已选 | `ResultShell` + 「点右上选择对方」(P6) |
| `.computing` | — | `ResultShell` + 内容区原地推演态(复用 `CompatibilityCastingView` 的三墨点 breathe,去掉 i/N,单选恒 1 对) |
| `.list` | 单对失败 / 拦截 | `ResultShell` + 内容区单卡(复用 `PairSummaryCard` 的 failed / hourUnknownBlocked 布局与回调) |
| `.detail` | — | `ResultShell` + 现 `CompatibilityMainView` 内容 |
| `.failed` | 全局失败 | 不变(ErrorStateView) |

`ResultShell` 头部的「当前对方」取自 `vm.selectedEntryIds` 对应的 roster entry(`.computing` / `.list` 期间也要能显示对方名 → VM 新增 `currentPartner: PartnerDisplay?` 派生属性,单一事实源,供头部与 sheet 勾选态共用)。

---

## 3. Slices(串行依赖,每个独立可 demo)

| Slice | 标题 | Blocked by | 一句话 |
|---|---|---|---|
| S1 | 人物牌头 + 原地换人(tracer bullet) | 无 | 头部人物牌 + sheet 复用现有名单行,点人原地推演→结果 |
| S2 | PartnerPickerSheet 完整化 | S1 | 勾选态、管理(移出/修改)、sheet 内添加(加入即合盘)、时辰拦截行、满员 |
| S3 | 首次进入与无已选态 | S2 | 名单空 → 内联表单;非空无已选 → 提示;配置页退役 |
| S4 | 结果页细节:日主方向中轴 + 换人动效 | S1 | 中轴「甲木生丁火 · 相生」+ 换人时印章重盖 / 内容 ink-in |
| S5 | 清理与文档回写 | S3 S4 | 删 toolbar/配置页/列表页死代码,pbxproj,USER_STORIES / 决策文档回写 |

---

### S1 人物牌头 + 原地换人(tracer bullet)

**What to build**
1. 新文件 `Features/Compatibility/PartnerHeader.swift`:`PartnerHeader(me:, partner:, isSelfHourUnknown:, onTapPartner:, onAddSelfHour:)`。
   - 布局:三栏 `HStack`,左「我」、中 `SealStamp("合", size: 26, rotation: -4)`、右对方牌 Button(称呼 `BaziFont.display` 15.5 / 副行 `日主 X · yyyy-MM-dd` caption tabular-nums / 尾 `chevron.down` inkMuted)。
   - 容器:**无底色**,底部 hairline 收边(卡片让位 hairline);对方牌可点区域 hairline 描边 `RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)`,**不用 Capsule**。
   - 无对方:dashed hairline 框「＋ 添加对方 / 选择对方」。
   - 无障碍:对方牌 `accessibilityLabel("切换对方,当前 X")` + `.isButton`;头像字(日主)按五行着色用 `BaziTheme.elementColor`。
2. 新文件 `PartnerPickerSheet.swift`(S1 最小版):`.presentationDetents([.medium, .large])`,内嵌 `NavigationStack`(为 S2 表单 push 预留),列表先直接复用 `RosterUnifiedListView`(行点击回调改为调 `onPick`)。
3. VM 新增:
   - `func selectPartner(_ entry: RosterEntry)`:若已是唯一已选且 state 为 `.detail` → no-op;否则走现有单选让位逻辑(`toggleEntrySelection` / `toggleArchived` 的「选中」分支,**不要**复制逻辑,抽出公共私有方法)后调 `compute()`。
   - `var currentPartner: PartnerDisplay?`(称呼 / 日主 / 生日 / entry id),由 `selectedEntryIds` + roster + archivedCharts 派生。
4. `CompatibilityView`:`.computing` / `.list` / `.detail` 三态外包 `ResultShell`(头部 + 内容);`.computing` 内容区用内联推演态(不再全屏)。

**验收**
- 有上次对方 → 冷启动直接见结果页 + 头部显示对方名;点对方牌弹 sheet;点另一位 → sheet 关、内容区推演态、算完原地出结果;头部名字立即切换(推演开始即切)。
- 推演中再次换人 → 上一个请求被 cancel(日志 `compatVM.compute.start` 两次,首个无 `.ok`)。
- 单对失败 → 内容区失败卡 + 「重试这一对」可用(`retryPair` 守卫当前要求 `.list`,保持)。
- 时辰拦截对 → 内容区拦截卡 + 补时辰 CTA(沿用 `onAddHour` 路由)。
- 单测(`ios/Tests/Compatibility/`,新增 `CompatibilitySelectPartnerTests.swift`):selectPartner 同人 no-op / 换人触发 compute 并单选让位 / currentPartner 派生正确 / 推演中换人 cancel。

---

### S2 PartnerPickerSheet 完整化

**What to build**
- 新行组件 `PartnerRow`(替换 sheet 内对 `RosterUnifiedListView` 的复用):日主字(五行色)/ 称呼 + 副行(生日 · 日主)/ 尾部选中态。
  - 选中态:**朱色描边小圆 + 勾**(沿用现 RosterUnifiedListView 的「行内朱圈」表达;朱红属印章级小元素的既有用法,不扩大)。
  - 他人无时辰行:副行换成 `L10n.CompatibilityRosterGate.mark`,点击 → `onAddHour(hash)`(S10 路由),临时对方无 hash → 显示 S11 置灰短注,不可选。
  - 命主无时辰:整列置灰不可点 + 顶部 banner(沿用 `L10n.CompatibilityRosterGate.selfBanner`)。
- 标题栏:「选择对方」+ 右侧文字按钮「管理 / 完成」(ink 色,**不用朱红**)。
- 管理模式:行尾换「修改」(仅临时人)+「移出」;移出走现有 `confirmationDialog` 文案(「移出后,重新加入需再填一次出生信息」)。移出当前对方 → `selectedEntryIds` 清空 → 主页进 P6 态。
- 尾部「＋ 添加对方」行 → NavigationStack push 添加表单页。
  - 表单:**把 `CompatibilityConfigView.swift` 内 `private struct AddPersonSheet` 的表单主体抽成 `PartnerBirthForm.swift`**(称呼 / 出生日期行 / 出生时刻行 / 性别 / 出生地 `CityPickerField` / 错误行 / 提交按钮),字段、默认值(日期 nil、性别 nil、出生地必选)、校验、wheel sheet 行为**一律不变**。
  - 提交成功(P4)→ `addTempToRoster()` 返回 entry → `selectPartner(entry)` → 关 sheet。失败 → 错误留在表单内(现行为)。
  - 修改模式:复用同一表单,`beginEditTempEntry` / `updateTempEntry`;若改的是当前对方且输入变化 → 保存后对该人重新 `selectPartner`(强制重算,绕过同人 no-op:加参数 `force: true`)。
- 满员(`roster.count >= rosterMax`):添加行置灰 + 「名单已满 8 人,先移出一位」。

**验收**
- sheet 内添加一个新人 → 保存 → sheet 关、原地推演、出结果,头部为新人。
- 管理 → 移出非当前人:列表更新,结果不变;移出当前人:主页进 P6 态,不发请求。
- 修改当前临时对方的日期 → 保存后自动重算;修改非当前对方 → 不重算。
- 无时辰行点击走补时辰 sheet;命主无时辰整列锁。
- 满员添加行不可用。
- 单测:P4 添加即选中 / 移出当前人清选且不 compute / 修改当前人 force 重算。

---

### S3 首次进入与无已选态

**What to build**
- `.configuring` + 名单空 → `ResultShell`(右侧 dashed「＋ 添加对方」)+ 下方留白说明(楷体 caption:「不建档案,填出生信息即可。以后点右上人物牌换人」)+ 内联 `PartnerBirthForm`(提交 = 加入 + `selectPartner`)。点头部占位 = 滚动到表单并聚焦称呼(不开 sheet)。
- `.configuring` + 名单非空无已选 → `ResultShell`(右侧「选择对方 ▾」)+ 一行 inkMuted 说明,点头部开 sheet。
- 命主无时辰:头部左侧「补时辰」入口 + banner;表单/列表按 S07 全锁语义置灰。
- `CompatibilityView` 不再渲染 `CompatibilityConfigView`。
- 跨启动草稿(`CompatibilityRosterPersistence` temp draft)在内联表单与 sheet 表单间共用同一 VM 字段(现状即如此,确认不回归)。

**验收**
- 新用户(只有命主盘)进合盘 tab:看到头部 + 表单,**无「开始合盘」按钮**;填完提交直接出结果。
- 旅程 C 端到端无断点:Tab 合盘 → 填表 → 结果 → 换人 → 结果。

---

### S4 结果页细节:日主方向中轴 + 换人动效

**What to build**
- `DualPillarsTable` 中轴:现「hairline —[合]— hairline」改为「hairline — 文字 — hairline」+ 保留小「合」空心印。文字 = `日主 {A日干}{A五行}{生|克}{B日干}{B五行} · {后端 dayMasterRelation}`,同气时 `{A日干}{B日干}同气`。
  - **方向**客户端派生(纯五行生克映射,非历法计算,不违反「客户端不做历法计算」):数据源 `DualPillarSource` 日柱的 `ganA/ganB/ganElementA/ganElementB`。新增纯函数 `DayMasterRelationPhrase.make(...)`,放 `Shared/` 或 Compatibility 目录。
  - **一致性守卫**:派生出的类别(同气/相生/相克)必须等于后端 `qualitativeAssessment.dayMasterRelation`;不等 → `AppLogger.error` + 只显示后端标签(不静默,不猜)。
  - 文案进 L10n(见 §4),en 版给等价表达。
- 日柱强调:日柱列上下两格外加一个 hairline 描边 `RoundedRectangle(cornerRadius: 4)`(**不加实底色**,卡片让位 hairline);柱头保持「年/月/日/时」,日字 ink 实色、其余 inkMuted。
- 换人动效(仅 detail 内容因对方变化而重建时):
  - `SealStamp`(头部「合」)`.id(compatibilityHash)` 触发 stamp(1.9→1 spring,DESIGN.md 标准,**不用** 1.35)。
  - 内容区 ink-in(opacity 0→1 + blur 7→0,DESIGN.md §Motion)。
  - `accessibilityReduceMotion` → 全部直出静态。
  - 冷启动恢复 / 首次出结果也播(与换人一致),推演态 → 结果态之间不额外加转场。

**验收**
- 三种关系(同气 / 相生 / 相克)与 A→B、B→A 两个方向各一条单测(`DayMasterRelationPhraseTests.swift`);一致性守卫不等时的回退路径一条单测。
- reduce-motion 开启时无动画。
- 截图对照:无实底卡片、无 Capsule CTA、朱红只出现在印章与选中圈。

---

### S5 清理与文档回写

- 删除:toolbar「编辑名单」两处;`CompatibilityConfigView.swift` 中不再使用的整页配置视图、`CompatibilityConfigCTAModel`(及其测试)、`AddPersonSheet`(已抽成 `PartnerBirthForm`);`CompatibilityPairListView` 的整页列表 + 底部「编辑名单」inset(`PairSummaryCard` 保留,S1 在内容区复用)。`RosterUnifiedListView` / `PersonARowView` 若已无引用一并删除。先 `grep` 全仓确认无引用再删。
- `backToConfig()`:无调用方则删除;若仍被补时辰刷新等路径使用,改名为语义化的 `clearDetailKeepRoster()` 并更新注释。
- `project.pbxproj`:新增文件每个 **4 处登记、一致 24 位 ID**(objectVersion 56 传统结构,漏登记 = 静默不编译);删除文件同步移除 4 处。
- 文档回写:
  - `USER_STORIES.md`:US-COMP-01 验收标准(删「底部 CTA 开始合盘」,改人物牌 + sheet)、旅程 C 流程图。
  - `docs/合盘多选设计决策.md`:D1 交互形态 / D11 增删入口 追加「2026-09-29 修订 → 见本文件 P1-P7」;09-03「添加与勾选解耦」条注明被 P4 部分修订。
  - `CompatibilityView.swift` 顶部状态注释同步 §2 表。

**验收**:全量单测绿;Xcode build 无警告新增;`grep -rn "编辑名单\|开始合盘" ios/` 仅剩历史注释或为 0。

---

## 4. 实施者通用约束(每个 slice 都适用)

- **UI token**:只用 `BaziTheme` / `BaziFont` / `BaziTheme.Spacing` / `BaziTheme.Radius` 现有 token;任何新颜色 / 字号 / 圆角 / 动效先读 `DESIGN.md`,偏离须用户批准。禁 Capsule(chip 除外)、禁渐变、朱红仅印章级小元素、CTA radius 5。
- **i18n**:新增用户可见文案一律走 `L10n.swift` 键 + `Resources/Localizable.xcstrings`(zh-Hans / zh-Hant / en 三语),对齐 2026-09-24 字面量收编做法;不要新增裸中文字面量。
- **错误**:不空 catch、不 `try?` 吞业务错误;失败要么 UI 显式、要么 `AppLogger.error` + 显式回退(并说明回退理由)。
- **不加依赖**。
- **不动后端 / prompt**(P9)。
- **commit 三段式**:每个 commit body 含 Why / What / Impact;一个 slice 至少一个 commit。
- **测试位置**:`ios/Tests/Compatibility/`;现有 `CompatibilityViewModelBatchTests` 等必须保持绿(修订 P4 引起的断言变更需在 commit Impact 段说明)。

## 5. 不做

- 多人同时合盘 / 名单排序规则变更 / 最近对方置顶
- 解读卡结构调整(位置、章节、次数口径全部不动)
- 同步标签新档位(一强一稳 / 需要磨合 等)——如需细分,另立后端决策
- `.empty`(无命主盘)态改版
- 交互稿中的 Noto 字体、实底卡片、胶囊按钮、1.35 印章、默认时辰「不确定」、默认性别

## 6. 风险

| 风险 | 缓解 |
|---|---|
| P4 修订 09-03 解耦,老测试断言「添加后未勾选」会红 | 数据层 `addTempToRoster` 行为不变(仍不勾选),选中由 UI 显式调 `selectPartner`;老测试多数应保持绿,红的逐条确认后改并在 commit 说明 |
| sheet 内 NavigationStack + 表单内 wheel sheet 嵌套 | 表单里的日期/时刻 wheel 已是 `.sheet`,在 sheet 内再弹 sheet iOS 17 支持;S2 真机验一次 |
| 推演中换人 / 切 tab 的竞态 | 全部走 `compute()` 内既有 cancel;`selectPartner` 不另起 Task |
| 补时辰 sheet 关闭后刷新(`refreshAfterAddHour`)依赖 `.configuring` 判断 | S1 时检查该函数,在结果壳下也要能对当前对方重算(补完时辰后对当前对方 `selectPartner(force: true)`) |
