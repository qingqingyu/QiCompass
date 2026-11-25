# KnowFate 官网设计稿 · 水墨孤本 × SEO(2026-11-24)

> 交付对象:负责实现的 AI / 工程师。本目录是**设计稿 + 实现规格**,不是生产代码。
> 上游决策:`docs/SEO站设计决策.md`(11-02 拍板 8 项,本稿全部沿用)、`DESIGN.md`(水墨孤本视觉事实源)、`docs/后端部署设计决策.md` D4(域名 `knowfate.app`)。
> 打开 `index.html` 看总览看板;四个页面均可直接在浏览器打开交互。
> **实施任务清单**:`docs/官网实现-slices/`(12 个 slice,按顺序逐个完成)。

## 文件

| 文件 | 内容 |
|---|---|
| `index.html` | 设计看板:四页预览(桌面 + 手机)、标志性交互、OG 卡模板、色板、Mobbin 参考 |
| `home.html` | 首页 `/en/` |
| `calculator.html` | 免费排盘器 `/en/bazi-calculator` |
| `article.html` | 知识页模板,以 `/en/day-master/jia-wood` 为样张(程序化页面全部复用此骨架) |
| `library.html` | 命理辞典总索引 `/en/library`(含六十甲子矩阵) |
| `assets/site.css` | Web 端 token + 组件(DESIGN.md 的 Web 映射,**token 值可直接搬**) |
| `assets/site.js` | 渐进增强交互原型(释义卡 / 章节轨 / 吸底 CTA / 揭示动效 / 时辰盘 / 日主查询 mock) |

样例数据均由 `lunar_python` 1.4.8 实算:今日 2026-11-24 = 丙午年 己亥月 壬寅日(农历十月十六,小雪);样例命盘 1992-04-18 09:30 北京男 = 壬申 甲辰 甲子 己巳,起运 7 岁顺行。**旺衰 / 喜忌数值是占位**(页面里有蓝框注释),上线时只能取后端规则引擎的输出。

---

## 1. 从 Rasty / Vault Air 案例提炼的原则 → 落到 KnowFate(原 QiCompass)

| 案例里的做法 | 为什么有效 | 本站怎么落地 |
|---|---|---|
| 老对手只在 App Store 卷排名,不做网页 SEO | 网页长尾词是无人区 | 英文八字是小众赛道:头部是 Joey Yap 这类课程站和工具站,**「专业 + 克制 + 现代设计」的知识站是空位**(需上线前用 Keyword Planner / Ahrefs 免费版复核关键词竞争度,本稿未做数据验证) |
| 覆盖所有指向同一功能的长尾词 | 单个词流量小,加起来可观且精准 | **程序化矩阵**:10 日主、10 十神、5 五行 ×3、20 神煞、60 日柱、10×12 日主×月令、55 日主配对……每一格都是一个真实搜索意图(§3) |
| 每天只发一篇高质量内容 | 谷歌偏好「少而精」,避开内容农场判定 | AI 起草 → 引擎事实核对 → 人工过目 → `forbidden_words` 校验 → 发布;一天一篇,不批量灌(§8) |
| 每天看「高曝光、零点击」的词 | 已有排名,只差标题或内容 | GSC 周报:曝光 >500、CTR <1%、排名 8–30 的页面 → 改 title / meta / 补 In-short 段 → 从高流量页加内链(§8) |
| 内部链接把流量导向新文章 | 加快收录、传递权重 | 每页至少 8 条上下文内链;术语释义卡、面包屑、相邻导航、Library 总索引共同构成网状结构(§5) |
| CTA 放在常见的退出点 | 网站 10% 转化 | 三处 CTA:读完答案后的内联条、文末「批」印之后、手机端吸底条;工具结果页放虚线锁框(§7) |
| 产品超细分 | 精准用户转化高 | 只讲八字(四柱),不做星座 / 塔罗 / 紫微,语气「专业不忽悠」 |
| 内容会被 LLM 引用 | AI 搜索成为新入口 | 答案先行段落、定义句式、结构化数据、`llms.txt`、术语中英并列(§6) |

额外的「钩子」:**免费排盘器**本身就是外链磁铁和反复访问的入口(Upwork / incident.io 的计算器页模式),每张结果都是内链分发器。

## 2. 定位与边界(沿用 11-02 拍板)

