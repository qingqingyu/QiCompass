# 今日页视觉评审修复方案

> 2026-10-18 · 起因：用户真机截图（今日页，乙丑日 · 偏财，大屏 iPhone）+ 一份外部 AI 评审 + 用户自己的感受「上面挤、下面空」
> 给执行 AI 看的改动说明。动手前先读 `DESIGN.md`（CLAUDE.md 强制），再读本文 §0。
> **用户已拍板：本文所有条目全部要修。** 其中 S4（光晕淡出）、S5（Tab 图标）修订了用户此前的定稿，改动后必须更新 `DESIGN.md` 决策记录（见 §9）。

---

## 0. 总览与约束

### 0.1 问题清单 → slice 对照

| # | 问题 | 根因（已核实代码） | Slice |
|---|---|---|---|
| A | 中文字体看起来是黑体（苹方），不是楷体 | `BaziFont` 假设 Kaiti SC「iOS 自带」，但它在真机上大概率是**按需下载**的系统字体；代码没有触发下载，缺失时静默回退系统字体。之前的视觉验收都在模拟器上做的 | **S1** |
| B | 左边距不统一（24 / 28 / 26） | 宜忌 `.padding(.horizontal, 28)` 是已删除的「光晕舞台 17 + 内边距 11」的遗留；今日信号行多了 `.padding(.horizontal, 2)` | **S2** |
| C | 事业 / 关系 / 精力 标签列太宽 | `domainRow` 标签列写死 92pt（按英文 "Relationships" 定的），中文两个字只需 ~30pt | **S2** |
| D | 「今日信号」和三行标签样式不统一 | 信号行标签 13 medium **ink**、值右对齐；三行标签 12.5 medium **inkMuted**、正文左对齐 | **S2** |
| E | 结尾那句「财不入急门…」被埋在底部小灰字 | `reminder` 用 `BaziFont.caption(12)` + inkMuted | **S3** |
| F | 上面挤、下面空 | 头部 + chips + 宜忌全叠在光晕区，宜忌行上下只有 9pt；页面在页脚就结束（09-07 删了第二屏 7 日历史带，没有东西补位） | **S3** |
| G | 标题和正文层级太近 | 主因是 A（字体没生效）；另外标题 17 / 正文 14 差距偏小 | **S1 + S3** |
| H | 光晕像污渍：绿团压在「忌」红字后，棕团压在「事业」后 | 10-15 定稿「光晕溢进解读区、不裁切」；主光团 `dominantMain` 坐标 (295,165) 正好在忌栏后面 | **S4** |
| I | Tab 栏上方有一条硬色带 | `TodayScrollEdge` 用了 `.scrollEdgeEffectStyle(.hard, …)` | **S5** |
| J | Tab 图标风格混杂；「我的」像撇嘴的脸 | 四个图标线宽不一（今日 5.5% / 合盘 3.9% / 我的 4.2%）；「我的」肩膀是一道上拱弧，悬在头点下方，读成嘴 | **S5** |
| K | 「偏财」「冲未」chip 看不出能点 | 两个 chip 都是 Button，点开是释义 sheet，但外观没有任何可点暗示 | **S6** |
| L | 页脚「乙丑日 · 偏财 · 解读仅供参照」和顶部信息重复 | 10-01 定稿 | **S6** |
| M | 正文括号注释读起来碎；「忌木故」这类文言缩略 | 每日 prompt 规则「术语首次出现时括号附 ≤6 字白话」，headline 也受此规则约束 | **S7**（后端） |

### 0.2 硬约束（不许违反）

- 颜色只用现有 token；**不新增朱红用法**（朱红只给印章级小元素）
- 不加第三方依赖。S1 用 Apple 自带的 CoreText 下载 API，不算依赖；**如果要把字体文件打包进 App，必须先停下来问用户**（涉及字体授权）
- 尽量不新增 `.swift` 文件；如果确实要新增，必须在 pbxproj 里 4 处登记，并使用一致的 24 位 ID
- 字体方向：中文展示层 = 楷体，宜忌 = 宋体（图内宋 / 文中楷）。**不要**把标题改成宋体（10-14 已否决）
- 错误显式传播：字体下载失败必须打日志，不允许空 catch
- 每个 slice 一个 commit，commit message 用三段式（Why / What / Impact）
- **在当前分支上提交**；不要 rebase 或 force-push 别人的分支

