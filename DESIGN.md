# Design System — 玄机问道 QiCompass

> 全局视觉事实源。任何 UI 决策(颜色 / 字体 / 间距 / 圆角 / 动效)都必须先读这里,偏离须用户明确批准。
>
> **2026-08-26 换轨**:宋瓷暖白 → **水墨孤本**(冷灰宣纸 / 焦墨 / 楷体 / 印章级朱红)。换轨依据:7 轮 design-shotgun 全旅程探索,决策记录与 24 屏参考在 `docs/design-ref/shuimo/`(approved.json 为事实源)。旧宋瓷系统的历史决策见文末 Decisions Log。

## Product Context

- **What this is:** AI 八字命理 iOS App,三模块(深度解析 / 合盘 / 每日运势)
- **Who it's for:** 想认真研究命理的中文用户(非娱乐化算命受众)
- **Space/industry:** 命理 / 玄学 / 占Astrology,对标:测测 / 知命 / 问真八字(国内)、Co-Star / The Pattern(海外)
- **Project type:** iOS native mobile app,SwiftUI,最低 iOS 17.2

## Memorable Thing

> **"专业不忽悠,不像算命软件。"**

用户第一次打开 3 秒后闭上眼,应该记住的事:一张**冷宣纸上的焦墨圆**,一枚**朱印**,一行**竖排楷体**。安静、克制、像一本还没翻开的手抄孤本。

每个设计决策都要服务这件事。

## Aesthetic Direction

- **Direction:** 水墨孤本(禅意水墨极简)
- **Decoration level:** minimal — 冷灰宣纸底 + 确定性纸纹噪点(4% 级),无渐变,无装饰图案,留白驱动,**卡片让位于 hairline 分隔**
- **Mood:** 冷宣纸 / 焦墨 / 竖排古书 / 印章落定。让命理内容自己说话,UI 不抢戏。
- **Signature elements(品牌指纹,跨模块复用):**
  - **墨圆 EnsoView** — 开机转场 / onboarding 承接 / 生肖揭晓 hero / 排盘布算
  - **朱印 SealStamp** — 品牌印「玄」、付费墙「解」印、合盘「合」印、批语「批」印
  - **竖排楷体 VText** — 标题、经文、批语、加载文案
  - **大写数字编号 壹-捌** — 深度解析捌章卷轴、付费章清单
- **Reference:** 探索产物 24 屏 HTML(`docs/design-ref/shuimo/`);精神参考不变(Co-Star 的克制 + 东方古籍气质)

## Typography

iOS 系统字体,**不打包任何自定义字体**。楷体走 `Font.custom("Kaiti SC")`(iOS 自带;若模拟器不渲染备选 "STKaiti")。

- **Display/Hero/Heading/Ganzhi:** `Kaiti SC` — 楷体扛全部中文展示层,书卷气 + 手写感呼应水墨
- **Body(正文):** `Kaiti SC` — 阅读页楷体 15.5pt 行距 2.15×,首行缩进 2em(古籍排版)
- **Latin caps(QICOMPASS 标):** system + `.tracking(大间距)`(约 0.55em),8.5-10pt
- **Numeric/Data:** `SF Pro Text` + `tabular-nums` — 西文数字对齐(排盘表格 / 日期)

**Type scale(基于 iOS 17.2 Dynamic Type):**

| 角色 | 字号 | 字重 | 用途 |
|---|---|---|---|
| Display | 32pt | Medium | 命盘大标题 |
| H1 | 28pt | Medium | 页面标题 |
| H2 | 22pt | Medium | Section 标题 |
| H3 | 17pt | Medium | 卡片标题 |
| Body | 15.5-16pt | Regular | 正文(楷体,行距 2.1-2.15×) |
| Caption | 13pt | Regular | 说明 |
| Micro | 10-11pt | Regular | 标签 / 元信息 |
| LatinCaps | 8.5-10pt | Regular | QICOMPASS 字距标 |
| Ganzhi-L | 30-32pt | Medium | 八字天干地支(主显) |
| Ganzhi-M | 22pt | Medium | 大运干支 |
| Ganzhi-S | 14pt | Medium | 时辰干支 |