- 内容站 + 免费排盘工具;排盘只出**确定性**结果(四柱 / 十神 / 藏干 / 纳音 / 长生 / 五行 / 旺衰喜忌 / 大运 / 神煞),**不在网页上调用 LLM**
- 要 AI 解读 → 引导下载 App;网页上不卖任何东西
- 英文优先 + 繁中(`/en/`、`/zh-hant/`);简中以后再加;不做百度
- 上架前所有 CTA 用「Notify me at launch」(Buttondown 收邮箱),上架后用同一个组件切换成 App Store 徽章(配置开关,见 §7)

## 3. 信息架构与 URL

URL 规则:`/{lang}/{type}/{slug}`,全小写、拼音加连字符、无尾斜杠。每页 hreflang 互指,`x-default` 指向 en。

| 类型 | URL 样例 | 数量 | 批次 | 主搜索意图(en) |
|---|---|---|---|---|
| 首页 | `/en/` | 1 | 一 | bazi calculator · four pillars of destiny |
| 排盘器 | `/en/bazi-calculator` | 1 | 一(待后端部署) | bazi calculator free · bazi chart |
| 日主查询 | `/en/day-master-calculator` | 1 | 一 | what is my day master |
| 日主 | `/en/day-master/jia-wood` | 10 | 一 | jia wood day master · yi wood personality |
| 十神 | `/en/ten-gods/eating-god` | 10 + 总览 | 一 | eating god bazi · seven killings meaning |
| 五行 | `/en/five-elements/wood`、`/too-much-wood`、`/missing-wood` | 15 + 总览 | 一(先做 5 个总览) | too much fire bazi · missing water bazi |
| 神煞 | `/en/stars/peach-blossom` | 20 + 总览 | 一(先做 6–8 个高搜索量的) | peach blossom bazi · nobleman star |
| 指南 | `/en/guides/how-to-read-a-bazi-chart` | 持续 | 一(3–5 篇 + 入口指南 1 篇) | how to read bazi chart · bazi unknown birth time |
| 入口指南(11-25 新增) | `/en/guides/chinese-astrology-and-bazi` | 1 | **一** | chinese astrology · chinese astrology vs bazi · what is chinese astrology |
| 辞典 | `/en/library` | 1 | 一 | bazi terms |
| 术语 | `/en/glossary/day-master` | ~20 | 二 | hidden stems bazi · luck pillar meaning |
| 日柱 | `/en/day-pillar/jia-zi` | 60 | 二 | jia zi day pillar · ren yin day |
| 今日 | `/en/today` | 1(每日更新) | 二 | chinese calendar today · today's day pillar |
| 日主 × 月令 | `/en/day-master/jia-wood/born-in-yin-month` | 120 | 二 | jia wood born in spring |
| 日主配对 | `/en/compatibility/jia-wood-and-ji-earth` | 55(无序对) | 二 | jia wood and ji earth compatibility |
| 生肖(= 地支,11-25 由第三批提前) | `/en/zodiac/horse`(12 页,地支与生肖合一) | 12 + 总览 | **二** | chinese zodiac horse · horse personality chinese zodiac · horse compatibility |
| 生肖年份 | `/en/zodiac/year-of-the-horse-2026`、`/en/zodiac/year-of-the-goat-2027` | 当年 + 次年,每年滚动新增 | **二** | year of the horse 2026 · chinese zodiac 2027 |
| 关于 / 隐私 / App | `/en/about` `/en/privacy` `/en/app` | 3 | 一 | — |

规范化规则:
- **天干不单独建页**:「甲」的落点就是 `/en/day-master/jia-wood`,避免内容重复(设计稿里所有天干链接已按此处理)。
- **地支不单独建页**:地支与生肖合一,「申」的落点就是 `/en/zodiac/monkey`(页面同时讲地支与生肖);设计稿里所有地支链接已按此处理(11-25)。
- 配对页只建无序对,`b-and-a` 301 到 `a-and-b`(按天干顺序)。
- 排盘结果、查询结果**永远不生成可收录的 URL**:带出生参数的地址一律 `noindex,follow`,canonical 指向干净 URL。个人数据不能做成「内容」。

## 4. 页面模板规格

### 4.1 首页(`home.html`)

