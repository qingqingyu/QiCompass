# 四屏 UI 修复 slices(2026-09-19)

> 范围拍板(用户 2026-09-19):**A 组纯前端视觉(#1/#2/#3/#4/#9)+ C 组内容质量(#7/#12)**,共 7 条。
> 分支策略:**在 paipan 上继续叠加**(已 fast-forward 至 main 460f259)。
> 非目标:B 组 en 翻译补齐 142 条、D 组决策类(#8 身份摘要/#10 付费墙/#11 隐私文案)——均不在本轮。
> 本文档是实施事实源;`四屏UI评审复核-2026-09-19.md` 是复核存档,不作为实施依据(其中行号/断言以本文核实为准)。

## 核对修正(相对复核文档)

复核文档两处表述与当前代码不符,实施以本节为准:

1. **tab bar 是系统 `TabView` + `.tabItem`**(`App/RootTabView.swift:55`),不是自绘悬浮胶囊。评审截图中的悬浮胶囊是 iOS 26 Liquid Glass 的系统浮动 tab bar 形态。**「全项目未见 safeAreaInset」也不准确**——`CompatibilityConfigView.swift:107` 已用 `safeAreaInset(edge: .bottom)` 挂 CTA。遮挡是否发生/量级需在 iOS 26 模拟器实测,不预设 90pt 魔数。
2. `Localizable.xcstrings` 现有 **358 keys**(复核文档记 349),语言只有 zh-Hans + en(zh-Hant 未落地)。本轮新增/改动文案必须同时给 zh-Hans + en;B 组存量漏翻不在本轮范围。

---

## S01 · #1 四屏 ScrollView 底部被浮动 tab bar 遮挡 —— ❌ 实测驳回,零代码改动

**症状**:「我的」页尾部 / 深度页目录尾部内容被底部浮动 tab bar 压住(评审截图)。

**实测(2026-09-19,iPhone 17 Pro 模拟器 iOS 26.5,一次性 auto-scroll 改造滚到底后截图,已还原)**:

| 屏 | 静止位(滚到底) | 结论 |
|---|---|---|
| 今日 | 补时辰提示行完整悬于胶囊上方,~19pt 净距 | 无遮挡 |
| 我的 | 落款(玄机问道 2026)完整在胶囊上方 | 无遮挡 |
| 深度 | 解锁 CTA 完整在胶囊上方 | 无遮挡 |
| 合盘 | safeAreaInset CTA 本就悬于胶囊上方 | 无遮挡 |

胶囊实测几何:上缘离屏底 **83pt**(y=2373/2622px@3x)、下缘 21pt、高 62pt(两图三列交叉验证)。

**判定**:iOS 26 浮动 tab bar **参与 safe area**,静止位内容自动让位;滚动中内容钻到玻璃下是系统设计行为。评审截图(以及复核文档基于「24/18pt < 90pt」的算术推断)把滚动中状态误读为遮挡。复核文档引的 `DeepAnalysisHomeView.swift:74 padding(.bottom,18)` 实为品牌印 overlay 的 padding,深度页 ScrollView 根本无底部 padding——进一步证伪该推理链。

**处置**:不改代码。回复评审者口径:请提供「滚动到底静止位」截图复核,滚动中内容在玻璃下属于 Liquid Glass 设计内行为。

---

## S02 · #2 今日 hero 右上「Clashes: 寅」胶囊英文长词换行 + #12 mappingEn 词表重写

同文件同区域,合并一个 slice。

**症状 (a)**:English 模式下右上 chip 文案 `Clashes: 午 (Year Branch 午)`(`L10n.swift:337-342`)过长,`ChipView`(`DailyImageHeroSection.swift:414-439`)内 Text 无行数约束,折成三行胶囊。**已实测复现**(EN 设备语言截图,`Clas/hes:/亥` 三行)。

**方案 (a)**(已实施):
- `dateRow` 外层改 `ViewThatFits(in: .horizontal)`:先试原 HStack(日期 + chips),放不下时 chips 整组换到日期行下方右对齐——胶囊始终单行。日期区/chips 拆为 `dateInfo` / `chips` 两个子视图避免候选分支重复代码。
- `ChipView` Text 加 `.lineLimit(1)` 兜底。

**症状 (b)**:`mappingEn` 直译单词语义散失(`Take It` / `Push` / `Feud`)。**已实测确认**(EN 截图 Do/Don't 全单词)。

**方案 (b)**(已实施):整表重写为带语境短语,不加行数不破坏 08-31 定稿双列节奏。新词表(用户 2026-09-19 过目拍板;落地时 1 处替换:七杀「硬扛」由提案 `Grind Yourself Down` 改 **`Burn Out`**——19 chars mono 14.5pt 超单列宽 ~163pt 会折行,压到 8 chars):

| 十神 | Do | Don't |
|---|---|---|
| 比肩 | Work Solo / Set Boundaries / Train | Argue / Compare / Follow the Crowd |
| 劫财 | Act Now / Branch Out / Share the Gain | Snap Buys / Lend Money / Force It |
| 食神 | Create / Speak Up / Meet Someone New | Delay / Stay Up Late / Debate |
| 伤官 | Speak Out / Debut Something / Be Frank | Clash / Overstep / Blurt It Out |
| 偏财 | Explore / Try New Things / Give Ground | Bet It All / Overreach / Buy on Credit |
| 正财 | Keep Steady / Track Spending / Stay Grounded | Cut Corners / Rush Deals / Break Promises |
| 七杀 | Make the Call / Take It On / Push Through | Waver / Start Feuds / Burn Out |
| 正官 | Own Your Duty / Play by the Rules / Report Back | Shrink Back / Skip the Chain / Miss Deadlines |
| 偏印 | Reflect / Sit with It / Review Old Notes | Get Stubborn / Overthink / Go It Alone |
| 正印 | Study Up / Take Advice / Rest Well | Lean Too Hard / Daydream / Drag Your Feet |

fallback EN(`Flow/Rest` vs `Force/Rush`)保持不动。

**验收**:English 模式 + 最窄支持宽度(iPhone SE 4 代 375pt 若在支持列表,否则基准机)截图,chip 单行、双列不溢出不换行;zh 模式回归无变化。

---

## S03 · #3 深度 hero 右下竖排喜忌贴边被裁 —— ❌ 不可复现,零代码改动

**症状**:右下竖排「喜水木 · 忌金土」末字贴边被裁(仅评审截图判断,复核文档自认未定位代码)。

**实测(2026-09-19,同一模拟器,真实命盘 hero 右下竖注 2x 放大裁切)**:竖排「喜木·忌土金」六字符全部完整渲染,末字「金」字形完整,右缘余量充足(`/tmp/s03_vert_crop.png`)。

**推算**:即便最长形态「喜火土木金 · 忌水」类(约 13 glyph × ~16pt ≈ 208pt)也在 hero 300pt 高度内;宽度方向恒为单字宽 + trailing 18pt,无裁切路径。评审截图疑似更大字号(辅助功能 Dynamic Type)或视觉误读。

**处置**:不改代码。若用户真机复现,记录机型 + 字号设置再立新案。

---

## S04 · #4 合盘 CTA 禁用态副标对比度塌

**症状**:CTA 禁用态副标「点选后即可排盘 · 名单上限 N 位」几乎不可读,评审误判为「透出另一层文字」。

**定位**:`CompatibilityConfigView.swift:114-144`。三因素叠加:`:133` 整块前景 `inkMuted` → `:137` 底 `inkDeep.opacity(0.3)` → `:128-131` 副标自身 `inkMutedSecondary` + 10pt + tracking 1。副标色是 `inkMuted` 之上的再弱化,叠加后对比度归零。

**方案**:禁用态下副标单独提色——`cta.note` 前景改为 `cta.isEnabled ? inkMutedSecondary : inkMuted`(主标维持 inkMuted 不动,层级关系保留)。一处改动,不动 CTA 结构。

**验收**:禁用态副标在 Light/Dark 下可读(肉眼 + 对比度目测);启用态视觉零变化。

---

## S05 · #9 「今日剩余 N 次」无解释

**症状**:深度页目录右侧「今日剩余 10 次」,用户不知道消耗的是什么、什么时候重置。

**定位**:`DeepAnalysisHomeView.swift:241-251` `tocStatusText`(已读 x/8 → 达限 → 剩余 N 次,三态)。xcstrings 已有 key「24h 内已缓存,不消耗次数」但仅合盘解读区在用(`CompatibilityInterpretationSection.swift:47/:71`),深盘 TOC 未呈现任何解释。

**方案**:TOC 头部状态行下加一行 caption 小注(inkMutedSecondary 10pt):zh「已读章节走缓存,不消耗次数 · 每日重置」en「Cached chapters don't use reads · resets daily」。新增 key,补 zh-Hans + en 双语。达限态重置信息已有(:248),不重复。

**验收**:三态(有剩余/已读/达限)下小注均正确显示且不与状态行挤行;en 模式有英文。

---

## S06 · #7 今日页 AI 失败态降级为次级模块

**症状**:AI 解读失败时,hero 正下方渲染红色大字「命书生成失败」+ Retry,占据次屏主位——而 hero 宜忌是**纯前端确定性查表**(`DailyImageHeroSection.swift:267-269` 注释 + `:273` mapping),页面本体完全正常,却看起来是坏的。

**定位**:`DailyInterpretationSection.swift:68-76` `.failed` 分支:`subheadline` + `shenshaInauspicious`(红) + Retry 按钮,卡片结构不变。

**方案**:`.failed` 分支视觉降级——错误文案降为 caption 级 `inkMuted`(去红色),Retry 保留为 caption 字重链接(ink 色)。卡片外框保留(维持与 hero 两框左右对齐的 09-07 拍板)。**不改状态机语义、不改错误文案内容**(UserFacingError 产出的人话文案原样呈现,只是不再用破坏性色渲染)。

**验收**:模拟器断网/失败注入下截图:hero + 宜忌完整,失败信息可读但不抢主位;Light/Dark 各一张;`.okFree`/`.fetching`/达限态视觉零变化。

---

## 护栏与流程

- **DESIGN.md**:全部修复用既有 token(inkMuted/inkMutedSecondary/hairline 等),不新增色值/字体;#6 方案不引入渐变/新组件语言。
- **xcstrings**:S02(若动 L10n key)/S05 涉及;改动后必须在本 worktree 跑一次全量 build 钉点(xcstrings 损坏是 build 级,2026-09-01 撞车实踩)。
- **pbxproj**:本轮**零新文件**(纯编辑既有 .swift),不涉及 4 处登记。
- **后端/prompt**:零触碰——不跑 evalkit、不跑 check_prompt_sync(未动 `prompts.py` / `PromptContextBuilder*.swift` 的 REQUIRED_FIELDS 与模板)。
- **测试**:每 slice 改完跑受影响用例,收尾全量 `xcodebuild test`(UDID destination + pipefail + xcresulttool 确认用例名,见记忆 reference_ios_xcodebuild_test)。S02 词表如有既有断言(若 mappingEn 有测试)同步更新断言。
- **commit**:每 slice 独立 commit,三段式 body(Why/What/Impact)。不推远端,等用户指令。
- **实施状态(2026-09-19)**:S01/S03 实测驳回零改动;S02/S04/S05/S06 已实施;全量测试 + zh/en 截图回归见 commit 记录。

## 遗留声明(本轮不做,记录防丢)

- B 组:142 条(现核对为更大基数,358 keys 中含 zh 无 en 的)en 漏翻,单独立项。
- D 组:#8 身份摘要统一组件、#10 付费墙六章收成一卡(便宜方案)、#11 隐私文案提权——需决策流程,另开。
- `MONETIZATION.md` 章节拆分过期(记 2+8,实际 2 免费 + 6 付费)——复核文档已声明不同步,本轮同样不动。