**SwiftUI 落地:** `BaziFont.display(size:)` 等既有 API 不变,内部换 Kaiti;新增 `BaziFont.latinCaps(size:)`。

## Color

**Approach:** restrained(克制)— 焦墨做主角(CTA 一律浓墨),朱红只做**印章级小元素**,墨青做吉向。颜色出现频率稀少且有意义。

| 角色 | Light Hex | Dark Hex(夜宣纸) | 用途 | SwiftUI 名 |
|---|---|---|---|---|
| 冷灰宣纸 / 夜宣纸 | `#F3F1EC` | `#141317` | 主背景 | `BaziTheme.paper` |
| 浅纸 / 深浅纸 | `#F7F5F0` | `#1E1D23` | sheet 底 / 残留卡底(让位 hairline 中) | `BaziTheme.cardSurface` |
| 浓墨 / 冷白 | `#1C1B1E` | `#E9E7E2` | 主文字 | `BaziTheme.ink` |
| 灰墨 / 浅灰墨 | `#77726A` | `#9B968C` | 弱说明文字 | `BaziTheme.inkMuted` |
| 淡灰墨(新) | `#A5A098` | `#6E6A62` | 二级弱注 | `BaziTheme.inkMutedSecondary` |
| 焦墨 / 冷白(新) | `#17161A` | `#E9E7E2` | **CTA 底** / enso 笔触(暗色反转) | `BaziTheme.inkDeep` |
| CTA 前景(新) | `#F3F1EC` | `#17161A` | CTA 文字(与 inkDeep 成对) | `BaziTheme.onInkDeep` |
| 印章朱红 / 亮朱红 | `#A83226` | `#C25143` | **印章级专用:SealStamp / 付费标 / 聚焦线 / 当前时辰点 / 在读态。禁止 CTA、禁止大面积** | `BaziTheme.cinnabar` |
| 墨青 / 亮墨青 | `#2F5E4A` | `#6FA08A` | 吉向 / 好朋友 chip / 宜 | `BaziTheme.jade` |
| 黛墨蓝 / 亮黛蓝 | `#3D4A5C` | `#7E93AC` | 三强调 / 水行 / 链接(降饱和) | `BaziTheme.daiBlue` |
| 细线 | ink @ 18% | ink @ 22% | 0.5-1pt hairline divider | `BaziTheme.hairline` |
| 虚线细线(新) | inkMuted @ 35% | @ 40% | 锁定框 / 临时态虚线 | `BaziTheme.hairlineDashed` |
| 朱砂淡 | `#A83226 @ 10%` | `#C25143 @ 14%` | 选中态底色(极少量) | `BaziTheme.cinnabarSoft` |
| 破坏红 | `#A83226` | `#C25143` | 错误 / 破坏性(与 cinnabar 同值,语义独立) | `BaziTheme.destructive` |

**Dark mode 实现策略:** 走 `Color(UIColor { traitCollection in ... })` 动态色(`BaziTheme.dyn` helper),色值集中在 RootTabView.swift 单文件与本表一一对应。夜宣纸不是反转而是**冷的**:底 `#141317`、纸面 `#1E1D23`、冷白文字 `#E9E7E2`;**焦墨 CTA 在暗色下反转**(冷白底 + 焦墨字)。

**五行色映射(降饱和 ~40%,进一步压向墨色):**

| 五行 | Hex | 用途 |
|---|---|---|
| 木 | `#466F46` | 木行段 |
| 火 | `#A85A42` | 火行段 |
| 土 | `#A6801E` | 土行段 |
| 金 | `#807E76` | 金行段 |
| 水 | `#3C5568` | 水行段 |

> 暗色各提亮约 20% 亮度。五行色保持"可识别但不鲜艳"。

## Spacing

- **Base unit:** 8pt(不变)
- **Density:** comfortable,水墨语言下更松——正文区左右 margin 34-36pt,阅读页更宽
- **Scale:** `xs 4 / sm 8 / cmd 12 / md 16 / lg 24 / xl 32 / xxl 48`(`BaziTheme.Spacing`,不变)

## Layout