### 0.3 建议执行顺序

**S1 → S2 → S3 → S4 → S5 → S6 → S7**

S1 必须最先做：其他 slice 的视觉验收都要在楷体真正生效之后截图，否则调的都是黑体。S7 是后端改动，和 iOS 改动互相独立，可以并行做。

---

## S1. 楷体 / 宋体在真机上真正生效

**文件**：`ios/QiCompass/QiCompass/Shared/BaziFont.swift`（加载逻辑放在这个文件里，避免新增文件），以及 `QiCompassApp.swift`（启动时调用）

### S1.0 先在真机上确认（必须做，不能跳过）

模拟器证明不了这个问题，必须用真机。在 `QiCompassApp.init` 里临时加一段打印，**确认后删掉**：

```swift
for name in ["Kaiti SC", "STKaitiSC-Regular", "Kaiti TC", "STKaitiTC-Regular",
             "STKaiti", "Songti SC", "STSongti-SC-Regular", "STSong"] {
    print("font probe", name, UIFont(name: name, size: 12) != nil)
}
```

- **全是 false（或楷体那几行是 false）** → 根因确认，继续做 S1.1
- **楷体那几行是 true** → 根因不是缺字体，**停下来**，把打印结果和一张真机截图报告给用户，不要做 S1.1。另外查一下 `Font.custom("Kaiti SC", …)` 实际解析到了哪个字体
- 注意：`UIFont(name:)` 要求传入的是字体名（PostScript 名或全名）。只传家族名 "Kaiti SC" 有可能拿不到字体，即使字体其实已经装了。所以上面同时测了家族名和 PostScript 名。S1.1 里的探测逻辑也要同时测这两种名字

### S1.1 启动时按需下载系统字体

用 CoreText 的系统字体下载 API（Apple 官方支持，不需要任何依赖）：

```swift
/// 按需下载 iOS 系统可下载字体(楷体/宋体真机默认不带,2026-10-18 真机截图确认)。
static func ensureDownloadableFonts() {
    let names = ["STKaitiSC-Regular", "STKaitiTC-Regular", "STSongti-SC-Regular"]
    let missing = names.filter { UIFont(name: $0, size: 12) == nil }
    guard !missing.isEmpty else { return }
    let descs = missing.map {
        CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: $0] as CFDictionary)
    }
    CTFontDescriptorMatchFontDescriptorsWithProgressHandler(descs as CFArray, nil) { state, info in
        switch state {
        case .didFailWithError:
            AppLogger.app.error("op=fontDownload.fail info=\(String(describing: info), privacy: .public)")
        case .didFinish:
            DispatchQueue.main.async { FontAvailability.shared.markChanged() }
        default: break
        }
        return true
    }
}
```

要求：

1. **探测不能永久缓存 nil。** 现在 `kaitiSCName` / `kaitiTCName` / `songtiName` 都是 `static let`，第一次求值是 nil 就永远是 nil。改成：一旦探测成功就缓存结果；结果是 nil 时，下次取值重新探测。探测时同时测家族名和 PostScript 名（见 S1.0）
2. **下载完成后刷新界面。** 在 `BaziFont.swift` 里加一个 `@Observable final class FontAvailability { static let shared; private(set) var revision = 0; func markChanged() }`。在 `RootTabView` 的 body 里读一次 `revision`，让 SwiftUI 在它变化时重新渲染。**不要用 `.id(revision)` 重建整棵视图树**，那样会丢掉导航状态和引导流程的进度
3. 在 `QiCompassApp.init` 里调用 `BaziFont.ensureDownloadableFonts()`
4. 下载失败（比如没联网）时，保留现有的回退字体，同时打一条 error 日志；下次启动会再试一次
5. 写清楚注释，同时更新 `BaziFont.swift` 文件头里「iOS 系统自带，不打包」这句：改成「系统可下载字体，启动时按需下载，不打包」

