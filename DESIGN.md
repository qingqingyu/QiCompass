# Design System — 玄机问道 QiCompass

> 全局视觉事实源。任何 UI 决策(颜色 / 字体 / 间距 / 圆角 / 动效)都必须先读这里,偏离须用户明确批准。

## Product Context

- **What this is:** AI 八字命理 iOS App,三模块(深度解析 / 合盘 / 每日运势)
- **Who it's for:** 想认真研究命理的中文用户(非娱乐化算命受众)
- **Space/industry:** 命理 / 玄学 / 占Astrology,对标:测测 / 知命 / 问真八字(国内)、Co-Star / The Pattern(海外)
- **Project type:** iOS native mobile app,SwiftUI,最低 iOS 17.2

## Memorable Thing

> **"专业不忽悠,不像算命软件。"**

用户第一次打开 3 秒后闭上眼,应该记住的事:这是一个**克制、真诚、像翻一本古籍**的研究工具,不是一个堆叠黑金卷轴纹的算命软件。

每个设计决策都要服务这件事。

## Aesthetic Direction

- **Direction:** 现代东方极简(宋瓷气质)
- **Decoration level:** minimal — 纯色背景,无渐变,无纸纹,无装饰图案,留白驱动
- **Mood:** 宋瓷雅致 / 明式克制 / 古籍阅读体验。让命理内容自己说话,UI 不抢戏。
- **Reference sites / products:**
  - 精神参考:Co-Star(极简直白的精神) — 取其克制,不取其纯黑白
  - 视觉参考:宋瓷色(汝窑天青 / 钧窑朱砂 / 龙泉墨青)/ 高端茶品牌目录 / 博物馆宋瓷展览图册
  - 反面教材:测测 / 知命 / 问真八字(国内命理黑金套路)

## Typography

iOS 系统字体,**不打包任何自定义字体**(避免体积 + 保持原生体验)。

- **Display/Hero(命盘标题):** `Songti SC` Semibold — 衬线宋体压住命理主题的文化分量
- **Heading(模块标题):** `Songti SC` Medium — 与 Display 同族,降一级权重
- **Body(正文):** `PingFang SC` Regular — 中文无衬线保证可读性
- **Ganzhi(干支字符):** `Songti SC` Semibold — 八字专用,字号 ≥22pt
- **Numeric/Data:** `SF Pro Text` + `tabular-nums` — 西文数字对齐(排盘表格 / 年龄 / 日期)
- **Code/Mono:** 不使用

**Type scale(基于 iOS 17.2 Dynamic Type):**

| 角色 | 字号 | 字重 | 用途 |
|---|---|---|---|
| Display | 32pt | Semibold | 命盘大标题 |
| H1 | 28pt | Semibold | 页面标题 |
| H2 | 22pt | Medium | Section 标题 |
| H3 | 17pt | Medium | 卡片标题 |
| Body | 16pt | Regular | 正文 |
| Caption | 13pt | Regular | 说明 |
| Micro | 11pt | Regular | 标签 / 元信息 |
| Ganzhi-L | 30pt | Semibold | 八字天干地支(主显) |
| Ganzhi-M | 22pt | Medium | 大运干支 |
| Ganzhi-S | 14pt | Semibold | 时辰干支 |

**SwiftUI 落地:** 用 `.font(.system(size:weight:))` + `.monospacedDigit()`(数字),或定义 `Font` extension。

## Color

**Approach:** restrained(克制)— 1 主强调色(朱砂) + 2 次强调色(墨青/黛蓝),颜色出现频率稀少且有意义。

