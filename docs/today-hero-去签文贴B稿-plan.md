# 今日 hero 去「今日一签」、光晕改为衬底（贴 B 稿）· 实施方案

> 2026-10-15 · 状态：**已拍板，待实施**
> 给实施 AI 的改动说明。动手前先读 `DESIGN.md`（CLAUDE.md 强制），再读本文 §0、§1。
> 设计事实源：设计画布「今日页 · 窗影改稿」→ 画板 **B · 光晕（完整长页）**（`project/Halo.dc.html`，390×1200）。
> 前置：10-14 commit `686eb47`（hero 换 B 光晕 + 竖排今日一签）、10-15 commit `935c65a`（光晕配色接入）。本方案在它们的基础上改。

---

## 0. 一句话

用户看了 B 稿和 iOS 现状后拍板：**iOS 版 hero 多出来的那两句竖排签文（「今日一签」）不要了，要和 B 稿一模一样。** B 稿里光晕没有单独占一块舞台，它是**铺在日期头部、chips 和宜忌下面的一层衬底**，宜忌紧跟在 chips 下方。所以这次要做两件事：

1. 删掉「今日一签」：竖排两句签文、左下「—— 今日一签」小标、`HeroDailyLot` 静态表和对应测试；
2. 去掉 340pt 的光晕独立舞台，把光晕改成头部 + chips + 宜忌区域的**背景层**，宜忌直接接在 chips 下面。

光晕的**配色、取色规则、四团光参数和动效**（10-15 已落地的 `HaloColors` / `HaloPalette` / 尺寸 / 透明度 / 漂移）**一律不动**。

---

## 1. 范围

### 现状 vs 目标

| | 现状（iOS，`935c65a`） | 目标（B 稿） |
|---|---|---|
| 头部日期区 + chips | `DailyHeaderSection` | 不变 |
| 光晕 | chips 下方单独一块 340pt 高的舞台，左右 17pt 边距 | **没有独立舞台**：光晕铺在头部 / chips / 宜忌**后面**，全屏宽，跟内容一起滚动 |
| 竖排「今日一签」两句 + 小标 | 在光晕舞台左侧 | **删除** |
| 宜忌双列 | 在光晕舞台下方，离 chips 约 340pt | **紧跟 chips**（B 稿 `.block` 上间距 30） |
| AI 解读 / 页脚 / 补时辰行 | 不变 | 不变 |

### 要做

| # | 内容 | 文件 |
|---|---|---|
| A | 把光晕抽成独立 View `HaloBackdrop`（光晕层 + 漂移状态 + 动画），不带任何文字 | `DailyImageHeroSection.swift` |
| B | `DailyImageHeroSection` 删掉光晕舞台、签文、小标，只剩宜忌双列 + 无障碍 label | 同上 |
| C | 删除 `enum HeroDailyLot` 整段（签文三语表 / fallback / caption / lines） | 同上 |
| D | 主布局：头部 + chips + 宜忌包进一个容器，光晕作为它的 `.background`；宜忌直接接在 chips 下 | `DailyFortuneMainView.swift` |
| E | 测试：删签文测试、EN 零 CJK 扫描里去掉签文条目 | `ios/Tests/DailyFortune/DailyImageHeroCopyTests.swift` |
| F | 注释 + `DESIGN.md` Decisions Log 补一条 | 上述 Swift 文件头注释 + `DESIGN.md` |

### 明确**不做**（review 时出现就打回）

1. **不动光晕配色和取色**：`HaloColors`、`HaloPalette`、四团光的尺寸 / 透明度 / 设计坐标、`drift` / `driftScale` / `startCycles` 的参数全部原样保留。现有光晕取色测试（`testHaloPalette*` 那 7 个）一个都不许改。
2. **不加 B 稿里的「今日五行」竖条图和「金气偏旺 · 宜借水木」文字**。理由同 10-15 方案：后端没有当日五行力量数据，示意高度不能上线；「宜借」是喜忌判断，CLAUDE.md 规定只能来自后端规则引擎。
3. **不动 B 稿里的「今日解读」区样式**。iOS 的 `DailyInterpretationSection` 保持现状。
4. **不改 B 稿配色 / 字体**：B 稿 HTML 用的是 Noto Serif SC + `#F1EEE8` 底色，那是画布示意。iOS 保持 `BaziTheme.paper` + 楷体 / 宋体现状（10-14、10-15 已拍板）。
5. **不改 `HeroYiJiColumns` 的词表、字号、列距、hairline**；只改它在页面上的**位置**。
6. 不改 `DailyHeaderSection`（日期行、chips、两个释义 sheet）。
7. 不碰后端、prompt、`PROMPT_VERSIONS`、缓存键。这次是纯 iOS 展示层。
8. **不新建 .swift 文件**（避免 pbxproj 4 处登记）。`HaloBackdrop` 放在 `DailyImageHeroSection.swift` 里。
9. 不加依赖；不用 `.delay(...)` 做错相（沿用现有四周期近似）。
10. 不加任何新的 `LinearGradient` / 背景渐变。光晕仍是 10-14 拍板的 hero 艺术层例外，**例外范围不扩大**（只是位置变了，见 §5）。