### S1.2 验收（真机）

| # | 场景 | 期望 |
|---|---|---|
| 1 | 删掉 App 重装，联网冷启动 | 首次下载完成后（几秒内），今日页标题、正文、盘面细目里的干支都变成楷体；宜忌变成宋体 |
| 2 | 第二次冷启动 | 一打开就是楷体，不会先闪一下黑体 |
| 3 | 飞行模式下首次安装 | 显示回退字体，不崩溃，有 error 日志；联网后重启恢复 |
| 4 | zh-Hant | 用的是 Kaiti TC（繁体字形） |

**S1 做完之后，前一份 plan（`docs/细目页大运卡片对齐修复-plan.md`）的验收截图也要在楷体下重拍，因为字宽变了。**

---

## S2. 左边距统一 + 标签列收窄 + 今日信号对齐

### S2.1 左边距统一为 24

**文件**：`ios/QiCompass/QiCompass/Features/DailyFortune/DailyFortuneMainView.swift`

```swift
DailyImageHeroSection(dayRelation: response.dayRelationToDayMaster)
    .padding(.horizontal, 24)   // 原 28(已删的光晕舞台 17 + 内边距 11 遗留)
```

同步改掉上方那句注释（「水平 28 = 原 hero 舞台 17 + 宜忌内边距 11」）。

**文件**：`DailyInterpretationSection.swift` → `signalRow`：删掉 `.padding(.horizontal, 2)`。

### S2.2 领域行标签列按语言区分宽度

**文件**：`DailyInterpretationSection.swift` → `domainRow`

```swift
/// 标签列宽:中文 52(容得下 4 字「今日信号」,三行与信号行同列对齐);
/// EN 维持 92("Relationships" / "Today's signal")。
private var labelColumnWidth: CGFloat {
    AppLanguage.current.isChinese ? 52 : 92
}
```

`domainRow` 里把 `.frame(width: 92, …)` 改成 `.frame(width: labelColumnWidth, …)`，标签加上 `.lineLimit(1)` 和 `.minimumScaleFactor(0.85)`。这两个宽度都偏紧：「今日信号」4 个字约 50pt，英文 "Today's signal" 在 12.5pt 下约 90pt，所以必须加缩放兜底。同时改掉函数注释里的「92pt 固定标签列」。

### S2.3 今日信号行改成和三行同一结构

现在的写法是「左标签 + Spacer + 右侧的值」（D5「左右分立」）。改成和 `domainRow` 完全一致：

- 行顶 hairline，上下 padding 11
- 左边是标签列：宽度用 `labelColumnWidth`，字体 `.system(size: 12.5, weight: .medium)`，颜色 **inkMuted**（原来是 ink）
- 右边是正文列：`木↓ 土↑` **左对齐**，紧接在标签列后面（`HStack(spacing: 10)`，和 `domainRow` 相同）。↑↓ 的着色和无障碍 label 保持不变
- 降级注释（`signalNote`）保持在这一行下方，左缘和正文列对齐（`.padding(.leading, labelColumnWidth + 10)`）

更新 `signalRow` 的文档注释，注明这一行修订了 D5 的「左右分立」。

### S2.4 验收

用像素测量截图（参考 `docs/today-hero-去签文贴B稿-plan.md` 实施记录里 PIL 的做法）：日期「18」、chips、宜/忌表头、「今日解读」、事业标签、今日信号标签，这几样的左缘 x 坐标相同（误差 ≤1pt）。正文列的左缘也对齐。中文、繁体、英文各截一张。

---

## S3. 结尾句提升 + 纵向节奏拉匀 + 标题加大

### S3.1 结尾句（reminder）做成整页的收尾

**文件**：`DailyInterpretationSection.swift` → `insightBody` 和 `reminderFont`

位置不动，仍然放在信号行之后（**不要**挪到顶部，也不要做成「签」，用户 10-15 刚删掉过今日一签）。只改样式：