| 角色 | Hex | 用途 | SwiftUI 名 |
|---|---|---|---|
| 宣纸米 | `#F5EFE1` | 主背景(替代黑渐变) | `BaziTheme.paper` |
| 浅宣 | `#EBE3D0` | 卡片底色 | `BaziTheme.cardSurface` |
| 浓墨 | `#1C1C1C` | 主文字 | `BaziTheme.ink` |
| 灰墨 | `#6B6557` | 弱说明文字 | `BaziTheme.inkMuted` |
| 朱砂红 | `#C33B3B` | 主强调 / CTA / 当前柱 | `BaziTheme.cinnabar` |
| 墨青 | `#2C5F3F` | 次强调 / 吉神 / 木行 | `BaziTheme.jade` |
| 黛蓝 | `#1D3A5F` | 三强调 / 水行 / 链接 | `BaziTheme.daiBlue` |
| 细线 | `#6B6557 @ 30%` | 0.5pt hairline divider | `BaziTheme.hairline` |
| 朱砂淡 | `#C33B3B @ 8%` | 当前柱 / 选中态底色 | `BaziTheme.cinnabarSoft` |

**五行色映射(用于五行平衡条 / 元素标签):**

| 五行 | Hex | 用途 |
|---|---|---|
| 木 | `#4A7A4A` | 木行段(降饱和绿) |
| 火 | `#B85A3A` | 火行段(降饱和赤) |
| 土 | `#A88848` | 土行段(降饱和黄) |
| 金 | `#8A8A82` | 金行段(降饱和白) |
| 水 | `#3A5A7A` | 水行段(降饱和玄) |

> 五行色全部**降饱和 20-30%** — 鲜艳饱和会落入"算命软件"气质,克制的五行色匹配宋瓷基调。

**Dark mode 策略:** 不只是反转,而是"墨夜瓷釉"。
- 底色由宣纸米 → 墨色 `#1A1815`(暖墨,非纯黑)
- 卡片底 `#25221D`
- 文字反转 `#E8E0CC`
- 朱砂提亮 `#D44A4A`(暗底需要更亮的红)
- 墨青 `#5A9978` / 黛蓝 `#6A8EB5`(同步提亮)

## Spacing

- **Base unit:** 8pt(全局 spacing 网格)
- **Density:** comfortable — 比现有 `VStack(spacing: 16)` 略松
- **Scale:**

| Token | Value | 用途 |
|---|---|---|
| `2xs` | 2pt | 微间距(图标与文字) |
| `xs` | 4pt | 紧凑间距(chip 内) |
| `sm` | 8pt | 同一组件内 |
| `md` | 16pt | 卡片内 padding / 横向 margin |
| `lg` | 24pt | Section 间距 |
| `xl` | 32pt | 大 Section 间距 |
| `2xl` | 48pt | 顶 / 底安全区附加 |
| `3xl` | 64pt | Hero 区上下 |

**SwiftUI 落地:** 定义 `BaziTheme.Spacing` enum with static lets。

## Layout

- **Approach:** grid-disciplined(严格网格,不做创意 editorial)
- **Grid:** 单列垂直流,横向严格 16pt margin(393pt 屏宽内内容区 361pt)
- **Max content width:** 393pt(iPhone 标准宽度,不做 iPad 自适应 — v1 只支持 iPhone)
- **全屏 sheet 例外:** onboarding 等全屏 sheet 横向 margin 用 32pt(`Spacing.xl`),而非标准 16pt — 全屏内容需要更宽的呼吸感,16pt 在 sheet 里会显得局促
- **Border radius(克制层级):**

| Token | Value | 用途 |
|---|---|---|
| `sm` | 4pt | 按钮 / 卡片(默认) |
| `md` | 8pt | 大卡片 / sheet |
| `lg` | 12pt | Modal |
| `full` | 9999pt | Capsule(仅 pill chip) |

> 现有代码 `Capsule()` 用得过多 → 改为 4pt 圆角(Capsule 只留给 chip)。

**分隔策略:**
- **0.5pt hairline**(`Color(red: 0x6b/255, green: 0x65/255, blue: 0x57/255).opacity(0.3)`)做卡片间 / 表格列间分隔
- **不用阴影**(现有代码无阴影,保持)
- **不用 neumorphism / 玻璃态**

## Motion

- **Approach:** minimal-functional — 只为辅助理解做动效,无装饰动效
- **Easing:** enter(`.easeOut`) exit(`.easeIn`) move(`.easeInOut`)
- **Duration:**