---

## 2. 改动 A + B + C：`DailyImageHeroSection.swift`

文件：`ios/QiCompass/QiCompass/Features/DailyFortune/DailyImageHeroSection.swift`

### 2.1 新增 `struct HaloBackdrop: View`（放在 `DailyImageHeroSection` 下方、`// MARK: - 光晕取色` 上方）

把下面这些**原样搬过去**（逻辑和数值都不改，搬完删掉 `DailyImageHeroSection` 里的原件）：

- 输入：`dayPillar: String`、`dayElements: DayElementsDTO?`、`daySignal: [DaySignalItemDTO]?`
- `@Environment(\.accessibilityReduceMotion)`、`@Environment(\.colorScheme)`
- 四个 `@State driftA…driftD`
- `haloLayer`、`halo(_:opacity:width:height:)`、`drift(_:)`、`driftScale(_:)`、`startCycles()`
- `body` = `haloLayer.onAppear(perform: startCycles)`，并保留 `.allowsHitTesting(false)` 和 `.accessibilityHidden(true)`

**舞台高度**：原来 `stageHeight = 340`，`haloLayer` 里 `sy = geo.size.height / 420`（设计坐标是 390×420）。改成衬底后，光晕层的高度直接用 **420pt**，这样 `sy ≈ 1`，四团光正好按 10-15 规格坐标落位。在 `HaloBackdrop` 里定义：

```swift
/// 光晕层高(设计坐标 390×420 原样,1:1 落位;2026-10-15 规格)。
static let height: CGFloat = 420
```

`sx = W/390`、`sy = H/420` 这两行公式**不要改**（屏宽不是 390 时仍按比例换算）。

### 2.2 `DailyImageHeroSection` 瘦身成「宜忌双列 + 无障碍」

改完后大致是这样（属性 `dayElements` / `daySignal` 不再需要，从这个 struct 删掉）：

```swift
struct DailyImageHeroSection: View {
    let dayRelation: String

    var body: some View {
        HeroYiJiColumns(dayRelation: dayRelation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: yiJiAccessibilityLabel))
    }

    /// 无障碍合并 label:宜/忌词(装饰光晕在 HaloBackdrop,不读)。
    private var yiJiAccessibilityLabel: String {
        let yiJi = HeroYiJiColumns.mapping[dayRelation] ?? HeroYiJiColumns.fallback
        return "\(L10n.DailyFortune.yiLabel) \(yiJi.yi.joined(separator: "、")), "
            + "\(L10n.DailyFortune.jiLabel) \(yiJi.ji.joined(separator: "、"))"
    }
}
```

- 原 `heroAccessibilityLabel` 里拼「今日一签: …」的那部分**删掉**，宜/忌部分保留（上面就是）。
- `.padding(.horizontal, 11)` 和 `.padding(.top, 18)` 不在这里加了，交给 `DailyFortuneMainView` 统一管（见 §3）。
- 也可以保留 `dayPillar` 参数不用——**不要**这么做，没用的参数直接删，调用处同步改。

### 2.3 删除

- `// MARK: - 今日一签` 整段：`lotText`、`lotCaption`
- `// MARK: - 今日一签静态表` 整段：`enum HeroDailyLot`（zh / hant / en 三张表、`table(for:)`、`fallback(for:)`、`caption(for:)`、`lines(for:language:)`）
- 删完后全仓 `grep -rn "HeroDailyLot\|lotText\|lotCaption\|今日一签\|今日一籤\|WORD FOR TODAY" ios/` 必须**零命中**（注释里的历史说明也改掉，见 §6）。

---

## 3. 改动 D：`DailyFortuneMainView.swift`

文件：`ios/QiCompass/QiCompass/Features/DailyFortune/DailyFortuneMainView.swift`

