# 今日 hero「光晕」配色接入 · 实施方案

> 2026-10-15 · 状态：**已拍板，待实施**（实施方交给另一个 AI，完成后由 Claude review）
> 分支：`today-hero-halo`（在此分支上继续提交，不要新开分支，不要 rebase / force-push）
> 前置：2026-10-14 已在本分支把 hero 从浅绛山水画卡换成 B「光晕」（commit `feat(ios): 今日页 hero 换 B「光晕」`）。本方案只调**光晕的配色、取色规则和动效参数**。

---

## 0. 一句话

把用户给的「五行光晕视觉规格」里的**主色 + 伴色色板**和**四团光的尺寸/透明度/位置**落进现有 `DailyImageHeroSection`；取色规则改成「主 = 流日天干五行，辅 = 引擎喜用命中优先、否则我生 + 我克」；**不加任何「宜借」文字、不做五行条、不碰后端和 LLM**。

---

## 1. 范围

### 要做

| # | 内容 | 文件 |
|---|---|---|
| A | 新增光晕专用色板（主色 + 伴色，亮色/暗色） | `DailyImageHeroSection.swift` 内新增 `enum HaloColors` |
| B | `HaloPalette` 取色规则改写（字段改名见 §3） | 同上 |
| C | 四团光参数按规格（尺寸、透明度、位置按屏宽换算） | 同上 `haloLayer` / `halo(...)` |
| D | 漂浮动画加 scale 1→1.05，周期对齐 12s | 同上 `startCycles` / `drift` |
| E | 更新单测 | `ios/Tests/DailyFortune/DailyImageHeroCopyTests.swift` |
| F | 更新文件头注释 + `DESIGN.md` Decisions Log 补一行 | 同上 + `DESIGN.md` |

### 明确**不做**（review 时出现即打回）

1. **不加「宜借 / 气偏旺」等任何文字**，不在 hero 或别处显示「{dominant}气偏旺 · 宜借…」。理由：宜借 = 喜用判断，CLAUDE.md 规定喜忌只来自后端规则引擎；「我生 + 我克」只是选色推法，不能以文字形式呈现成命理结论。
2. **不做五行强弱条形图**。后端没有当日五行力量数据，示意高度（92%/34%…）不许上线。
3. **不让 LLM 输出 palette**，不改 `backend/app/ai/prompts.py`，不 bump 任何 `PROMPT_VERSIONS`，不改后端任何文件。
4. **不改页面底色**（保持 `BaziTheme.paper`，即 `#E7E2D5` / 夜宣纸；规格里的 `#F1EEE8` 不采纳）。
5. **不新增颗粒层 / 噪声 PNG / Metal shader**。RootTabView 已全局叠 `PaperGrain()`。
6. **不改 `ElementColors`**（全 app 其他地方在用，降饱和色是它的设计）。光晕色板独立。
7. **不新建 .swift 文件**（避免 pbxproj 4 处登记）。所有新类型放在 `DailyImageHeroSection.swift` 里。如果确实要新文件，必须按 CLAUDE.md 在 `project.pbxproj` 4 处登记一致的 24 位 ID。
8. 不引入任何新依赖。
9. 不使用 `.animation(...).delay(...)` 做错相（见 §5）。
10. 不动 `HeroYiJiColumns`、`HeroDailyLot`、`DailyHeaderSection`、`DailyInterpretationSection` 及签文/宜忌文案。

---

## 2. 色板（A）

新增：

```swift
/// 光晕专用五行色(2026-10-15 用户规格;比 ElementColors 饱和,只用于 hero 光晕)。
/// key 用英文五行 key(同 ElementColors.rawValue:wood/fire/earth/metal/water)。
enum HaloColors {
    static func main(_ key: String) -> Color?
    static func tint(_ key: String) -> Color?
}
```

| 五行 key | 主色 main | 伴色 tint |
|---|---|---|
| metal 金 | `#CDAA64` (205,170,100) | `#B4BCC4` (180,188,196) |
| wood 木 | `#78A06E` (120,160,110) | `#BECD96` (190,205,150) |
| water 水 | `#5F87AF` (95,135,175) | `#A0BED2` (160,190,210) |
| fire 火 | `#D77855` (215,120,85) | `#EBAF87` (235,175,135) |
| earth 土 | `#C8A069` (200,160,105) | `#B99878` (185,152,120) |

