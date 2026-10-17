# 盘面细目 · 大运卡片对齐修复方案

> 2026-10-17 · 起因：用户真机截图（「我的」→ 盘面细目），「大运」一节的卡片高度参差不齐
> 给执行 AI 看的改动说明。动手前先读 `DESIGN.md`（CLAUDE.md 强制），并读一遍本文 §0 的约束。

---

## 0. 结论与约束

**外部 AI 找出的三个病因都对，但它给的修法有一处会造成回归，不能照抄。**

对照代码 `ios/QiCompass/QiCompass/Features/DeepAnalysis/LuckPillarsTimeline.swift:29-57` 核实：

| 外部 AI 的判断 | 是否属实 | 代码证据 |
|---|---|---|
| ① 年份被加了千分位（`1,998-2,007`） | **属实，是 bug** | `:37` `Text("\(lp.startYear)-\(lp.endYear)")` 走 `LocalizedStringKey`，Int 插值按 locale 加了分组符；`Localizable.xcstrings` 里确实有 `"%lld-%lld"` 这个键 |
| ② 「16-25岁」换行、「6-15岁」不换行 | **属实** | `:46` 卡宽写死 `.frame(width: 64)`，`.caption2` 跟随 Dynamic Type 放大，宽度却不跟着变；年份行（9 个字符）同理会被挤成两行 |
| ③ 「当前」只在当前卡出现，多出一行 | **属实** | `:40` `if isCurrent { Text("当前") }` |

**外部 AI 的修法要改的地方：**

| 外部 AI 的修法 | 采纳？ | 理由 |
|---|---|---|
| 年份 `Text(verbatim:)` | **采纳** | 纯数字，不需要本地化 |
| 年龄 `Text(verbatim: "\(…)–\(…)岁")` | **不采纳** | `"%lld-%lld岁"` 是已翻译的键：en = `26–35 yrs`，zh-Hant = `26-35歲`。改成 verbatim 后，英文和繁体都会显示简体「岁」，**这是 i18n 回归**。只需要加 `lineLimit(1)` 防换行，保留本地化键 |
| 「当前」用 `opacity(0)` 占位 | **采纳** | 补上 `.accessibilityHidden(!isCurrent)`，避免 VoiceOver 在每张卡都读出「当前」 |
| `.frame(maxHeight: .infinity)` + `.fixedSize(vertical:)` 强制等高 | **采纳（作兜底）**，但要注意顺序 | 现在 `background` / `overlay` 写在 `luckColumn` 内部。如果把 `maxHeight` 加在外面，**拉高的只有布局框，底色和描边不会跟着变高**。必须把 `maxHeight` 放在 `.padding` / `.background` 之前 |
| 卡宽改成 `96` | **不采纳** | 这会改变视觉密度，而且仍是写死的值，字号调大后还会再溢出。改用 `@ScaledMetric`（项目里已有先例：`DeepAnalysisHomeView.swift:154`） |
| 设计建议：去掉「当前」，只靠红色描边区分 | **不采纳** | 只靠颜色区分不利于无障碍（色弱用户），而且 DESIGN.md 里「当前柱 cinnabar 文字」是既定口径。改成角标属于视觉改动，需用户另外批准，本轮不做 |
| 设计建议：年份行用小一号、浅一点的字 | **已经是这样** | 年份行现在就是 `.caption2` + `inkMuted`，不用改 |

**硬约束：**
- 不新增 `.swift` 文件（避免 pbxproj 四处登记）
- 不新增朱红用法，颜色 token 一律不改
- 不加依赖
- 年龄行**必须**继续走 `"%lld-%lld岁"` 本地化键

---

## 1. 主改动：`LuckPillarsTimeline.swift`

**文件**：`ios/QiCompass/QiCompass/Features/DeepAnalysis/LuckPillarsTimeline.swift`

### 1.1 卡宽跟随 Dynamic Type

```swift
struct LuckPillarsTimeline: View {
    let luckPillars: [LuckPillarDTO]
    let currentLuckPillar: CurrentPillarDTO?

    /// 卡内容宽:随 Dynamic Type 放大(原写死 64,大字号下年龄/年份被挤成两行)
    @ScaledMetric(relativeTo: .caption2) private var columnWidth: CGFloat = 64
```

### 1.2 `luckColumn` 改成固定四行