区块顺序(H 结构):
1. **Hero** — H1「Free BaZi Calculator — the Four Pillars, read honestly.」;lede;**原生 GET 表单**(日期 / 时间 / 城市 + 不知时辰)→ 排盘器;右侧时辰盘
2. **Today 条** — 今日年 / 月 / 日干支、农历日、当前与下一个节气 → 链到 `/en/day-pillar/{今日}`。构建时生成;边缘缓存按 UTC+8 每天零点失效
3. 壹 **What is BaZi?**(H2)— 答案段(40–60 词)+ 四柱示意图(日柱用 cinnabarSoft 整列底色加左右朱线,与 iOS 细目页同口径)
4. 三条承诺(同盘 / 真时 / 不玄)— 差异化 + E-E-A-T
5. 贰 **The ten Day Masters** — 5×2 矩阵,悬停用 ink-in 补出一句释义;手机端 2 列,不显示释义
6. 叁 **Five Elements** 生克交互图 + 释义面板 + 专题内链
7. 肆 **Guides** — 编号列表,带阅读时长
8. **App** 区 — 命书捌章(前两章免费,其余付费标)+ 通知表单 / App Store 徽章 + 手机样机(直接复刻 App 首页)
9. 伍 **FAQ**(`<details>`,与 FAQPage JSON-LD 一一对应)
10. Footer — **全站内链枢纽**:10 日主 / 10 十神 / 五行与神煞 / 工具与指南;免责声明

### 4.2 排盘器(`calculator.html`)

- H1「BaZi Calculator — Four Pillars of Destiny」+ 一句话答案
- 左「生辰帖」(sticky):日期、时间、不知时辰、城市自动补全(显示时区 + 经度,数据复用 `cities.sqlite` 导出)、性别(注明仅用于大运顺逆)、规则说明(23:00 换日 / 节气定月)
- 右结果区,按以下顺序:元信息(含真太阳时修正量)→ chips(日主 / 日柱 / 生肖)→ **四柱表**(十神 / 天干 / 地支 / 藏干 / 纳音 / 长生)→ 五行比例条 → 旺衰与喜忌 → 大运横轴(当前一步加朱点)→ 神煞 chips → **虚线锁框「The reading」**(捌章清单 + App CTA)
- 下方:方法论四格(真太阳时 / 子初换日 / 节气定月 / 出处)+ FAQ
- 数据来源:`GET /api/public/chart`(决策 4:不签 context_token、不碰 LLM、按 IP 限流、CORS 只放行站点域名)。**客户端不做任何历法计算**——`site.js` 里的儒略日算法只是为了让 mock 能动,禁止进入生产
- 从格(special_pattern)时:旺衰显示「Special pattern」,喜忌显示「left open」,**不猜**
- 时辰未知:时柱显示虚线圆位 + 「Hour unknown」,其余照常
- JSON-LD:`WebApplication` + `HowTo` + `BreadcrumbList`

### 4.3 知识页模板(`article.html`,所有程序化页面共用骨架)

```
面包屑
Hero:墨圆 + 大字(五行色)+ 落印 | kicker / H1 / 副题 / 署名行(编辑 · 审校出处 · 更新日期 · 阅读时长)| 竖排题签
三栏:左 TOC 章节轨(壹–捌 + 墨线进度)| 正文 ≤680px | 右栏 sticky(小工具 + App 卡)
正文:
  In short 答案框(定义句,≤60 词)      ← 吸底 CTA 的触发锚点
  速查表 dl(8 项,含内链)
  H2 × 6–8(大写数字编号)
  第 2 个 H2 之后:内联 CTA(退出点 1)
  FAQ(2–4 问,与 JSON-LD 对应)
  「批」印收束 → 文末 CTA 面板(退出点 2)
  上一篇 / 下一篇(同类相邻,首尾循环)
  出处与方法说明 + 免责
```

各类型的 H2 骨架(保证每页都有足够的独有内容,防止被判为薄内容):