| 类型 | 时长 | 用途 |
|---|---|---|
| micro | 80-100ms | 按钮高亮 / chip 选中 |
| short | 200ms | 卡片淡入 / 状态切换 |
| medium | 350ms | sheet 进出 / 大区域切换 |

**禁止:** 弹簧反弹(非必要)、视差滚动、自动轮播、装饰性发光。

**SwiftUI 落地:** `.animation(.easeOut(duration: 0.2), value: state)`。

## SAFE CHOICES(国内用户期待的底线)

1. **保留命理文化感** — Songti SC + 宣纸底 + 朱砂红,不是 Co-Star 式纯黑白(纯黑白会让国内用户觉得"不像命理")
2. **五行色映射可识别** — 木青 / 火赤 / 土黄 / 金白 / 水玄 用户一眼能读懂
3. **保留排盘表格结构** — 四柱 / 神煞 / 五行 / 喜忌 / 大运的信息层级符合用户心智

## RISKS(差异化来源)

1. **砍掉黑金渐变背景** — 国内命理 App 默认都黑金,QiCompass 改白底宣纸。
   - **得到:** 视觉区隔,显得专业真诚
   - **代价:** 需要重新教育用户"我们不是算命软件"

2. **用 Songti SC 衬线扛标题** — 国内 App 大多用 PingFang 一招鲜,宋体显得"慢、重、文气"。
   - **得到:** 文化分量 + 品牌识别,匹配"专业研究工具"定位
   - **代价:** 信息密度高的页面宋体识别速度比黑体慢 5-10%(可接受,因为产品定位不是工具效率)

3. **朱砂红做主 CTA 而不是金色** — 金色 = 玄学套路,朱砂红 = 古籍印鉴 + 道法镇煞正色,语义更准确。
   - **得到:** 视觉记忆点 + 文化正确性
   - **代价:** 朱砂饱和度高,**只能用在 1-2 处**(主 CTA + 当前柱高亮),否则刺眼

## iOS SwiftUI 落地计划

### Step 1: 重构 BaziTheme token(根目录优先级 P0)

**替换** `iOS/QiCompass/QiCompass/App/RootTabView.swift` 内的 `enum BaziTheme`(line 55-71):

```swift
enum BaziTheme {
    // 背景(替代黑渐变)
    static let paper         = Color(red: 0xF5/255, green: 0xEF/255, blue: 0xE1/255)
    static let cardSurface   = Color(red: 0xEB/255, green: 0xE3/255, blue: 0xD0/255)

    // 文字
    static let ink           = Color(red: 0x1C/255, green: 0x1C/255, blue: 0x1C/255)
    static let inkMuted      = Color(red: 0x6B/255, green: 0x65/255, blue: 0x57/255)

    // 强调
    static let cinnabar      = Color(red: 0xC3/255, green: 0x3B/255, blue: 0x3B/255)
    static let cinnabarSoft  = cinnabar.opacity(0.08)
    static let jade          = Color(red: 0x2C/255, green: 0x5F/255, blue: 0x3F/255)
    static let daiBlue       = Color(red: 0x1D/255, green: 0x3A/255, blue: 0x5F/255)

    // 细线
    static let hairline      = inkMuted.opacity(0.3)

    // 旧 token(过渡期 alias,逐步替换调用点后删除)
    static let bgTop         = paper
    static let bgMid         = paper
    static let bgBottom      = paper
    static let gold          = cinnabar        // ⚠️ 语义改变:gold 改指 cinnabar
    static let goldLight     = paper           // ⚠️ 反色场景由 ink 接管
    static let text          = ink
    static let textDim       = inkMuted

    // 背景渐变 → 纯色
    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [paper, paper, paper],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension BaziTheme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }
    enum Radius {
        static let sm: CGFloat = 4
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
    }
}
```

**保留旧 token alias** 是为了**渐进重构**:不会让全代码 base 一夜之间 break,而是一边改 UI 一边把对 `gold` 的调用改成 `cinnabar` / `jade` 等更精确的语义,最后删除 alias。

