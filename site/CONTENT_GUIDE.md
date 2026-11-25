# KnowFate 官网内容写作指南(S02)

给写内容的人(或 AI)看。事实源:`docs/design-ref/website/README.md`(规格)、
`docs/SEO站设计决策.md`(拍板)、backend 引擎与《三命通会》查表。本指南是它们的写作层落地。

## 守护栏(每次动内容必跑,不过不算完成;全部从仓库根跑)

```bash
python3 tools/check_site_content.py            # 内容校验(禁词/长度/frontmatter/内链)
cd site && npm run build                        # schema 校验(reviewedBy 缺审 = 构建失败;
                                                # prebuild 自动失效渲染缓存,见下)
python3 tools/check_site_content.py --dir site/tests/fixtures/content   # fixtures 回归
```

动 `backend/app/engine/term_translations.py` 或 `site/src/data/terms.json` 另须跑:

```bash
arch -arm64 backend/.venv/bin/python tools/check_term_sync.py
```

**渲染缓存陷阱**:Astro content layer 把条目渲染结果缓存在 `node_modules/.astro/`,
失效判据只有内容文件 digest——**插件 / terms.json / term-defs.json / astro.config.mjs
的变更不会触发重渲染**,build 照样全绿但 dist 静默复用旧 HTML。`npm run build` 的
prebuild 钩子(`site/scripts/invalidate-render-cache.mjs`)会对这组文件取指纹自动
失效,所以**永远用 `npm run build`,不要绕过 npm 直接调 astro build**。

## 文件布局与 frontmatter

- 路径:`site/src/content/{collection}/{lang}/{slug}.md`,collection ∈
  `day-master / ten-gods / five-elements / stars / guides / zodiac / zodiac-year`;lang ∈ `en / zh-hant`。
- `slug` = 文件名 = URL 末段(小写字母数字连字符);`lang` 必须与目录段一致。
- 必填:`title`(≤60 字符)、`description`(140–160 字符,一句完整回答,主词放最前)、
  `inShort`(答案框定义句:en ≤60 词 / 中文 ≤120 字)、`updated`("YYYY-MM-DD" **带引号**,
  不带引号会被 YAML 解析成 date 对象导致构建失败)、`faq`(2–4 条)、`slug`、`lang`。
- `published: true` 必须有 `reviewedBy: {date, reviewer}` —— 缺审构建直接失败。
  S07 的流程:AI 起草 → `published: false` 入库 → 用户过目 → 填 reviewedBy + 开 published。
- 类型字段见 `site/src/content.config.ts` 注释。**禁手填**:`zodiac` 的 `friends/clash`
  (构建期从后端 branch_relations.py 导出)、`zodiac-year` 的 `startsAt/endsAt`(引擎导出立春时刻)。
- **日期一律带引号**;字符串值建议全部加引号。

## H2 章节约定

正文用 `## {中文数字}|{标题}` 形式,模板拆分后渲染大写数字编号:

```markdown
## 壹|描述什么
## 贰|按出生季节
```

编号壹–捌连续;不用 frontmatter sections 数组(以正文为单一事实源)。

## 语气与句式

- 专业不忽悠。描述**倾向**,不下结论:「传统上认为……」「命局呈现××倾向」「较易/较难」。
- 每页以 `inShort` 定义句开头(争取精选摘要/AI 概览引用)。
- 从格/专旺诚实降级:写 "Special pattern — preferences left open",**不猜喜忌**。
- 生肖措辞沿用 App 口径:「好朋友 / 需磨合」;不用「不和谐 / 相克 / 犯太岁化解」。

## H2 骨架(抄规格 README §4.3,保证每页独有内容)

| 类型 | H2 骨架 |
|---|---|
| 日主 | 描述什么 / 长短 / 按出生季节 / 旺与弱 / 与其他九日主 / 工作学习 / 在自己盘里怎么看 / FAQ |
| 十神 | 是什么关系 / 透干与藏干的区别 / 过多与缺失 / 在各柱的含义 / 与其他十神的组合 / FAQ |
| 五行 | 象与性 / 过多 / 缺失 / 生克关系 / 季节 / FAQ |
| 神煞 | 查法(按日干或年支查表)/ 在各柱 / 常见误读 / FAQ |
| 日柱 | 干支与纳音 / 自坐十神与长生 / 近期日期(未来 12 个同柱日)/ FAQ(名人不写) |
| 配对 | 十神关系 / 天干合冲 / 只看日主的局限 / 用合盘真正看什么 → App 合盘 |
| 生肖 | 地支与五行 / 性格倾向 / 好朋友与需磨合 / 生肖年份列表 / 生肖按立春换年,不按春节 / 生肖只是八字的一个字 → 排盘器 |
| 生肖年份 | 该年年柱干支与纳音 / 起止时间(立春到次年立春)/ 与各生肖的关系 / 本命年说明 / FAQ |
| 入口指南 | Chinese astrology 有哪些体系 / 生肖只是年柱一个字 / 什么时候看生肖、什么时候要排盘 |

## 内链规则(校验强制)

- 每页正文站内链接 **≥ 8 条**,全部指向存在的路由(死链 FAIL;固定路由表在
  `tools/check_site_content.py` 的 `KNOWN_STATIC_ROUTES`,与 Header/Footer 同步)。
- 术语自动内链:`src/plugins/remark-term-links.mjs` 会把正文里
  **十神 / 神煞 / 五行(en 页)** 与 **十神 / 神煞(zh-hant 页)** 术语的首次出现
  包成术语链接(标题、已有链接、代码、本页自身除外)。
  干支单字不自动链:en 里 "Wu" 同时是 戊(天干)与 午(地支),裸拼音必误链;
  zh 里五行单字必然误切复合词(甲木/木火通明)。日主 / 地支 / 纳音 / 长生的链接
  由正文手写(描述性锚文本,如 "Jia Wood Day Master",不用 "click here")。
- 术语释义卡:`src/data/term-defs.json`(术语键 → 一句英文定义)。写新页时给
  新出现的术语补 def;只写「是什么」,不写判断。
- 手写链接指向术语页 = 消耗该术语的首次出现(同术语本页只链一次)。

## 事实来源与禁止事项

- 事实骨架**只能**来自:后端引擎输出、《三命通会》查表(神煞)、`terms.json` 术语。
  不自造数据;拿不准就留 open,不猜。
- 禁词(校验强制 FAIL):「准 / 灵验 / 预测 / 转运 / 改命 / 化解」家族(backend
  `forbidden_words`)+ 英文 accurate / predict(ion) / guarantee / lucky charm /
  cure / remedy / change your fate + 格局硬分类(「正官格 / 偏印格 / ……格」;
  英文 "{十神} structure" 结论式)。**从格 / 专旺不禁**(App 诚实降级概念)。
- 名人不写(真实人物命盘);个人出生数据不入内容页。
- 每页底部免责由模板统一渲染(「仅供娱乐与自我认知参考」),正文不用重复写。