| 类型 | H2 骨架 | 独有数据来源 |
|---|---|---|
| 日主 | 描述什么 / 长短 / 按出生季节 / 旺与弱 / 与其他九日主 / 工作学习 / 在自己盘里怎么看 / FAQ | 十神关系表、季节表(后端规则) |
| 十神 | 是什么关系 / 透干与藏干的区别 / 过多与缺失 / 在各柱的含义 / 与其他十神的组合 / FAQ | 十神对照(`TEN_GODS_EN`) |
| 五行 | 象与性 / 过多 / 缺失 / 生克关系 / 季节 / FAQ | 五行色、生克图 |
| 神煞 | 查法(按日干或年支查表)/ 在各柱 / 常见误读 / FAQ | 《三命通会》单一查表 |
| 日柱 | 干支与纳音 / 自坐十神与长生 / 近期日期(未来 12 个同柱日)/ 名人不写 / FAQ | 引擎生成日期表 |
| 配对 | 十神关系 / 天干合冲 / 只看日主的局限 / 用合盘真正看什么 → App 合盘 | 规则生成 |
| 生肖 | 地支与五行 / 性格倾向(善意、不贴标签)/ 好朋友(六合 1 + 三合 2)与需磨合(六冲 1)/ 生肖年份列表 / **生肖按立春换年,不按春节**(很多网站按春节算,这是本站的差异化内容)/ 生肖只是八字的一个字 → 引向排盘器 / FAQ | 关系取后端 `branch_relations.py`(与 App 生肖屏、合盘引擎同一事实源);措辞沿用 App「好朋友 / 需磨合」,不用「不和谐」「相克」等恐吓词 |
| 生肖年份 | 该年年柱干支与纳音 / 起止时间(立春到次年立春)/ 与各生肖的关系 / 本命年说明(不写「犯太岁化解」)/ FAQ | 引擎导出 |
| 入口指南 | Chinese astrology 有哪些体系(生肖、八字、紫微等)/ 生肖只是年柱一个字,八字用全部八个字 / 什么时候看生肖、什么时候要排盘 → 链向生肖总览与排盘器 | 人工写作 |

JSON-LD:`Article`(含 `dateModified`、`citation`)+ `BreadcrumbList` + `FAQPage`;日主 / 十神 / 神煞的 `about` 写成 `DefinedTerm`。

### 4.4 Library(`library.html`)

- H1 + 搜索框(对静态 HTML 做过滤;每一项都是可抓取的真实 `<a>`)
- 吸顶分区 chips(当前分区高亮)
- 日主 10 → 十神按五族排(比劫 / 食伤 / 财 / 官杀 / 印)→ 五行各 3 个入口 → 神煞吉 11 / 煞 9 → **六十甲子 10×6 矩阵**(悬停显示纳音,今日日柱加朱点,搜索时不匹配的格子淡出)→ 术语 A–Z
- JSON-LD:`CollectionPage` + `DefinedTermSet`

## 5. 内链规则(实现时写进模板,不靠人工)

1. **枢纽与辐条**:首页、Library、Footer 链到全部一级页面;每个一级页面回链到所属总览和 Library。
2. **上下文内链**:正文首次出现的术语自动包成 `<a class="term">`(带释义卡数据),每个术语每页只包第一次出现;每页至少 8 条正文内链。
3. **相邻导航**:同类上一篇 / 下一篇(甲→乙…癸→甲)。
4. **关系表即内链**:日主页的「与其他九日主」→ 配对页;季节表 → 日主×月令页;排盘结果的每个字 → 对应页。
5. **新页导流**:新页面发布当天,从 3 个已有流量的相关页加上下文链接(案例里提到的「3–4 天见效」靠的就是这一步)。
6. 锚文本写成描述性文字(如 "Jia Wood Day Master"),不用 "click here"。

## 6. 技术 SEO 清单

- **Astro 静态输出**(决策 5),页面内容在 HTML 里;JS 只做增强。看板宣称的「关闭 JS 可读」是验收项
- title 模式:`{主词}: {副词} | KnowFate`,主词放最前,≤60 字符(超出时去掉品牌后缀);meta description 140–160 字符,写成一句完整的回答
- 每页:`canonical`、`hreflang`(en / zh-Hant / x-default)、OG / Twitter 标签、`og:image` 自动生成(看板里的 1200×630 模板:左标题、右墨圆大字,Satori 构建时渲染)
- `sitemap-index.xml` 按类型分片(`sitemap-day-master.xml`…),带 `lastmod`;`robots.txt` 屏蔽 `/*?d=` 这类参数 URL
- 结构化数据见 §4;`Organization`、`WebSite` 放在全站 `@graph`(`Organization.name` = KnowFate,`alternateName` = ["觀命", "观命"]);App 上架后首页加 `MobileApplication`(`name` = App Store 英文名「KnowFate - Chinese Astrology」,见 §13)
- `llms.txt`:站点简介 + 各类型总览链接 + 方法说明(写清「确定性规则 + 不预测」)
- **性能预算**(手机 4G):LCP < 2.0s,CLS < 0.02,INP < 150ms,首屏 JS < 15KB gzip
  - 字体:中文 = 思源宋体子集 woff2(复用 `tools/build_songti_fonts.py` 的字表,Web 端再按页面实际用字做子集),`font-display: swap`;英文标题 Newsreader 子集只 preload 一个字重;正文用系统无衬线,零下载
  - 墨圆 / 时辰盘 / 五行图全是内联 SVG,不用位图;纸纹是 240px 的 SVG 噪点 data-URI
  - 设计稿用 Google Fonts 只为方便预览,**上线必须自托管**