- 亮/暗用同一组色值，**暗色只靠透明度系数压低**（见 §4 的 `dim`），不另调色。
- 未知 key → 返回 `nil`；调用方回落 `BaziTheme.inkMuted`（沿用现有 `HaloPalette.color(_:)` 的回落 + 已有的 `op=heroHalo.elementMiss` 日志，不新增静默兜底）。
- 构造 `Color` 用 `Color(red: r/255, green: g/255, blue: b/255)`，与 `ElementColors` 写法一致；不要新增 `Color(rgb:)` 之类的全局 extension。

---

## 3. 取色规则（B）

`HaloPalette` 字段改名并改语义：

```swift
struct HaloPalette {
    let dominantKey: String?   // 主五行
    let support0Key: String?   // 辅一
    let support1Key: String?   // 辅二
    init(dayPillar: String, dayElements: DayElementsDTO?, daySignal: [DaySignalItemDTO]?)
}
```

规则（全部确定性，0 AI）：

1. **dominant** = `dayElements.stemElement`（中文五行 → `ElementColors.fromZh`）；`dayElements == nil` → `ElementColors.ofGan(dayPillar 首字)`；都失败 → `nil` + 现有 warning 日志。（保持现状不变。）
2. **support0** = `daySignal` 中第一个 `direction == "up"` 且 ≠ dominant 的五行（引擎喜用命中优先）；没有 → `sheng[dominant]`（我生：金→水、水→木、木→火、火→土、土→金）。
3. **support1** = `ke[dominant]`（我克：金→木、木→土、土→水、水→火、火→金）；若与 support0 相同 → 改取 `sheng[dominant]`。
4. dominant 为 `nil` 时 support0/support1 也为 `nil`（除非 support0 来自信号，可保留）。
5. 不再使用 `dayElements.branchElement`（旧规则「副 = 地支五行」作废）。

不变式（写进测试）：dominant 非 nil 时，三者两两不同。

> 注：`sheng` 字典已存在，新增同风格的 `static let ke: [String: String]`。

对外再提供：

```swift
var dominantMain: Color   // 光 1
var dominantTint: Color   // 光 2
var support0Main: Color   // 光 3
var support1Main: Color   // 光 4
```

---

## 4. 四团光参数（C）

设计坐标系 = **390 × 420**。实际舞台：宽 `W` = `GeometryReader` 宽度，高 `H` = 现有 `stageHeight`（340，**不改**，避免宜忌下移）。

换算：
- 中心点：`x' = x × W/390`，`y' = y × H/420`
- 尺寸：`w' = w × W/390`，`h' = h × W/390`（宽高同用 W 比例，保持椭圆形状）
- blur 半径固定 26（不随屏宽缩放）

| # | 颜色 | 不透明度 | 设计尺寸 w×h | 设计中心 (x, y) |
|---|---|---|---|---|
| 1 主光 | `dominantMain` | 0.85 | 250 × 290 | (295, 165) |
| 2 伴光 | `dominantTint` | 0.70 | 200 × 220 | (60, 100) |
| 3 辅光一 | `support0Main` | 0.55 | 150 × 170 | (115, 345) |
| 4 辅光二 | `support1Main` | 0.50 | 120 × 140 | (260, 330) |

- 绘制顺序（下→上）：2 伴光、1 主光、3、4（与现有一致）。
- 实际不透明度 = 表中值 × `dim`，`dim` = 亮色 1.0 / 暗色 0.55（保持现有值）。
- 渲染方式保持现状：`Ellipse().fill(RadialGradient(colors: [c.opacity(a), c.opacity(0)], center: .center, startRadius: 0, endRadius: min(w', h')/2)).frame(w', h').blur(26)`。（可改用 `EllipticalGradient(startRadiusFraction: 0, endRadiusFraction: 0.5)` 以更贴 CSS closest-side，二选一，review 均接受。）
- 不 `.clipped()`（现状），光晕边缘自然洇出。
- 竖排签文仍在左侧（`lotText` 位置不动），与主光（右上）错开。

---

## 5. 动画（D）

