# KnowFate 官网(knowfate.app)— 实施分割索引

Parent 设计事实源:
- `docs/design-ref/website/README.md` — **实现规格**(IA / URL / 模板区块 / 内链 / 技术 SEO / CTA / 交互参数 / §12 已拍板)
- `docs/design-ref/website/*.html` + `assets/site.css` — **高保真视觉稿**(像素与交互以此为准;用浏览器打开 `index.html` 看总览)
- `docs/SEO站设计决策.md` — 11-02 拍板 8 项 + 11-24 增补(品牌 KnowFate / Newsreader / 先上内容页 / hello@knowfate.app)
- `docs/App改名KnowFate设计决策.md` — App 改名(中文名观命 / 繁 觀命、品牌印「观」、英文商店名 KnowFate - Chinese Astrology);官网联动规则见 `design-ref/website/README.md` §13
- `DESIGN.md` — 水墨孤本视觉系统(任何视觉偏离须用户批准)
- `CLAUDE.md` — 全局约束(commit 三段式 / 错误显式传播 / 不擅自加依赖 / 术语与 LLM 边界)

本目录为 2026-11-24 分割产物:12 个 vertical slice,分两期。**一期 = 不依赖生产后端,可以立即开工并上线;二期 = 等后端部署(`docs/后端部署设计决策.md` S4)后接入排盘。**

## 开工前必读(给实现方 AI)

1. 按顺序读:本 README → `docs/design-ref/website/README.md` → 在浏览器打开 `docs/design-ref/website/index.html` 及四个页面 → 你要做的那份 slice 文档
2. **一次只做一个 slice**,做完对照该 slice 的验收标准逐条自检,并写交付报告(做了什么、验收结果、偏离与原因、遗留问题),再开下一个
3. 标 **HITL** 的 slice 或步骤需要用户本人操作或拍板:做到那一步就停下,列出需要用户做的事,**不要替用户决定**
4. 遇到设计稿和规格冲突:以 `design-ref/website/README.md` 为准;规格没写到的视觉细节以 HTML 稿为准;两边都没写的停下来问
5. 设计稿里的蓝色虚线注释框(`.anno`)、Google Fonts 外链、`site.js` 里的儒略日 mock 算法、看板页 `index.html` **都不上线**

## 实施顺序

| Slice | 标题 | 期 | 类型 | Blocked by | 一句话 |
|---|---|---|---|---|---|
| S01 | [站点骨架 + 设计 token + 基础组件](S01-站点骨架与设计token.md) | 一 | AFK | 无 | `site/` 建 Astro 项目,搬 token,做 BaseHead / Header / Footer / 品牌指纹组件,自托管字体,`/en` `/zh-hant` 路由;一张空白示例页通过「关 JS 可读」+ Lighthouse |
| S02 | [内容模型 + 术语单一事实源 + 内容校验脚本](S02-内容模型与术语校验.md) | 一 | AFK | S01 | content collections schema;从 backend 导出术语 JSON;`tools/check_site_content.py`(禁用词 / 术语 / frontmatter / 内链数) |
| S03 | [知识页模板 + 甲木样张](S03-知识页模板与甲木样张.md) | 一 | AFK | S02 | `ArticleLayout` 全套(答案框 / 速查表 / 章节轨 / 三处 CTA / 释义卡 / JSON-LD / 相邻导航);样张 `/en/day-master/jia-wood` 与 `article.html` 视觉一致 |
| S04 | [首页 + Library + 交互组件](S04-首页与Library.md) | 一 | AFK | S03 | 时辰盘 / 五行生克图 / 十日主矩阵 / 六十甲子矩阵 / Library 检索;首页按一期状态(表单 → 邮箱) |
| S05 | [一期排盘器页 + 转化与站务页](S05-一期排盘器页与站务页.md) | 一 | AFK(含 HITL 步骤) | S03 | `/en/bazi-calculator` 一期版(锁框 +「Opening soon」+ 方法论 + FAQ);CTA 两态开关;Buttondown;`/en/app` `/en/about` `/en/privacy` |
| S06 | [SEO 基础设施](S06-SEO基础设施.md) | 一 | AFK(含 HITL 步骤) | S03 | sitemap 分片 / robots / hreflang 校验 / llms.txt / OG 图 / TelemetryDeck / 404 |
| S07 | [首批内容 ~40 页](S07-首批内容生产.md) | 一 | **HITL** | S02、S03 | 10 日主 + 10 十神 + 5 五行 + 6–8 神煞 + 3–5 指南;**每页用户过目后才发布** |
| S08 | [一期上线](S08-一期上线.md) | 一 | **HITL** | S04–S07 | Cloudflare Pages + knowfate.app 根域 + Email Routing + Search Console;上线验收清单 |
| S09 | [后端公开排盘端点 `/api/public/chart`](S09-后端公开排盘端点.md) | 二 | AFK | **无(可与一期并行开发)** | 复用排盘核心,不签 token、不碰 LLM、IP 限流、CORS 白名单、字段裁剪;pytest |
| S10 | [排盘器完整版 + 日主查询](S10-排盘器完整版.md) | 二 | AFK | S09 + 后端已部署 | 生辰帖 + 结果区全套 + 晕墨动效 + 首页表单切回 + 右栏日主查询;`features.calculator=on` |
| S11 | [程序化二批:今日 / 60 日柱 / 日主×月令 / 配对 / 生肖](S11-程序化二批.md) | 二 | AFK + HITL 抽审 | S09、S07 | 构建期从引擎导出数据生成 ~255 页(含 12 生肖 + 生肖年份页);用户抽审 10% |
| S12 | [增长运营手册](S12-增长运营手册.md) | 二 | HITL(持续) | S08 | GSC 周报 → 改 title/meta → 每日一篇 → 新页内链导流;写成可重复执行的 runbook |