- 无障碍:时辰盘和五行图都有 `<title>`;交互节点可键盘操作;对比度 ≥ 4.5:1(`ink-muted-2` 只用于 ≥18px 的文字);`prefers-reduced-motion` 全部降级
- 分析:TelemetryDeck Web SDK(与 App 一致,无 cookie 横幅);App 下载链接带 `ct={pagetype}-{slug}-{slot}` 归因参数

## 7. 转化设计

| 位置 | 组件 | 文案方向 |
|---|---|---|
| 知识页答案框之后 | `.cta-inline`(大字 + 一句话 + 按钮) | "Is your Day Master Jia?" → 排盘器 |
| 文末「批」印之后 | `.cta-panel` | "This page describes every Jia. Your chart describes you." |
| 手机吸底条 | `.sticky-cta` | 答案框滚出视口后出现,接近 footer 时隐藏,可关闭(sessionStorage) |
| 右栏 | 日主查询 + App 卡 | 10 秒小工具 → 排盘器 → App |
| 排盘结果 | 虚线锁框捌章 | 「This is the structure. The app reads it to you」 |

- **两态 CTA**:`state=prelaunch` 显示邮箱表单(Buttondown,双重确认),`state=live` 显示 App Store 徽章;桌面端可加二维码(参考 ElevenLabs)。一个全局配置项切换
- 从网页到 App 的出生信息带入:Universal Link `https://knowfate.app/open?d=…&t=…&c=…` → App 预填出生表单(需要 iOS 侧配合,单独立项)
- 目标:知识页 → 排盘器点击率 ≥ 15%,排盘器 → App 点击 ≥ 10%(对标案例的 10%)

## 8. 内容生产与增长循环

```
周一:GSC 导出 → 选出「曝光高 / CTR 低 / 排名 8–30」的页面 + Keyword Planner 新词
每天:AI 起草 1 篇(promo-site prompt 链)→ 事实骨架取自后端引擎 / 查表 → 用户过目 → forbidden_words 校验 → 发布
发布当天:从 3 个相关高流量页加内链;提交 sitemap
第 3–4 天:看收录和排名;没起色就改 title / In short
```

内容红线(与 App 同口径,上线前逐页过):不写「准 / 灵验 / 预测」,不写「转运 / 改命 / 化解」;**禁止格局硬分类**,只写「命局呈现××倾向」;喜忌只引用后端规则的结论;术语译名只取 `backend/app/engine/term_translations.py`,站点术语表纳入 `tools/check_term_sync.py` 的校验范围;每页底部写「For entertainment and self-reflection only」。

## 9. 设计系统 Web 映射

| DESIGN.md(iOS) | Web token(`site.css`) | 备注 |
|---|---|---|
| paper / cardSurface / ink / inkMuted / inkMutedSecondary / inkDeep / onInkDeep | `--paper` `--paper-raised` `--ink` `--ink-muted` `--ink-muted-2` `--ink-deep` `--on-ink-deep` | 色值一致;暗色用夜宣纸,走 `prefers-color-scheme` + `[data-theme]` |
| cinnabar(仅印章级) | `--cinnabar` | Web 端只用于:印章、付费标、TOC 聚焦线、当前时辰点、今日日柱、CTA 里的菱形小点。**禁止用作 CTA 底色或大面积** |
| jade / daiBlue | `--jade` `--dai` | jade = 生 / 吉;dai 仅用于设计注释 |
| 五行色 | `--wood` … `--water` | 干支逐字着色,规则同 iOS 主页 hero |
| hairline / dashed | `--hairline` `--hairline-dashed` | 卡片让位于 hairline;虚线 = 锁定 |
| 宋体(QiSongti) | `--f-zh`(思源宋体子集) | 所有中文;zh-hant 页面换 `--f-zh-tc` |
| EN 衬线标题 + 无衬线正文 | `--f-serif` Newsreader / `--f-sans` 系统字体 | 遵守两族纪律;不用 Inter / Roboto |
| ink-in / stamp / breathe | `.ink-in` `.seal.is-stamping` `.breathe` + `.reveal` | 参数与 DESIGN.md 一致 |
| NumeralBadge | `.numeral`(实线 / `.locked` 虚线) | 壹–捌 |
| CTA radius 5 | `.btn` | 高度 48(主要 54) |

