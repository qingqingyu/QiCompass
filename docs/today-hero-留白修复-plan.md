# Today hero 顶部留白修复方案

> 2026-10-02 · 起因：真机截图（393pt 宽，正财日 / 己酉）外部评审说 hero 画卡上部"太空"
> 给执行 AI 看的改动说明。动手前先读 `DESIGN.md`（CLAUDE.md 强制），并读一遍本文 §0 的约束。

---

## 0. 结论与约束

**评审说得对，但只采纳一部分。**

截图实测（换算成 pt）：hero 卡从 y≈180 开始，卡高约 392。山顶在卡内约 **38%** 处（≈149pt），也就是说顶部有约 **135pt** 只有雾和纸纱，唯一的内容是右上角 16pt、透明度 74% 的「己酉」落款。这块留白离山远，落款又太小，撑不住画面，看起来就像图没加载完。连带的问题是，今日解读的标题被挤到 y≈628，第一条领域行（事业）一半被 Tab 栏挡住。

| 评审建议 | 采纳？ | 理由 |
|---|---|---|
| A. 把 AI 标题「正财当值…」挪进山上方当题字 | **不采纳（本轮）** | ① headline 是 LLM **异步**产物，`.fetching` 期间画是空的，`.failed` 时还要换成引擎模板文字，画面会跳；② 违反 10-01 定稿 D1「画做减法、画内只留落款+宜忌」；③ 画内文字目前是确定性内容（干支 / 宜忌查表），塞 LLM 文字进去，等于把 AI 内容放进品牌艺术层；④ EN 标题长（"A day on your own ground"）没法竖排，需要另做一套版式。要做得单独拍板，见 §5 |
| B. 放大「己酉」，往山的方向靠 | **采纳（适度放大）** | 只改落款的字号和位置，不加印章——定稿 D1 写明「hero 上无任何印章」，要加朱印须用户另行批准 |
| C. 压缩插画高度、山往上提 | **采纳（主改动）** | 最直接，也不改信息架构；按 §1 的算法，只裁掉顶部的空白天空，山和宜忌都不动 |
| 记账/务本压在墨色上，对比度不够 | **采纳** | 调 `bottomFadeLayer` 的起点（纸色遮罩，有先例，不算背景渐变） |
| Tab 栏下透出正文显得脏 | **采纳** | 用 iOS 26 系统的 scroll edge effect，不手写渐变 |

**硬约束（不许违反）：**
- `DESIGN.md`：禁止 `backgroundGradient` 渐变背景。叠在图上的**纸色遮罩**（`bottomFadeLayer` / `edgeFadeLayer` 同类）可以用，因为已有先例
- 朱红只用于印章级元素；本方案**不新增**任何朱红
- `baseLayer` 的滤镜参数（`gSaturation/gBrightness/gContrast/gBlur`）注释写明「禁改」，本方案不动
- 不加依赖，不新增 .swift 文件（避免 pbxproj 登记）

---

## 1. 主改动：裁掉顶部空天（评审 C）

**文件**：`ios/QiCompass/QiCompass/Features/DailyFortune/DailyImageHeroSection.swift`

### 1.1 卡片比例

```swift
// 现状
private static let imageAspectRatio: CGFloat = 916.0 / 1000.0
// 改为：只裁顶部约 80pt（@393 屏，卡宽 359）
private static let imageAspectRatio: CGFloat = 916.0 / 780.0
```

卡高 392 → 约 306pt，省下约 **86pt**。目标：山顶落在新卡高的 **18–24%** 处（不能再高，否则会被 `edgeFadeLayer` 顶部 14% 的融纸吃掉）。

### 1.2 裁图要裁顶部，不能居中裁

现在 `Image("HeroLandscape").resizable().scaledToFill()` 是**居中**裁切，卡片变矮后上下各裁一半，山脚和底部会一起丢掉。必须改成**底对齐**，只裁天空：

```swift
Image("HeroLandscape")
    .resizable()
    .scaledToFill()
    ...
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)  // 关键：底对齐
    .clipped()
```

（`.frame(maxWidth:)` 和 `.frame(maxHeight:)` 两行合成一行，带上 `alignment: .bottom`。）暗色底图 `HeroLandscape_dark` 共用同一路径，**两种外观都要截图验收**。

### 1.3 跟着卡高重新调的参数

这些参数是按旧卡高 392/402 写的绝对值或比例，卡片变矮后要重新校准：

| 位置 | 现值 | 建议 | 说明 |
|---|---|---|---|
| `bloomMask` center.y | 0.42 | ≈0.50 | 圆心跟着山的视觉重心下移 |
| `bloomMask` endRadius | 400 | ≈340 | 原值按 402 卡高的对角线取 |
| `rimLayer` center.y / endRadius | 0.45 / 430 | ≈0.50 / 370 | 同上 |
| `mistLayer` 两团 y 偏移 | 76 / 178 | ≈40 / 120 | 雾要落在山腰，不能飘到宜忌字上 |
| `bottomFadeLayer` 起点 | 0.66 | 见 §3 | 宜忌字层占卡高的比例变大了 |

以上是初值，以截图为准微调。

### 1.4 宜忌字层不动

`HeroYiJiColumns` 的 `.padding(.horizontal, 22)` 和 `.padding(.bottom, 28)` 保持不变。卡片变矮后，宜忌在卡内的占比从约 37% 涨到约 47%，属于预期。**验收**：宜/忌表头的上沿和山脚之间至少要有 12pt 的纸面，不能压在山体最浓的墨上。

---

## 2. 落款放大、靠近山（评审 B，适度）

**同文件** `pillarSignature`：