```swift
// 收尾句(2026-10-18 评审:整页唯一可带走的一句,原 caption 小灰字被埋)
VStack(spacing: 14) {
    Rectangle()                       // 短墨横,同命书小节题 16×1.5 母题
        .fill(BaziTheme.ink.opacity(0.35))
        .frame(width: 16, height: 1.5)
    Text(MarkdownSanitizer.rendered(insight.reminder))
        .font(reminderFont)
        .foregroundStyle(BaziTheme.ink)
        .multilineTextAlignment(.center)
        .lineSpacing(6)
        .fixedSize(horizontal: false, vertical: true)
}
.frame(maxWidth: .infinity)
.padding(.top, 40)
```

```swift
private var reminderFont: Font {
    AppLanguage.current.isChinese
        ? BaziFont.display(size: 20)                                    // 楷体
        : .system(size: 17, weight: .medium, design: .serif).italic()
}
```

- 去掉 `.tracking(1)`
- 降级态（`degradedBody`）复用的是同一个 `insightBody`，会自动生效。要确认引擎模板的 reminder 在大字下也能看（`EngineReadingTemplates` 的各条 reminder 都要过一遍）
- 不加朱印（属于朱红新用法，需要用户另外批准）

### S3.2 纵向节奏拉匀

问题是空白都堆在底部，要把它们分到各个区块之间。**不要**用 Spacer 或 minHeight 把页脚钉到屏幕底部，因为小屏手机本来就需要滚动。

| 位置 | 文件 | 现在 | 改为 |
|---|---|---|---|
| 宜忌条目上下 padding | `DailyImageHeroSection.swift` `HeroYiJiColumns.column` | 9 | **11** |
| 宜忌 → 今日解读 | `DailyFortuneMainView.swift` `DailyInterpretationSection` `.padding(.top, …)` | 24 | **40** |
| 标题 → 领域行 | `insightBody` 里 `.padding(.top, 11)` | 11 | **16** |
| 领域行上下 padding | `domainRow` `.padding(.vertical, 11)` | 11 | **13**（今日信号行同步改，见 S2.3） |
| 结尾句 → 页脚 | `heroFootnote` `.padding(.top, 26)` | 26 | **36** |

同步更新 `HeroYiJiColumns` 文档注释里的「每条上下 padding 9」。

### S3.3 标题加大

`insightBody` 里标题 `BaziFont.display(size: 17)` 改成 **19**，行距 `lineSpacing(7)` 保持不变。正文保持 14、ink 不变。标题**不改宋体**。

### S3.4 验收

- 大屏（Pro Max）：页脚到 Tab 栏之间的空白 ≤ 一个区块的高度，不再出现一大片空白
- iPhone SE：可以正常滚到底，页脚完整可见
- 降级态（断网或 AI 失败）：结尾句显示的是引擎模板句，样式和正常态一致
- 中文、繁体、英文各截一张

---

## S4. 光晕在「今日解读」之前淡出 + 主光团降透明度

> 修订 2026-10-15 定稿里「溢出部分洇进下方解读区，不裁切」这一条。用户 10-18 已拍板。

### S4.1 遮罩淡出

**文件**：`DailyFortuneMainView.swift` 里光晕的 `.background` 那一段

光晕原本是 420pt 高，从头部顶边往下 34pt 开始画，会超出宿主容器（头部 + 宜忌）。现在加一层**跟着宿主高度走**的遮罩：在宜忌底部附近淡出到全透明，「今日解读」所在的区域不再有任何光晕。

```swift
.background(alignment: .top) {
    GeometryReader { host in
        let visible = max(host.size.height - Self.haloTopInset + 16, 0)
        HaloBackdrop(…)
            .frame(height: HaloBackdrop.height)
            .offset(y: Self.haloTopInset)
            .mask(alignment: .top) {
                // 光晕到宜忌底(+16)渐隐至透明,不再洇进解读区(2026-10-18 修订 10-15)
                LinearGradient(
                    stops: [.init(color: .black, location: 0),
                            .init(color: .black, location: 0.72),
                            .init(color: .clear, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: visible)
                .offset(y: Self.haloTopInset)
            }
    }
    .inkIn(delay: 0.08)
}
```