Web 字号阶梯(桌面 → 手机,用 clamp):Display 76→40 / H1 54→34 / H2 38→28 / H3 22 / 正文 18(文章)、17(界面)/ Caption 13.5 / LatinCaps 11(字距 .32em)。

## 10. 标志性交互参数

| 交互 | 实现 | 降级 |
|---|---|---|
| 时辰盘 | SVG 路径 `pathLength=1`,stroke-dashoffset 1→0,2.2s `cubic-bezier(.2,.6,.2,1)`;feTurbulence + feDisplacement 做出毛笔边;当前时辰 = `floor(((h+1)%24)/2)`,用**访客本地时间** | reduced-motion:直接显示完整墨圆 |
| 墨迹晕开 / 揭示 | `opacity 0→1 + blur 7→0`,1.2–1.4s;滚动揭示用 IntersectionObserver,只触发一次;**`.js` 前缀**保证无 JS 时内容可见 | 0.3s 纯淡入 |
| 落印 | scale 1.9→1 + 回弹,0.5s,进入视口 60% 时触发 | 静态 |
| 排盘晕墨 | 四柱按列延迟 0 / .3 / .6 / .9s 依次显现 | 同时显示 |
| 五行图 | 选中后相关的生线(墨青 2px)和克线(浓墨实线)高亮,其余淡到 14%,节点淡到 45% | 默认显示「木」的面板 |
| 术语释义卡 | 仅 `(hover: hover)` 设备;mouseenter / focus 显示,180ms 延迟隐藏;触屏直接跳转 | 普通链接 |
| 章节墨线 | 左栏 1.5px 线按 `scaleY(阅读进度)` 增长;当前章节左侧 2px 朱线 | 静态目录 |
| 甲子检索 | 不匹配的格子 `opacity .18 + blur 1.5px` | 不过滤 |

## 11. 给实现方的注意事项

- 建议目录:仓库内 `site/`(Astro),组件可按以下拆分:`Header` `Footer` `Enso` `Seal` `Numeral` `AnswerBox` `Facts` `Toc` `TermLink` `CtaInline` `CtaPanel` `StickyCta` `NotifyOrAppStore` `PillarsTable` `ElementBar` `LuckRow` `ShichenDial` `WuxingCycle` `JiaziGrid`
- `assets/site.css` 可以直接作为全局样式起点;页面内 `<style>` 改写成组件作用域样式
- 设计稿里的 Google Fonts、mock 算法、`.anno` 注释框、看板本身,都**不上线**
- 引入 Astro 已获同意(决策 5);**Newsreader 字体、Satori(OG 图)属于新依赖,按 CLAUDE.md 要先征得同意**
- zh-hant 版:同一模板换 `--f-zh-tc`、`lang="zh-Hant"`;中文页面的 H1 可以改成竖排题签 + 横排标题双写(竖排部分 `aria-hidden`,H1 文本保持横排)

## 12. 已拍板(2026-11-24)

| # | 问题 | 结论 | 设计稿上的落地 |
|---|---|---|---|
| 1 | 品牌名 vs 域名 | **网站和 App 之后都改名 KnowFate**;中文名 **观命**(繁 觀命),品牌印「观」(11-24 改名规划拍板) | 设计稿品牌字样已换成 KnowFate / KNOWFATE,品牌印「玄」→「观」;App 侧改名见 `docs/App改名KnowFate设计决策.md`;站点联动规则见 §13 |
| 2 | 英文标题字体 | **Newsreader**(已同意引入) | 上线时自托管 woff2 子集,只 preload 一个字重;Satori(OG 图生成)仍需单独征得同意 |
| 3 | 上线顺序 | **先上内容页**(维持决策 7) | 见下方「分期上线」 |
| 4 | 公开联系邮箱 | **域名邮箱 `hello@knowfate.app`** | Cloudflare Email Routing 转发到私人邮箱(私人邮箱不出现在任何页面);已写进全站页脚与首页 FAQ;隐私政策页同用此地址 |