- **Approach:** 开放布局优先——**卡片让位于 hairline 分隔**;仅 sheet / 锁框保留容器底色
- **分隔策略:**
  - 0.5-1pt hairline(ink @ 18%)做行/段分隔
  - **dashed hairline**(inkMuted @ 35%,dash [4,3])专用于锁定框 / 临时态 / 未登录框
  - 不用阴影 / neumorphism / 玻璃态(不变)
- **Border radius:** `sm 4pt`(默认)/ CTA 5pt / `md 8pt`(sheet)/ `lg 12pt`(modal);Capsule 只留给 chip
- **章节编号:** 大写数字(壹贰叁肆伍陆柒捌)圆徽——实线圆=可读,虚线圆=锁定(`NumeralBadge`)
- **付费标识:** `PaidTag`「付费」白字朱底小方标,旋转 -6°,**只此一处用朱底块**
- **Tab:** 墨物线描四枚矢量图标(`TabIcons.swift`)+ 楷体文字,tint=ink;系统 TabView + ImageRenderer 模板渲染(2026-08-30 拍板,替代原纯文字 tab;几何事实源 `~/.gstack/projects/qingqingyu-QiCompass/designs/tab-icons-20260830/finalized.html`。今日=墨圆环抱点(EnsoView 同源)/深度=三叠横墨/合盘=双环交叠/我的=未钤空心印;朱红不出现在 tab 层)
- **每日运势 V4「一幅图为主角」**(2026-08-30 拍板,事实源 `~/.gstack/projects/qingqingyu-QiCompass/designs/daily-fortune-art-20260830/`,用户参考图像素级复刻):第一屏 = 三行日期区(公历大字 19/农历·干支 12.5/短标签+关系+冲 chips)→ **3:2 五行小景水墨插画**(左右 17pt 边距,右下干支竖排+左下朱印为客户端 Kaiti 矢量叠加,不靠生图写字;深色模式插画保持浅纸底=「暗夜里的一张画」)→ 宜忌单行居中 → AI 解读 → hairline 小注;第二屏 = 7 日历史带 + 明日预告(吸顶方向感知折叠机制随 V4 移除)。插画当前为内置静态样图(`DailyFortuneHeroSample`),后续切后端 gpt-image-2 每命主每日一幅(生成+缓存,详见 `~/.claude/plans/dapper-hopping-puzzle.md`)

## Motion

- **Approach:** 墨的物理——入场即墨迹落纸,克制而确定
- **三式标准动效:**

| 名称 | 参数 | 用途 |
|---|---|---|
| ink-in | opacity 0→1 + blur 7→0,1.2-1.6s easeOut | 墨圆 / 大标题入场 |
| stamp | scale 1.9→1,spring 回弹,0.5s | 印章落定(SealStamp) |
| breathe | opacity 1↔0.92,7-8s 循环 | 常驻元素微呼吸(墨圆/水印) |

- **Reduce Motion:** 全部降级为 0.3s 纯淡入或不动的静态呈现(`MotionPreferences`)
- **禁止:** 弹簧反弹( stamp 除外)、视差滚动、自动轮播、装饰性发光(不变)

## SAFE CHOICES(国内用户期待的底线)

1. **保留命理文化感** — 楷体 + 墨圆 + 朱印,文化分量比宋瓷更足,且依然不是黑金套路
2. **五行色映射可识别** — 木青 / 火赤 / 土黄 / 金白 / 水玄,降饱和但保持色相
3. **保留排盘表格结构** — 四柱 / 神煞 / 五行 / 喜忌 / 大运的信息层级符合用户心智(不因去卡片化破坏)

## RISKS(差异化来源)

1. **楷体扛全部展示层** — 楷体比宋体更"手写",识别速度略慢
   - **得到:** 书卷孤本气质,与所有竞品黑体/宋体拉开差距
   - **代价:** 信息密集页(四柱表)用 Ganzhi 尺度足够大时可接受;`Font.custom("Kaiti SC")` 需模拟器实测
2. **卡片让位 hairline** — 国内 App 习惯卡片分层
   - **得到:** 留白驱动的"一卷读完",最不像软件
   - **代价:** 结构重排工作量大(分四阶段);层级感靠 spacing + hairline + 字重维持