- 这个渐变是光晕艺术层的**遮罩**，不是页面背景，所以不违反「禁止渐变背景」（同 `bottomFadeLayer` 先例）。页面底色仍然是纯色宣纸
- 注意 mask 的坐标系：mask 是跟着被遮罩的视图走的，所以 `offset` 要和 HaloBackdrop 自己的 offset 对上。这一点要实测，不要只看代码推算

### S4.2 压在「忌」栏后面的主光团降透明度

**文件**：`DailyImageHeroSection.swift` → `HaloBackdrop`

`dominantMain` 这一团：透明度从 `0.85 * dim` 改成 **`0.6 * dim`**。位置、尺寸、配色规则、漂移动效都不动。

### S4.3 验收

- 「今日解读」小标题和标题那一行的背景是纯宣纸色，用像素采样验证，和页面底色的差值 ≤ 2
- 「忌」栏的朱红字压在光团上时，对比度 ≥ 4.5:1（取光团最浓的那个点）
- 亮色、暗色模式，木 / 火 / 土 / 金 / 水 五种主色各至少截一张（用 mock 换流日）
- 开启减弱动态效果时，光晕静止，遮罩没有问题

---

## S5. Tab 栏：去掉硬色带 + 统一图标线宽 + 修「我的」人形

> 修订 2026-09-29 D4「Tab 图标维持 08-30 定稿不换」。用户 10-18 已拍板。图标的**造型立意不变**（墨圆一点 / 三叠横墨 / 双开口圆 / 未钤之印），只调线宽和人形。

### S5.1 滚动边缘效果改成柔和

**文件**：`DailyFortuneMainView.swift` → `TodayScrollEdge`

`.scrollEdgeEffectStyle(.hard, for: .bottom)` 改成 `.soft`。注释里本来就写了「与水墨风格冲突则回退系统默认 `.soft`」，同步把这句改成已执行，并注明日期。

### S5.2 图标线宽统一为 5.5%

**文件**：`ios/QiCompass/QiCompass/Shared/TabIcons.swift`

| 图标 | 现在 | 改为 |
|---|---|---|
| 今日（墨圆） | `size * 0.055` | 不变（基准） |
| 合盘（双开口圆）`StrokeStyle(lineWidth: size * 0.039…)` | 3.9% | **5.5%** |
| 我的（印框）`.stroke(…, lineWidth: size * 0.0417)` | 4.2% | **5.5%** |
| 我的（人形弧）`StrokeStyle(lineWidth: size * 0.0417…)` | 4.2% | **5.5%** |
| 深度（三叠横墨） | 实心笔画 | 不变（本来就是粗墨块，和墨圆同一视觉重量） |

合盘的两个圆加粗之后，如果交叠处糊成一团，可以把半径从 r=50 收小到 r=48，圆心距不变。

### S5.3 「我的」人形：肩膀改成被印框截断的半身

现在是：头点悬在中间，下面有一道独立的上拱弧，整体看起来像「眼 + 撇嘴」。改成：肩弧的两端**落在印框底边上**，读起来是一个被印框截住的半身像。

```swift
/// 肩 = 两端落在印框底边的拱弧(2026-10-18:原悬空弧被读成「撇嘴的脸」)。
/// 印内 116 坐标系:起止 (30,116)→(86,116)(避开 rx 28 圆角),控制点 (58,40),
/// 弧顶 ≈ y 78,与头点(中心 y≈36.5,半径≈15)留出 ~26 的颈距。
p.move(to: CGPoint(x: 30 * s, y: 116 * s))
p.addQuadCurve(to: CGPoint(x: 86 * s, y: 116 * s),
               control: CGPoint(x: 58 * s, y: 40 * s))
```

头点保持实心，可以从 16.7% 微调到 18%。最终参数**必须在 28pt 实际尺寸下目测**。改完后把四个图标并排截一张（亮色和暗色、选中和未选中），**附在 commit 说明里，同时发给用户确认**。用户不认可就回滚 S5.3，S5.1 和 S5.2 保留。

同步更新 `TabIcons.swift` 文件头的注释，以及 `PersonInSeal` 的文档注释。

---