| 属性 | 现值 | 建议 |
|---|---|---|
| 字号 `BaziFont.brush(size:)` | 16 | **22** |
| 颜色 | `ink.opacity(0.74)` | `ink.opacity(0.82)` |
| 竖排字间距 `VStack(spacing:)` | 2 | 4 |
| `.padding(.top)` | 16 | 改成相对卡高约 **10%**（用 GeometryReader 或 `containerRelativeFrame` 算，不要写死），让落款下端靠近山顶右侧，跟山形成呼应 |
| `.padding(.trailing)` | 16 | 22（跟宜忌左右内边距对齐） |

- 只放大到约 1.4 倍，**不要**放大 2–3 倍：落款属于「题款」，比大字日（58pt）抢眼就会喧宾夺主
- **不加印章、不加朱红竖线**（违反 D1 定稿和朱红纪律）。真要加，先找用户批准
- 无障碍 label 不变（`heroAccessibilityLabel` 已经包含 dayPillar）
- Dynamic Type：落款属于装饰层，可以不跟随字号缩放，但 XXL 档下不能和宜忌字层重叠

---

## 3. 宜忌文字对比度（小问题 1）

截图里左列「记账」「务本」叠在左下角一抹残山的墨色上，这是因为 `bottomFadeLayer` 要到 66% 才开始压纸。

**改法**：把纸色渐隐的起点提前，同时让字最密的那段接近纯纸：

```swift
LinearGradient(
    stops: [
        .init(color: BaziTheme.paper.opacity(0),    location: 0.46),
        .init(color: BaziTheme.paper.opacity(0.85), location: 0.66),
        .init(color: BaziTheme.paper,               location: 0.90),
    ],
    startPoint: .top, endPoint: .bottom
)
```

（location 是按 §1 改后的新卡高给的初值。）

**验收**：在亮色和暗色下，宜忌第 2、3 行文字和其背后像素的对比度 ≥ **4.5:1**（截图取色计算）。如果山脚被压得太白、失去意境，宁可只在左列底下加一块局部的纸色椭圆遮罩（和 `mistBlob` 同一种写法、不动画），也不要整体再往上压。

---

## 4. Tab 栏下透出正文（小问题 2）

**文件**：`ios/QiCompass/QiCompass/Features/DailyFortune/DailyFortuneMainView.swift`，`ScrollView`

现在是 iOS 26 的浮动 Liquid Glass Tab 栏，正文从下面透出来属于系统默认行为。修法是用系统自带的滚动边缘效果，**不要**手写一段 `LinearGradient` 盖在 Tab 栏上（会违反「禁止渐变背景」，而且在暗色下容易穿帮）：

```swift
ScrollView { ... }
    .modifier(TodayScrollEdge())

private struct TodayScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.hard, for: .bottom)
        } else {
            content
        }
    }
}
```

（`ViewModifier` 写在 `DailyFortuneMainView.swift` 文件里，不要新开文件。）

- 部署目标是 17.2，必须加 `#available` 判断
- 先试 `.hard`；如果硬边和水墨风格冲突，退回 `.soft`（系统默认值），截图对比后让用户选
- 其他三个 Tab 也有同样的问题，**本轮只改今日页**，其余页另开任务

---

## 5. 备选（未批准，不要做）：标题题字进画

如果改完 §1–§4，用户仍觉得画面空，再考虑评审建议 A。前置条件（缺一不可）：
1. 用户明确推翻 10-01 定稿 D1「画内只留落款 + 宜忌」
2. 题字的数据源用**确定性**引擎模板标题（`EngineReadingTemplates`，按 dayRelation 查表，例如「踏实务本,积小胜的一天」），**不要用** LLM headline——这样画面不随 AI 状态跳变，也和下方的 AI 标题区分开（一个是"今日调性"，一个是"AI 解读"）
3. EN 横排衬线、zh/zh-Hant 竖排楷体，要分别出版式稿
4. 解读区标题和题字不能写同一句话

---

## 6. 验收清单

截图设备：393pt（iPhone 16 Pro）+ 375pt（SE / mini）+ 430pt（Pro Max）× 亮色/暗色 × zh/zh-Hant/en。

- [ ] 393pt 亮色首屏（不滚动）能看到：日期区、chips、完整的 hero、今日解读标题、**至少一条完整的领域行**（事业）
- [ ] 山顶在卡高的 18–24% 处，顶部没有被融纸切掉
- [ ] 落款 22pt，视觉上和山相互呼应，不比大字日抢眼
- [ ] 宜忌文字对比度 ≥ 4.5:1（亮/暗都测）
- [ ] 宜忌表头和山脚之间有 ≥12pt 纸面
- [ ] 暗色夜景底图同样底对齐，月光倒影没有被裁掉
- [ ] iOS 26：Tab 栏下方不再透出可读的正文；iOS 17/18 行为不变
- [ ] reduce-motion：雾和呼吸动效全停，静态画面依然成立
- [ ] EN 宜忌词每条 ≤16 chars 的预算在 375pt 屏下仍能单行显示（`DailyImageHeroCopyTests` 通过）
- [ ] 全量 iOS 单测通过（至少 `DailyImageHeroCopyTests`、DailyFortune 相关测试）
- [ ] 没有新增朱红、印章、依赖或 .swift 文件
- [ ] 在 `DESIGN.md` Decisions Log 追加一行：「2026-10-02 Today hero 裁顶部空天 916:1000→916:780 底对齐 + 落款 16→22 + 宜忌融纸提前 + iOS 26 scroll edge effect」
- [ ] commit 按三段式（Why / What / Impact）写