现在 `body` 里是：`DailyHeaderSection`（`.padding(.horizontal, 24).padding(.top, 6).inkIn()`）→ `DailyImageHeroSection`（`.padding(.horizontal, 17).padding(.top, 6).inkIn(delay: 0.08)`）→ `DailyInterpretationSection` …

改成：把头部和宜忌包进一个**不加水平 padding** 的 `VStack`，光晕挂在这个 VStack 的 `.background` 上，这样光晕是全屏宽、在文字后面、跟着一起滚动：

```swift
// ===== 头部 + 宜忌(2026-10-15 贴 B 稿:光晕是这一块的衬底,不再单独占舞台)=====
VStack(alignment: .leading, spacing: 0) {
    DailyHeaderSection(...)            // 参数不变
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .inkIn()

    DailyImageHeroSection(dayRelation: response.dayRelationToDayMaster)
        .padding(.horizontal, 28)      // = 原 17 + 11,宜忌左缘位置不变
        .padding(.top, 30)             // B 稿 .block padding-top 30
        .inkIn(delay: 0.08)
}
.frame(maxWidth: .infinity, alignment: .leading)
.background(alignment: .top) {
    HaloBackdrop(
        dayPillar: response.dayPillar,
        dayElements: response.dayElements,
        daySignal: response.daySignal,
    )
    .frame(height: HaloBackdrop.height)
    .offset(y: Self.haloTopInset)
    .inkIn(delay: 0.08)
}
```

要点：

1. **`haloTopInset`**：B 稿里光晕区从页面 y=110 开始，头部从 y=76 开始，所以光晕顶边比头部顶边低约 **34pt**。在 `DailyFortuneMainView` 里加 `private static let haloTopInset: CGFloat = 34`，带注释说明来源。真机截图后可以微调，但只改这一个常量。
2. **不要 clip**：光晕层 420pt 比「头部 + 宜忌」容器高，会往下溢出到「今日解读」标题后面——**这是 B 稿本来的样子**（B 稿光晕下缘压在「今日五行」区上）。不要在这个容器或 ScrollView 内容上加 `.clipped()`，也不要把光晕的 blur 边缘切成矩形。
3. **层级**：光晕必须在文字下面。用 `.background` 就够了，不要用 `ZStack` + `zIndex` 绕。`DailyInterpretationSection` 在 VStack 里排在后面、本身没有不透明底色，光晕溢出部分会透过它显示，这是预期效果。
4. 原 `DailyImageHeroSection(...)` 的 `.padding(.horizontal, 17)` 和 `.padding(.top, 6)` 删掉。
5. `DailyInterpretationSection` 的 `.padding(.top, 24)` **先不动**；如果截图发现宜忌和「今日解读」之间太挤或太空，在 PR 里贴截图给用户定，不要自行调。
6. 离线角标 `if vm.isOffline { ... }` 保持在这个新 VStack **上方**（不放进衬底区）。
7. 文件头注释第 4–6 行（「→ hero 光晕(17pt 边距,2026-10-14 改 B 版:五行光晕 + 竖排今日一签 + 宜忌双列)」）和 `// ===== hero 光晕…` 那段注释同步改成新结构。

---

## 4. 改动 E：测试

文件：`ios/Tests/DailyFortune/DailyImageHeroCopyTests.swift`

1. **删除** `testDailyLotTablesCoverAllRelationsAndFitVertical`（约第 313–330 行）整个用例，以及它上方 `// MARK: - 今日一签 + 光晕取色(2026-10-14 B 光晕 hero)` 改成 `// MARK: - 光晕取色`（或直接删掉这行 MARK，下面已经有 `// MARK: - 光晕取色(2026-10-15 规格…)`）。
2. `testEnBaseLayerStaticTextsHaveNoCJK` 里删掉这三行和它上面的注释：
   ```swift
   // 今日一签(2026-10-14 B 光晕 hero)+ 小标 + 兜底
   for lines in HeroDailyLot.en.values { texts += lines }
   texts += HeroDailyLot.fallback(for: .en)
   texts.append(HeroDailyLot.caption(for: .en))
   ```
3. 光晕取色的 7 个用例（`testHaloPalette*` 等）**不改**。它们测的是 `HaloPalette`，和 View 搬家无关。
4. 不需要新增测试（这次是删内容 + 改布局，布局靠截图验收）。

---

## 5. 改动 F：注释与 `DESIGN.md`

### 5.1 `DailyImageHeroSection.swift` 文件头注释（第 3–25 行）