### 分期上线(问题 3 的展开)

后端服务器还没采购,排盘器上线前**任何页面都不能出排盘结果**(客户端禁止历法计算)。所以第一期:

| 页面 / 组件 | 第一期(仅内容) | 第二期(后端就绪) |
|---|---|---|
| 首页 hero 表单 | 换成「Notify me when the calculator opens」邮箱表单 + 「Browse the library」次按钮;右侧时辰盘保留(纯本地时间,不涉及排盘) | 换回排盘表单 |
| `/en/bazi-calculator` | **第一期就上线**,让这个最重要的 URL 早点开始积累收录:保留 H1、答案段、方法论四格、FAQ;生辰帖换成虚线锁框 + 「Opening soon」+ 邮箱表单;没有结果区 | 打开完整工具 |
| 日主查询小工具(知识页右栏 / `/en/day-master-calculator`) | 隐藏右栏小工具,换成「附日主速查」:列出 10 个日主入口;独立页暂不上 | 接 `/api/public/chart` |
| 知识页 / Library / 指南 | 全部上线 | — |
| 「今日」条 / `/en/today` | 构建时由后端脚本离线生成静态数据(构建期调用,不在浏览器计算)。构建环境调不到引擎 → **构建失败**,不静默隐藏(CLAUDE.md 错误显式传播;11-25 修正此前「整块隐藏」的写法,与官网 S04 统一) | 正常 |
| App CTA | 「Notify me at launch」 | App 上架后切成 App Store 徽章 |

两期之间只是改配置开关(`features.calculator`、`cta.state`),模板不分叉。

## 13. App 改名联动(2026-11-25)

App 改名规划(`docs/App改名KnowFate设计决策.md`)拍板后,官网需要同步的规则。改名 S01 还差用户在 App Store Connect 实测两个中文名;若实测失败、中文名再变,本节随之修改。

### 品牌呈现

| 位置 | en 页面 | zh-hant 页面 |
|---|---|---|
| 页头品牌字 | 墨圆小标 + `KNOWFATE` 字距标 | 墨圆小标 +「觀命」(宋体)+ 小号 `KNOWFATE` |
| 品牌印(页脚、首页时辰盘、OG 卡) | 「观」 | 「觀」 |
| `<title>` 后缀 | `\| KnowFate` | `\| 觀命 KnowFate` |
| 页脚版权 | © 2026 KnowFate | © 2026 觀命 KnowFate |
| 功能印 | 「解」「批」「木」等不变 | 繁体字形(「批」「解」同形) |

- 简体中文站(以后再做)用「观命」「观」
- 字体:「觀」在繁体子集(Big5)内;「观」在简体子集(GBK)内。站点字体子集脚本(官网 S01)的字表要包含这两个字

### App Store 相关

- App Store 英文名:**KnowFate - Chinese Astrology**(已在 App Store Connect 保存)。`/en/app` 页、`MobileApplication` 结构化数据、App Store 徽章的 `aria-label` 用这个全称
- **隐私政策页与技术支持页是 App 提交审核的前置条件**:App Store Connect 要求填写隐私政策网址和技术支持网址,二者都指向本站(`/en/privacy`、`/en/support`)。所以这两页必须在 App 首次提交前上线,哪怕其余页面还没准备好(官网 S05、S08 已据此调整)
- 隐私政策只有一份正文(本站页面),App 内和 App Store 都链接它,不另写副本

### 已拍板:「Chinese astrology」关键词方向(2026-11-25)

App 英文名带上了「Chinese Astrology」,官网据此调整,但**首批 BaZi 布局不变**(长尾词仍是起步阶段最容易拿到排名的地方):

1. **新增入口指南** `/en/guides/chinese-astrology-and-bazi`,放进**第一批**:讲清 Chinese astrology 的几个体系、生肖和八字的关系,把搜「chinese astrology」的人引向生肖总览和排盘器。首页「What is BaZi?」区块和 `/en/app` 页链接它
2. **生肖页从第三批提前到第二批**:12 个生肖页(地支与生肖合一,不再单建地支页)+ 当年和次年的生肖年份页(2026 马年、2027 羊年),每年滚动新增
3. 生肖内容的差异化:**按立春换年**(与 App 和排盘引擎一致),并解释它和按春节算的区别
4. 不做:生肖每日 / 每月运势、「犯太岁」「化解」类内容(违反内容红线)