```swift
private func luckColumn(_ lp: LuckPillarDTO, isCurrent: Bool) -> some View {
    VStack(spacing: 4) {
        // 保留本地化键 "%lld-%lld岁"(en "yrs" / zh-Hant「歲」),不可改 verbatim
        Text("\(lp.startAge)-\(lp.endAge)岁")
            .font(.caption2)
            .foregroundStyle(BaziTheme.inkMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        Text(lp.ganZhi)
            .font(BaziFont.ganzhi(size: 17))
            .foregroundStyle(isCurrent ? BaziTheme.cinnabar : BaziTheme.ink)
            .lineLimit(1)
        // verbatim:LocalizedStringKey 的 Int 插值会按 locale 加千分位(1,998)
        Text(verbatim: "\(lp.startYear)-\(lp.endYear)")
            .font(.caption2)
            .foregroundStyle(BaziTheme.inkMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        // 每张卡都占「当前」这一行,非当前卡隐藏 → 整排等高
        Text("当前")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(BaziTheme.cinnabar)
            .opacity(isCurrent ? 1 : 0)
            .accessibilityHidden(!isCurrent)
    }
    .frame(width: columnWidth)
    .frame(maxHeight: .infinity, alignment: .top)   // 必须在 background 之前
    .padding(BaziTheme.Spacing.sm)
    .background(
        isCurrent ? BaziTheme.cinnabarSoft : BaziTheme.cardSurface,
        in: RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
    )
    .overlay(
        RoundedRectangle(cornerRadius: BaziTheme.Radius.sm)
            .stroke(isCurrent ? BaziTheme.cinnabar.opacity(0.5) : BaziTheme.hairline,
                    lineWidth: 0.5)
    )
}
```

年份分隔符保持半角 `-`，与中文年龄行的 `"%1$lld-%2$lld岁"` 一致，不改成 en dash。

### 1.3 `body` 的 HStack 加等高兜底

```swift
HStack(alignment: .top, spacing: 12) {
    ForEach(Array(validPillars.enumerated()), id: \.offset) { _, lp in
        luckColumn(lp, isCurrent: isCurrent(lp))
    }
}
.fixedSize(horizontal: false, vertical: true)   // 新增:行高 = 最高那张卡,其余卡由 maxHeight 拉齐
.padding(.vertical, 4)
```

### 1.4 文件头注释

第 7 行的「当前柱高亮」说明后面补一句：「四行固定（年龄 / 干支 / 年份 / 当前占位），整排等高」。

---

## 2. 本地化清理：`Localizable.xcstrings`

**文件**：`ios/QiCompass/QiCompass/Resources/Localizable.xcstrings`

- 删除 `"%lld-%lld"` 整条（约在第 346-367 行）。全仓 grep 过，它只被 `LuckPillarsTimeline.swift:37` 使用，改成 verbatim 后就成了孤儿键
- **不动** `"%lld-%lld岁"` 和 `"当前"`
- 删除前再 grep 一次 `Text("\\(.*)-\\(.*)")`，确认没有其他调用点

---

## 3. 顺带发现（同屏，建议本轮一起修）

截图里「神煞」一节的「**天罗地网** 时柱」chip 被挤成两行，比同排的 chip 高，也是对齐问题。

**文件**：`ios/QiCompass/QiCompass/Features/DeepAnalysis/ShenshaChips.swift:37-44`

```swift
Text(BaziTerms.shenshaChipText(item.name))
    .font(.caption.weight(.medium))
    .lineLimit(1)
    .minimumScaleFactor(0.75)
Text(BaziTerms.display(item.position))
    .font(.caption2)
    .foregroundStyle(BaziTheme.inkMuted)
    .lineLimit(1)
    .fixedSize()          // 位置标签不参与压缩
```

**要注意 en**：en 的 chip 文本是「意译 + 汉字括注」，比中文长很多，`0.75` 可能还不够，会被截断成 `…`。执行时一定要切到 en 看一遍。如果截断严重，就**停下来报告**，不要自行把 `GridItem(.adaptive(minimum: 90))` 改成流式布局（那属于布局改版，需要用户拍板）。

---

## 4. 验收

没有可写的单元测试（纯布局），只做人工走查。每一项都要截图：

| # | 场景 | 期望 |
|---|---|---|
| 1 | zh-Hans，默认字号 | 年份显示 `1998-2007`，没有逗号；整排卡片等高；只有当前卡有「当前」 |
| 2 | zh-Hans，Dynamic Type 调到 **最大的非辅助档（xxxLarge）** | 年龄和年份都不换行（允许缩字）；卡片变宽且等高 |
| 3 | zh-Hant | 年龄显示「歲」，「當前」 |
| 4 | en | `26–35 yrs` 不换行；`Now` 标签正常 |
| 5 | 暗色模式 | 当前卡 cinnabarSoft 底色和描边铺满整卡（验证 §1.2 的修饰符顺序） |
| 6 | VoiceOver 扫过大运一排 | 只有当前卡读出「当前」 |
| 7 | 神煞（§3） | zh 下「天罗地网 时柱」一行显示；en 下不出现严重截断 |
| 8 | iPhone SE（375pt 宽） | 以上都成立 |

CLAUDE.md 里的各个守护脚本（prompt / 术语 / SKU / 城市库）都不涉及这几个文件，不需要跑。

## 5. Commit

三段式（Why / What / Impact），一个 commit 即可，例如：

`fix(ios): 盘面细目大运卡片等高——年份去千分位、年龄/年份禁换行、「当前」占位`