关键路径:S01 → S02 → S03 → (S04 ∥ S05 ∥ S06 ∥ S07) → S08。S09 可以从第一天就并行做。

**与 App 上架的硬依赖**:App Store 提交审核必须填隐私政策网址和技术支持网址,两者都在本站。若 App 准备提交时官网还没整体上线,就按 S08「最小上线」先把 `/en/privacy`、`/en/support`(含繁中版)部署到 knowfate.app。

## 依赖批准状态(CLAUDE.md「不擅自加依赖」)

| 依赖 | 状态 | 依据 |
|---|---|---|
| Astro + 官方 `@astrojs/sitemap` | ✅ 已同意 | SEO站设计决策 #5 |
| Newsreader 字体(自托管) | ✅ 已同意 | 11-24 增补 |
| 思源宋体(复用 `ios/.../QiSongti*.otf` 做 Web 子集,`fontTools` 已是 `tools/build_songti_fonts.py` 的依赖) | ✅ 无新依赖 | — |
| Buttondown 嵌入表单(纯 HTML POST,无 JS 库) | ✅ 已同意 | 决策 #8 |
| TelemetryDeck Web SDK | ⚠️ 决策文档「默认取舍」写了,**实施前跟用户确认一次** | SEO站设计决策「默认取舍」 |
| Satori / `@vercel/og`(OG 图生成) | ❌ **待批准** | 未批准前 S06 走降级方案 |
| `brotli`(Python,生成 woff2 用) | ✅ **已批准(2026-11-25,用户口头批准,见 build_site_fonts.py 注释)** | 依赖装在 backend venv(fontTools ≥4.39 + brotli) |
| 其他一切(UI 框架 / CSS 框架 / 动画库 / MDX / 搜索库 / 分析库) | ❌ 不要加 | 交互全部手写原生 JS(设计稿已经证明够用) |

## 全系列红线(每个 slice 都适用)

- **网页端零 LLM 调用**;**浏览器端零历法计算**:所有干支 / 节气 / 大运 / 神煞数据要么来自构建期运行后端引擎导出的静态数据,要么来自 `/api/public/chart`。`site.js` 里的儒略日算法禁止进入生产
- **关闭 JS 时完整可读**:内容在静态 HTML 里;动效用 `.js` 前缀类控制初始隐藏(参考 `site.css` §16)。每个 slice 的验收都包含这一条
- **术语译名单一事实源**:en / zh-hant 术语只取 `backend/app/engine/term_translations.py`,站点不另起译名;站点术语数据纳入 `tools/check_term_sync.py` 校验
- **内容红线**:不写「准 / 灵验 / 预测 / 转运 / 改命 / 化解」;禁止格局硬分类(正官格、偏印格等),只写「命局呈现××倾向」;喜忌只引用后端规则结论,从格写「Special pattern · left open」不猜;每页底部免责
- **个人数据不成页**:带出生参数的 URL 一律 `noindex,follow` + canonical 到干净 URL;结果不落任何存储
- **朱红只做印章级**:印章 / 付费标 / TOC 聚焦线 / 当前时辰点 / 今日日柱 / CTA 内菱形小点。禁止 CTA 底色和大面积
- **品牌**:en 页面 KnowFate / KNOWFATE + 品牌印「观」;zh-hant 页面「觀命」+ 品牌印「觀」(规则见规格 README §13)。站内不再出现「玄机问道」「QiCompass」和「玄」字品牌印
- **错误显式传播**:构建期数据导出失败、术语缺失、内容校验不过 → 构建失败退出,不要用默认值兜底
- **commit 三段式**(Why / What / Impact),每个 slice 至少一个独立 commit

## 不做(勿在本系列实现)

网页端 AI 解读 / 网页支付或订阅 / 用户账号 / 评论区 / 简体中文站(以后再做)/ 百度 SEO / 星座、塔罗、紫微等非八字内容 / 名人命盘(真实人物不写)/ 自动批量发布(每日一篇、人工过目)。