- 每团光：位移 `(0,0) ↔ (+8, −10)` **加** 缩放 `1 ↔ 1.05`，ease-in-out，往返循环。
- 规格是 12s 一个往返 + 四团负延迟错相。SwiftUI 没有负延迟；`.delay(n)` 会让光团静止 n 秒才动，**禁止使用**。
- 做法：四团各自独立 `@State` 开关，用略不同的半程时长近似错相：光 1 `6.0s`、光 2 `6.8s`、光 3 `5.6s`、光 4 `7.4s`（`withAnimation(.easeInOut(duration:).repeatForever(autoreverses: true))`）。
- `accessibilityReduceMotion == true` → 不启动任何循环（现状逻辑保留）。
- 注意 `.scaleEffect` 放在 `.blur` 之后、`.position` 之前或之后都可，但 offset/scale 不能导致 `.position` 中心点被重复换算。

---

## 6. 测试（E）

替换现有两个 `HaloPalette` 测试（`testHaloPaletteUsesStemBranchAndFavorableSignal` / `testHaloPaletteFallbacks`），新测试覆盖：

1. **默认推法**：`庚申` + `DayElementsDTO(金, 水)` + 无信号 → dominant `metal` / support0 `water` / support1 `wood`。
2. **五个主五行逐一**：遍历 金木水火土，无信号 → support0 = 我生、support1 = 我克（钉死规格表）。
3. **喜用信号优先**：dominant 金，信号 `[金↑, 火↓, 土↑]` → support0 `earth`（跳过等于 dominant 的金、跳过 down 的火），support1 `wood`。
4. **信号与我克撞车**：dominant 金，信号 `[木↑]` → support0 `wood`，support1 回落 `water`。
5. **老快照**：`dayElements == nil`，`丙午` → dominant `fire`，support0 `earth`，support1 `metal`。
6. **不变式**：上述所有用例 dominant/support0/support1 两两不同。
7. **色板完整**：五个 key 的 `HaloColors.main` / `tint` 均非 nil；未知 key 返回 nil。

签文相关的 `testDailyLotTablesCoverAllRelationsAndFitVertical` 与 EN 零 CJK 扫描保持不动。

---

## 7. 文档（F）

- `DailyImageHeroSection` 文件头的「光晕取色」段落按 §3 重写；注明色板来源「2026-10-15 用户五行光晕视觉规格」，以及**不显示宜借文字**的理由（一句话）。
- `DESIGN.md` Decisions Log 末尾追加一行 `2026-10-15`：光晕改用独立饱和色板 + 伴色、取色规则改为「喜用命中优先、否则我生 + 我克」、规格中的底色 `#F1EEE8` / 颗粒 PNG / LLM palette / 五行条 / 宜借提示语未采纳及原因。

---

## 8. 提交要求

- 在 `today-hero-halo` 分支上**新增一个 commit**，push 到 `origin today-hero-halo`。
- commit message 必须三段式（CLAUDE.md）：Why / What（改了哪些类型/函数/文件）/ Impact，末尾带 Co-Authored-By 行。
- 本环境无法编译 Swift 时，在 commit body 的 Impact 里写明「未编译，需 Xcode 构建 + 跑 DailyImageHeroCopyTests」。能编译的话跑 `DailyImageHeroCopyTests` 全绿再提交。

---

## 9. 验收 / review 清单（Claude review 时逐条对）

- [ ] 色板 10 个色值与 §2 表逐一相等，无手误
- [ ] `ElementColors` 未被修改
- [ ] 取色规则与 §3 一致；`branchElement` 不再参与
- [ ] dominant 非 nil 时三色两两不同（代码 + 测试）
- [ ] 四团光尺寸/透明度/中心与 §4 表一致，且按 `W/390`、`H/420` 换算，无写死 390/420 的 frame
- [ ] 伴光用 tint，不是 main 降透明度
- [ ] 暗色 `dim = 0.55` 仍生效
- [ ] 动画含 scale 1→1.05；无 `.delay(`；reduce-motion 时不启动
- [ ] 无「宜借」「气偏旺」等新增可见文字；无五行条；无新颗粒层；页面底色未改
- [ ] 未改后端 / prompt / `PROMPT_VERSIONS`；未加依赖；未新建 .swift 文件（或 pbxproj 4 处已登记）
- [ ] 查表失败仍走 warning 日志 + inkMuted，无静默吞错
- [ ] 测试按 §6 覆盖；旧 HaloPalette 测试已替换（字段名变了，旧测试必须改，不能留着编译失败）
- [ ] `DESIGN.md` Decisions Log 有 2026-10-15 条目
- [ ] commit 三段式、在 `today-hero-halo` 分支、未 force-push