### Step 2: 全局散点修复(代码搜索)

搜索以下旧用法,逐个替换:

| 搜索 | 替换 | 语义 |
|---|---|---|
| `BaziTheme.gold` 用作主 CTA | `BaziTheme.cinnabar` | 朱砂替代金 |
| `BaziTheme.gold` 用作吉神 chip | `BaziTheme.jade` | 墨青替代金 |
| `BaziTheme.goldLight` | `BaziTheme.paper` 或 `Color.white`(看场景) | 反色背景 |
| `Color.white.opacity(0.0x)` | `BaziTheme.cardSurface` | 散落白底统一 |
| `BaziTheme.backgroundGradient` | `BaziTheme.paper`(纯色) | 渐变 → 纯色 |

### Step 3: 逐模块 UI 重构(优先级)

| 优先级 | 模块 | 主要工作 | 预期改动 |
|---|---|---|---|
| P0 | `RootTabView` + `BaziTheme` | token 重构 + 渐变→纯色 | 30 行 |
| P0 | `BirthFormView`(首屏) | 表单 / 按钮 / 背景 | 50 行 |
| P1 | `DeepAnalysisResultView` + `PillarsTable` + `ChartHeaderView` | 四柱表 / 字体 / 朱砂高亮 | 80 行 |
| P1 | `XijiCard` + `ElementBalanceBar` + `ShenshaChips` | 五行色 + chip 样式 | 60 行 |
| P1 | `LuckPillarsTimeline` | 大运时间线 + 朱砂当前柱标记 | 40 行 |
| P2 | `DailyFortuneMainView` + 子组件 | 每日运势主页 | 80 行 |
| P2 | `CompatibilityView` + 子组件 | 合盘对比 / 四维定性 | 100 行 |
| P3 | 空态 / 加载态 / 错误态 | `EmptyStateView` / `LoadingStateView` / `SuccessCardView` 视觉统一 | 40 行 |

**估算总改动:** ~500 行 SwiftUI 代码,集中在 `Features/` 目录。

### Step 4: 验收清单(落地后必须满足)

- [ ] `BaziTheme.gold` 调用次数 = 0(全部迁移到 `cinnabar`/`jade`)
- [ ] `backgroundGradient` 调用次数 = 0(全部改成 `paper` 纯色)
- [ ] `Color.white.opacity(...)` 散落写法 = 0(统一 `cardSurface`)
- [ ] `Songti SC` 用在所有八字字符(`pillar-gan` / `pillar-zhi` / `luck-gz`)
- [ ] 朱砂红只在 CTA + 当前柱 + 忌神 三类场景出现
- [ ] 圆角默认 4pt,Capsule 只用在 chip
- [ ] 0.5pt hairline 替代所有 divider
- [ ] Dark mode 在所有页面正确显示(墨夜瓷釉配色)

## Decisions Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-07-13 | 初始设计系统创建 | design-consultation skill 基于 EUREKA 推导(命理 App 默认堆黑金,QiCompass 反向操作走宋瓷极简)+ CLAUDE.md "LLM 只润色不判断 / 诚实告知从格边界" 产品姿态 + 国内(测测/知命/问真)+ 海外(Co-Star/The Pattern)竞品研究 |
| 2026-07-13 | 砍掉 BaziTheme 黑金渐变 | 黑金是国内命理 App 同质化元凶,EUREKA 推导下 QiCompass 应该走反向 |
| 2026-07-13 | Songti SC 替代 PingFang 一招鲜 | 宋体压住命理主题文化分量,匹配"专业研究工具"定位 |
| 2026-07-13 | 朱砂红替代金色做主 CTA | 金色=玄学套路,朱砂=古籍印鉴+道法镇煞正色,语义更准 |
| 2026-07-13 | 五行色全部降饱和 20-30% | 鲜艳五行色落入"算命软件"气质,降饱和匹配宋瓷基调 |
| 2026-07-13 | 不打包自定义字体 | iOS 系统 Songti SC + PingFang SC + SF Pro 已够用,免打包体积 |