3. **朱红退出 CTA** — 朱底按钮是行业肌肉记忆
   - **得到:** 朱印级朱红出现即有意义(付费标 / 印章 / 当前时辰),稀缺即贵
   - **代价:** CTA 依赖浓墨块的对比度,暗色下反转逻辑必须成对(inkDeep/onInkDeep)

## iOS SwiftUI 落地计划

### Step 1: BaziTheme token 换值(Phase 1,P0)

**token 名全部保留**(600+ 引用零改动),就地改值 + 增补新 token。`cinnabar` 语义注释改为「印章级专用,禁止 CTA」。

```swift
enum BaziTheme {
    static let paper    = dyn(#F3F1EC, #141317)   // 冷灰宣纸 / 夜宣纸
    static let cardSurface = dyn(#F7F5F0, #1E1D23)
    static let ink      = dyn(#1C1B1E, #E9E7E2)
    static let inkMuted = dyn(#77726A, #9B968C)
    static let inkMutedSecondary = dyn(#A5A098, #6E6A62)  // 新
    static let inkDeep  = dyn(#17161A, #E9E7E2)   // 新:焦墨 CTA 底(暗色反转)
    static let onInkDeep = dyn(#F3F1EC, #17161A)  // 新:CTA 前景
    static let cinnabar = dyn(#A83226, #C25143)   // 印章级专用,禁止 CTA
    static let cinnabarSoft = cinnabar.opacity(0.10)
    static let jade     = dyn(#2F5E4A, #6FA08A)
    static let daiBlue  = dyn(#3D4A5C, #7E93AC)
    static let hairline = ink.opacity(0.18)
    static let hairlineDashed = inkMuted.opacity(0.35)  // 新
    // Spacing / Radius 不变;PrimaryCTAButton 内部 radius 用 5
}
```

### Step 2: 全局散点修复(代码搜索)