## S6. chips 加上可点提示 + 页脚精简

### S6.1 chip 可点提示

**文件**：`DailyImageHeroSection.swift` → `TodayChip`

两个 chip 点开都是释义 sheet，在文字后面加一个很小的 chevron，表示「点开有内容」：

```swift
HStack(spacing: 3) {
    Text(text)
        .font(.system(size: 11))
        .foregroundStyle(BaziTheme.ink)
        .lineLimit(1)
    Image(systemName: "chevron.right")
        .font(.system(size: 7, weight: .semibold))
        .foregroundStyle(BaziTheme.inkMuted)
        .accessibilityHidden(true)
}
.padding(.horizontal, 10)
.frame(height: 26)
.background(Capsule().stroke(BaziTheme.hairline, lineWidth: 0.5))
```

保留边框。加上 chevron 后，确认 `ViewThatFits` 在 375pt 宽的屏幕、英文环境下仍然能横排放下（「Wealth Rival ›」「Clashes with Goat ›」这类长文本）；放不下会自动上下堆叠，这本身就是既有的兜底行为。

### S6.2 页脚只保留免责声明

**文件**：`DailyFortuneMainView.swift` → `footnoteText` / `heroFootnote`

页脚文字从「乙丑日 · 偏财 · 解读仅供参照」改成只显示 `L10n.DailyFortune.disclaimer`（中文「解读仅供参照」）。

- `footnoteText(dayPillar:relation:language:)` 里的拼音逻辑和 `pinyinMiss` 日志都删掉。如果函数只剩返回 disclaimer，就把函数删掉，直接用 `Text(L10n.DailyFortune.disclaimer)`
- `ios/Tests/DailyFortune/DailyImageHeroCopyTests.swift` 里钉住页脚拼音段的用例同步删掉或改掉（EN 零 CJK 扫描里去掉 footnote 条目）。grep `footnoteText` 确保零残留
- 同步更新文件头和函数文档里「戊申日 · 偏财 · 解读仅供参照」这类描述

---

## S7. 每日 prompt：减少括注、禁止文言缩略（后端）

**这是 prompt 改动，CLAUDE.md 的「三语模板同步」和「prompt 三边一致性」两条守护栏都会触发。**

### S7.1 改什么

`backend/app/ai/prompts/{zh,zh-hant,en}/daily_fortune_v4.md` 第 34 行（en / zh-hant 对应的行），以及 `daily_fortune_unknown_hour_v4.md` 里同样的那条规则。现在的规则是：

> 核心术语保留（流日 / 偏官 / 喜忌等），**在本输出中首次出现时用括号附一句 ≤6 字白话**（例：偏官（外来压力）日），之后可裸用

改成（中文版，繁体和英文按同样意思写）：

> - headline **不加括号**；需要术语时直接用术语，或者直接用白话说
> - 全文**最多一处**括号白话注释，只给最难懂的那个术语；其余术语要么不用，要么用一句完整白话带出
> - 不用文言缩略（如「忌木故」「宜静养」式的省略句），每句都要有完整的主谓

英文版对应：headline 不加括号；全文最多一处括号 gloss；不写省略主语的电报体短语。

### S7.2 版本与文件

1. 新建 `daily_fortune_v5.md` 和 `daily_fortune_unknown_hour_v5.md`，**zh / zh-hant / en 三语各一份，共 6 个文件**，内容 = v4 加上 S7.1 的修改。v4 文件保留不删
2. `backend/app/ai/prompts.py`：`PROMPT_VERSIONS["daily_fortune"]` 从 4 改成 **5**（unknown_hour 变体共用这个版本号）
3. 更新 `prompts.py` 里提到「当前 v4」的注释
4. `backend/tests/test_interpret_render.py:596` 的 `assert PROMPT_VERSIONS["daily_fortune"] == 4` 改成 5；再 grep 一遍 tests，看有没有其他地方写死了 v4
5. iOS **不用改**：客户端缓存的 prompt 版本是从服务端 identity 读的，老缓存会自然失效

### S7.3 必须全部通过

