# SEO 站设计决策(2026-11-02)

Status: 拍板 8 项(下表);域名可用性待用户自查;实现未开始
关联:`docs/上架清单拍板-2026-10-28.md` / `docs/后端部署设计决策.md`(D4 域名)/ `tmp/app-store-launch/privacy-policy.md`(隐私政策正文草稿)/ `tmp/social-seeding/`(社媒渠道,与 SEO 互补)

## 拍板结论

| # | 决策点 | 拍板 | 要点 |
|---|---|---|---|
| 1 | 定位 | **内容站 + 免费排盘工具** | 知识页 + 排盘器;排盘只出确定性结果,**不烧 LLM**;要 AI 解读 → 引导下载 App;不在网页卖东西,不分流 IAP |
| 2 | 语言 / 市场 | **英文优先 + 繁中** | 主战场 Google;不做百度(App 不上大陆);简中后加 |
| 3 | 内容生产 | **AI 起草 + 人工校对** | 事实骨架取自后端引擎与《三命通会》查表,promo-site prompt 链起草,逐页用户过目后发;首批 30-50 核心页,再逐步扩 |
| 4 | 排盘计算 | **调后端公开只读端点** | 新增 `/api/public/chart`:不签发 context_token、不碰 LLM、按 IP 限流、CORS 仅放行站点域名;保证与 App 同盘(守 CLAUDE.md「所有排盘走后端」) |
| 5 | 技术栈 / 托管 | **Astro + Cloudflare Pages** | 新依赖已同意;静态 HTML 输出、i18n 路由、sitemap;隐私政策改放本站(**替代** 10-28 第 6 项的 GitHub Pages) |
| 6 | 域名 | **品牌域名** | 优先 `qicompass.com`,次选 `.app` / `.co`;站点放主域、API 用 `api.` 子域,一并解决部署 D4。可用性待用户自查(本环境网络策略拦截 RDAP/whois) |
| 7 | 上线时机 | **先上内容页,CTA 先收邮箱** | 尽早开始收录积累;CTA「上架通知我」,App 上架后换 App Store 链接;排盘器等后端部署完成后再开 |
| 8 | 收邮箱 | **Buttondown** | 嵌入表单、无 JS 依赖、双重确认;须写进隐私政策 |

## 默认取舍(未单独拍板,按惯例定;有异议再改)

- **代码位置**:本仓库 `site/` 目录(monorepo)——术语表与 backend `term_translations.py` / iOS `BaziTerms.swift` 同仓,便于复用与校验
- **术语一致性**:站点 en / zh-hant 术语必须取自 `backend/app/engine/term_translations.py`,不另起译名;新增站点术语表时纳入 `tools/check_term_sync.py` 校验范围
- **URL 结构**:`/{lang}/{type}/{slug}`,如 `/en/day-master/jia-wood`、`/zh-hant/day-master/jia-wood`;每页 hreflang 互指 + x-default 指向 en
- **结构化数据**:知识页 `Article` + `BreadcrumbList`;首页 `MobileApplication`(App 上架后)
- **分析**:与 App 一致用 TelemetryDeck 的 Web SDK(不加 Google Analytics,保持隐私口径一致;无 cookie 横幅)
- **视觉**:遵循 `DESIGN.md` 水墨孤本(色板 / 宋体 / 朱印规则),Web 端字体用思源宋体子集 woff2

## 首批页面(30-50 页,建议)

| 类型 | 数量 | 目标搜索词(en 示例) |
|---|---|---|
| 首页 + 排盘器入口 | 1 | bazi calculator, four pillars of destiny calculator |
| 十日主 | 10 | jia wood day master, yi wood personality |
| 十神 | 10 | ten gods bazi, eating god meaning |
| 五行 | 5 | five elements bazi, too much fire bazi |
| 神煞(高搜索量者先) | 5-8 | nobleman star bazi, peach blossom bazi |
| 指南 | 3-5 | how to read a bazi chart, unknown birth time bazi |
| 隐私政策 / 关于 | 2 | — |

第二批:60 甲子日柱、其余神煞、生肖 × 年份。

## 内容红线(与 App 同口径)

- 不承诺「准 / 灵验 / 预测」,不用「转运 / 改命 / 化解」
- **禁止**格局硬分类(正官格 / 偏印格等),用「命局呈现××倾向」
- 喜忌只引用后端确定性规则的结论,不让 LLM 自行推断
- 每页过 backend `forbidden_words` 校验后再发
- 每页底部「内容仅供娱乐与自我认知参考」

## 依赖的前置

- 排盘器:后端生产部署(D1-D5)+ 公开端点实现
- 隐私政策页:公开联系邮箱(用户待提供)
- App Store CTA:App 上架