| 搜索 | 替换 / 处理 | 语义 |
|---|---|---|
| `cinnabar` 全部引用 | 逐个复核:强调误用 → `ink`;印章时刻保留 | 朱红语义收窄 |
| `PrimaryCTAButton` 样式 | bg `inkDeep` / fg `onInkDeep` / radius 5 / 尾端朱色菱形印点 | 全 App CTA 浓墨化 |
| `Label(_, systemImage:)` tabItem | `Label { Text } icon: { TabIcons 模板图 }` + `.tint(ink)` | 墨物线描矢量 tab(2026-08-30 迭代) |
| `AccentColor.colorset`(#C9A03C 金) | `#F3F1EC`(launch 底色=转场底色) | 启动屏与转场无缝 |
| `WelcomeBackground` 资产 | 删除(仅 WelcomePage 引用,改原生墨圆构图) | 壁画图与新语言冲突 |
| `Capsule()` 非 chip 用途 | radius 4-5 圆角 | Capsule 只留 chip |

### Step 3: 逐模块 UI 重构(优先级 = 实施阶段)

> **落地状态(2026-08-26):四阶段全部完成并合入 main(merge d9d99d2;Phase 提交 909edbe / ce925f2 / b77d63b / b2e63c5),每阶段 161 测试全绿。**

| 阶段 | 模块 | 主要工作 | 参考 | 状态 |
|---|---|---|---|---|
| Phase 1 | RootTabView + BaziTheme + BaziFont + PrimaryCTAButton + 新组件 InkKit/SplashTransitionView | token/字体/CTA/tab/启动转场 | variant-c-shuimo.html | ✅ |
| Phase 2 | Onboarding O1-O4 + DailyFortune T1 | O1 墨圆承接(删壁画图) / O3 墨圆布算 / T1 去卡重排;**O2 表单与 O4 揭晓为 token 携带**(结构重排遗留) | onboarding-o*.html / daily-t1.html | ✅(含遗留) |
| Phase 3 | DeepAnalysis 捌章卷轴 + PaywallView + 阅读页 | NumeralBadge 行 / 「解」印 sheet;**朱字批语未做**(需 prompt 输出,动 prompts.py 触发 evalkit 守护栏须先跑基线) | deep-p1..p4.html | ✅(含遗留) |
| Phase 4 | Compatibility H1-H3 + Profile M1/M2 | 对卡/合印/定性网格/命主块;**双柱合印中轴与 M2 引导盒为 token 携带** | hepan-*.html / mine-*.html | ✅(含遗留) |

**新组件(Shared/InkKit.swift):** `VText` / `EnsoView` / `SealStamp`(自 OnboardingView 迁出) / `PaperGrain`(Canvas 确定性噪点) / `NumeralBadge` / `PaidTag`;**Shared/SplashTransitionView.swift**。新文件须 pbxproj 4 处登记一致 24 位 ID(objectVersion 56)。

### Step 4: 验收清单(2026-08-26 核对)

- [x] 每阶段 xcodebuild build + 全量测试绿(161/161 × 4 阶段;commits 三段式 Why/What/Impact)
- [x] `cinnabar` 零 CTA / 零大面积底色使用(全 App grep 清零,仅印章级授权场景)
- [x] 所有 CTA = inkDeep 底 + onInkDeep 字(暗色正确反转)
- [x] Kaiti SC 在模拟器真实渲染(非系统回退;截图核对)
- [x] 竖排文字全部走 VText;章节编号全部大写数字
- [x] 开机转场:冷启动墨圆 ink-in → 玄印 stamp → 1.65s 淡出,全程 allowsHitTesting(false),reduce-motion 静态降级
- [ ] Dark mode 夜宣纸全页走查(转场/欢迎/浅深截图已核,余下三 tab 深色人工走查待用户验收)
- [x] `WelcomeBackground` 引用与资产清零
- [x] 对照 docs/design-ref/shuimo/ 逐屏核对(对照板:`~/.gstack/.../compare-ios-vs-html.html`,结构性还原 8 屏 / token 携带 6 屏 / 未做 1 屏)
- [ ] **英文 locale 走查**:Kaiti 拉丁字形与 VText 竖排的英文适配(见 Decisions Log 待办)

## Decisions Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-07-13 | 初始设计系统创建(宋瓷极简) | design-consultation 基于 EUREKA 推导 + 竞品研究 |
| 2026-07-13 | 砍掉黑金渐变 / Songti SC 扛标题 / 朱砂替代金 CTA / 五行降饱和 | 反向操作国内命理套路 |
| 2026-07-22 | paper 宣纸米 `#F5EFE1` 调浅为 `#FDFCFA` | 留白驱动,暖色收进卡片 |
| 2026-08-01 | Copy voice 不进 DESIGN.md | voice 归 prompt 工程范畴,视觉与文案解耦 |
| 2026-08-26 | **换轨:宋瓷暖白 → 水墨孤本** | 7 轮 design-shotgun 全旅程探索(开机页/onboarding/今日/深度付费/合盘/我的),黑金/星空/国潮均未入选,两轮内部迭代回到最留白原案——留白审美是稳定硬约束。事实源 `docs/design-ref/shuimo/approved.json` |
| 2026-08-26 | 朱红退出 CTA,降为印章级点缀 | 「极少量高饱和点缀」原则;CTA 一律浓墨(inkDeep/onInkDeep 成对,暗色反转) |
| 2026-08-26 | Songti SC → Kaiti SC(楷体)全展示层 | 孤本手抄气质;竖排/批语/大写数字为品牌指纹 |
| 2026-08-26 | 卡片让位 hairline;dashed 锁框;纸纹 Canvas 确定性噪点(不引入图片链路) | 开放布局 + 零新依赖 |
| 2026-08-26 | **待办:英文 locale 字体路由**——Kaiti SC 拉丁字形偏楷书衬线,英文正文可用性待验证;方向:display 中文 Kaiti / 英文回退系统 serif;body 英文走系统 sans;VText 仅用于中文(英文横排,沿用 SutraView locale 分流模式);印章/品牌字(玄机问道/玄/解/合)保持中文不翻译(决策 7 术语族) | i18n v1 中英开口子(2026-08-12)与新字体体系交叉,落地前须英文截图走查 |
| 2026-08-26 | T3 签纸分享卡 backlog(不做入 v1 换装) | 分享卡是图片生成新功能,与换装解耦;今日首页用 T1 墨白节奏 |