```bash
python3 tools/check_prompt_sync.py                      # PASS
cd backend && python -m pytest tests/test_i18n.py tests/test_interpret_render.py \
    tests/test_interpret_cache.py tests/test_interpret_prompt_version.py tests/test_daily_fortune.py
```

- evalkit 只覆盖 M0-M7，不覆盖 daily_fortune，所以这一步不用跑
- 如果有条件，用真实模型生成 3 个不同流日的 zh 输出贴进 commit 说明，人工确认：headline 没有括号、全文括号 ≤1 处、没有「忌木故」式的缩略

---

## 8. 总验收（S1-S6 做完后，真机统一走一遍）

| # | 场景 | 期望 |
|---|---|---|
| 1 | 今日页 zh 亮色，大屏 | 楷体生效；左缘统一；光晕不进入解读区；结尾句大字居中；下方不再空一大片 |
| 2 | 今日页 zh 暗色 | 同上，光晕 dim 正常 |
| 3 | zh-Hant | 繁体楷体（Kaiti TC）；标签列 52 能放下「今日信號」 |
| 4 | en | 标签列 92；结尾句是 serif italic；chips 加了 chevron 后横排或堆叠都正常 |
| 5 | iPhone SE | 能滚到底，没有截断 |
| 6 | 降级态（断网） | 引擎模板五段 + 大字结尾句，版式和正常态一致 |
| 7 | 时辰未知盘 | 信号行降级注释和正文列对齐；末尾的补时辰行正常 |
| 8 | 减弱动态效果 | 光晕静止，所有入场动画降级 |
| 9 | VoiceOver | chip 的 chevron 不会被读出；信号行仍读「喜用 土 / 忌神 木」 |
| 10 | Tab 栏 | 上方没有硬色带；四个图标线宽一致；「我的」不再像一张脸 |

`xcodebuild test` 全绿（`DailyImageHeroCopyTests` 的用例数会因为 S6.2 减少，在 commit 说明里写清楚减了几个、为什么）。如果你的环境没有 Swift 工具链，**在 commit message 里写明「未编译，需 Xcode 构建 + 测试确认」**，不要声称已经验证过。

---

## 9. DESIGN.md 同步

在 `DESIGN.md` 的 Decisions Log 里加一条 2026-10-18 记录，并改掉第 115-116 行附近（每日运势 / 深度解析两段长描述）相关的旧描述：

- **字体**：楷体 / 宋体是系统**可下载**字体，启动时按需下载，不打包（修订「iOS 自带」的说法）
- **今日页**：左缘统一 24；中文标签列 52 / EN 92；今日信号行和三行同构（修订 D5「左右分立」）；收尾句改为楷体 20 居中 + 短墨横；纵向节奏数值（S3.2 表）
- **光晕**：遮罩淡出到宜忌底部，不再进入解读区；主光团透明度 0.6（修订 10-15「溢出不裁切」）
- **Tab 栏**：滚动边缘效果改 `.soft`；图标线宽统一 5.5%；「我的」人形改为半身（修订 09-29 D4）
- **chips**：加 chevron 可点提示；**页脚**：只保留免责声明（修订 10-01）

---

## 10. 提交

按 slice 分别提交，共 7 个 commit，三段式 message。例如：

- `fix(ios): 楷体/宋体按需下载——真机缺字体静默回退苹方`
- `fix(ios): 今日页左缘统一 24 + 中文标签列收窄 + 今日信号行与领域行同构`
- `feat(ios): 今日页收尾句提升为楷体大字 + 纵向节奏拉匀 + 标题 19`
- `fix(ios): 今日光晕在解读区前淡出 + 主光团降透明`
- `fix(ios): Tab 栏 soft 边缘 + 图标线宽统一 + 「我的」人形改半身`
- `fix(ios): 今日 chips 可点提示 + 页脚只留免责`
- `feat(backend): daily_fortune prompt v5——减括注、禁文言缩略(三语)`

全部完成后，在本文件顶部加一行「状态：已实施」，文末补「实施记录」：写明每个 slice 的 commit hash、测试结果、截图结论、和本方案的偏差。格式参考 `docs/today-hero-去签文贴B稿-plan.md`。