改写成新结构，要点：
- 今日 hero = 光晕衬底（`HaloBackdrop`）+ 宜忌双列（`DailyImageHeroSection`），**2026-10-15 用户拍板去掉「今日一签」，光晕改为头部 / chips / 宜忌的衬底，贴 B 稿**；
- 光晕取色那段（「主晕 = 流日天干五行…」）原样保留；
- 「**今日一签**:按流日十神查静态表…」那段删除；
- 「DESIGN.md 破例」那段保留，补一句：光晕现在铺在头部和宜忌文字后面，仍是 hero 艺术层，不是整页背景——只覆盖页面顶部约 420pt，页面底色仍是纯色宣纸。

### 5.2 `DESIGN.md` Decisions Log

在 2026-10-15 那一行**之后**新增一行（不要改 10-14 / 10-15 两行的原文）：

| 日期 | 决策 | 说明 |
|---|---|---|
| 2026-10-15 | **Today hero 去「今日一签」，光晕改为头部 + 宜忌的衬底（贴 B 稿）** | 用户对照画布 B · 光晕与 iOS 实机后拍板：B 稿没有签文，iOS 多出的两句竖排签文删除（`HeroDailyLot` 及测试一并移除）；光晕不再占 340pt 独立舞台，改为头部 / chips / 宜忌区的 `.background`（全屏宽、420pt 高、顶边低于头部 34pt、溢出不裁切），宜忌紧跟 chips（上间距 30）。光晕色板 / 取色规则 / 四团光参数 / 动效不变。光晕「禁止渐变背景」例外范围不扩大：仍只是页面顶部的 hero 艺术层，页面底色纯色宣纸。B 稿的五行竖条与「宜借」提示语仍不采纳（理由同 10-15）。 |

---

## 6. 验收

### 6.1 代码层（必须全过才能提交）

1. `grep -rn "HeroDailyLot\|lotText\|lotCaption\|今日一签\|今日一籤\|WORD FOR TODAY" ios/` → **零命中**。
2. `grep -rn "stageHeight" ios/` → 零命中。
3. `xcodebuild` 编译通过，`DailyImageHeroCopyTests` 全绿（预期 24 个，原 25 个减去签文用例）。如果本环境没有 Swift 工具链，**在 commit message 里写明"未编译，需 Xcode 构建 + 测试确认"**，不要声称已验证。
4. 每日运势相关其他测试（`ios/Tests/DailyFortune/` 下全部）全绿。
5. 本次不涉及 prompt / SKU / 术语 / 城市库 / context_token，CLAUDE.md 里那些守护脚本**不需要跑**。

### 6.2 视觉层（截图给用户目验，放 PR 或交接说明里）

对照画布 B 稿，截以下 6 张（iPhone 15 / 393pt 宽即可）：

| # | 场景 | 看什么 |
|---|---|---|
| 1 | 亮色 · 中文 · 庚申日（金） | 没有签文；宜忌紧跟 chips；主光团在右侧宜忌 / 「忌」列后面，伴光在左上；整体和 B 稿构图一致 |
| 2 | 暗色 · 中文 · 同一天 | 光晕仍压到 0.55，不像霓虹；宜忌文字可读 |
| 3 | 亮色 · 繁体 | 同 1 |
| 4 | 亮色 · English | 同 1；EN 宜忌（Do / Don't）不换行 |
| 5 | 向下滚动到「今日解读」 | 光晕下缘自然洇进解读标题区，**没有矩形切边**；光晕跟着内容滚，不是固定背景 |
| 6 | 系统设置开「减弱动态效果」 | 光晕静止 |

**文字对比度**：宜忌条目（墨色宋体 15）压在主光团（0.85 不透明度）上，要肉眼确认可读。如果某个五行色（尤其火 `D77855`、土 `C8A069`）压字明显发糊，**不要自己改透明度或色值**——截图标出来，交给用户决定（可选方案：只调 `haloTopInset` 让主光团下移，或用户另批透明度）。

---

## 7. 提交

- 一个 commit 即可：`feat(ios): 今日 hero 去「今日一签」,光晕改为头部+宜忌衬底(贴 B 稿)`
- commit message 按 CLAUDE.md 三段式（Why / What / Impact）。Impact 里写清：纯 iOS 展示层，后端 / prompt / 缓存键零变更；`HeroDailyLot` 删除；光晕参数不变。
- 不要 rebase / force-push 别人的分支；在用户指定的分支上提交。
- 实施完成后在本文件顶部把状态改成「已实施」，文末补「实施记录」（commit hash、测试结果、截图结论、与本方案的偏差），格式参考 `docs/today-hero-光晕配色-plan.md`。
