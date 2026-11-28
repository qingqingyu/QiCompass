# S06 SEO 基础设施

- **类型**: AFK,含 HITL 步骤(Satori 批准、TelemetryDeck 确认)
- **Blocked by**: S03
- **覆盖规格**: `design-ref/website/README.md` §3(规范化规则)、§6
- **Parent**: `docs/官网实现-slices/README.md`

## What to build

1. **sitemap**:`@astrojs/sitemap`(已批准),按类型分片(`sitemap-day-master.xml`、`sitemap-ten-gods.xml`…)+ `sitemap-index.xml`;`lastmod` 取 frontmatter `updated`;排除 `noindex` 页、示例页、未发布页;每条带 hreflang alternates
2. **robots.txt**:允许全部;`Disallow: /*?d=`、`/*?t=`、`/*?c=`(出生参数);写 sitemap 地址
3. **noindex 规则**:任何带出生参数的 URL 输出 `noindex,follow` + canonical 到干净 URL(二期排盘器用,一期先把机制做好)
4. **重定向**(`site/public/_redirects`):`/` → `/en/`;配对页 `b-and-a` → `a-and-b`(规则生成,二期才有页面,一期先写好生成逻辑);旧路径占位
5. **结构化数据品牌字段**:全站 `Organization` 的 `name` = KnowFate、`alternateName` = ["觀命", "观命"];App 上架后 `MobileApplication.name` = 「KnowFate - Chinese Astrology」
6. **`llms.txt`**:站点简介 + 方法说明(确定性规则、不预测、术语中英)+ 各类型总览链接
7. **OG 图**:设计稿 `index.html` 里的 1200×630 模板(左标题 / 右墨圆大字 / 底部朱印 + KNOWFATE.APP;朱印 en「观」/ zh-hant「觀」)
   - **Satori 未获批准前的降级方案**:为每个**页面类型**手工做一张静态 OG 图(用设计稿模板在本地 Playwright 截图生成 PNG,脚本放 `tools/`,产物进 `site/public/og/`),每页按类型引用
   - 获批后:构建期每页生成专属 OG 图
8. **TelemetryDeck**:**先向用户确认**(见 README 依赖表);确认后接入 Web SDK,无 cookie;记录事件:CTA 点击(带 slot)、邮箱提交、排盘提交(二期)
9. **404 页**:水墨风格,给出 Library / 首页 / 排盘器入口
10. **校验脚本** `tools/check_site_seo.py`(跑在构建产物 `site/dist/` 上):每页 title 唯一且 ≤60 字符、description 140–160、canonical 唯一、hreflang 互指闭合、JSON-LD 可解析、无 `noindex` 页出现在 sitemap、内链无 404

## HITL 步骤

- 询问用户是否批准 Satori(说明:理由 / 替代方案 = 按类型静态图 / 不引入的代价 = 分享卡千篇一律)
- 询问用户确认 TelemetryDeck Web SDK

## Acceptance criteria

- [x] `python3 tools/check_site_seo.py` 对构建产物 PASS;故意制造重复 title → FAIL(2026-11-28 实测:dist 里把 support 的 title 换成 about 的 → `FAIL: en/support.html: title 与 en/about.html 重复`,exit 1;重建恢复)
- [x] sitemap 能被 Search Console 的「测试」解析(上线后在 S08 验证;本地已用 `xml.etree` 解析 index + 全部 shard 校验 well-formed + 与 indexable 页互为镜像)
- [x] 每页都有 og:image,尺寸 1200×630(checker 读 PNG IHDR 逐页校验;14/14 过)
- [x] robots.txt、llms.txt、404 页在构建产物中(checker 校验在位;上线可访问归 S08 部署验收)

## 实施记录(2026-11-28)

全部落地,`tools/check_site_seo.py` PASS(14 indexable 页 / 14 sitemap URL / 2 shard)。与规格的偏离及理由:

1. **sitemap 未用 `@astrojs/sitemap`,改自研 `site/scripts/gen-sitemap.mjs`**(构建后扫 dist)。理由:README §6 要求**按类型命名分片**(`sitemap-day-master.xml` 等),`@astrojs/sitemap` 只按页数均分、给不出类型名 shard;自研脚本零新依赖(stdlib 读产物),canonical / hreflang / noindex / lastmod 全部以页面产物为单一事实源。虽属「少加依赖」方向,仍在此记录偏离(该依赖此前的批准见 slice README 依赖表)
2. **OG 图走降级方案**(2026-11-28 用户拍板:Satori 不引入,按页面类型静态图):`tools/build_site_og.py` 用设计稿同款版式生成 5 类型 × 2 语言共 10 张 PNG(`site/public/og/`),Chrome `--headless=new --screenshot` 直出(**未加 Playwright 依赖**,直接调本机 Chrome 二进制)。OG 专用字(盘盤书書 + zh-hant 文案字)经 `og_image_chars()` 并入 `tools/build_site_fonts.py` 硬性字集(单一事实源:字体脚本 import OG 脚本)。视觉抽检 2 张(home-en / calculator-zh-hant):宋体/enso 毛边/朱印/无 tofu 达标
3. **TelemetryDeck 已接入**(2026-11-28 用户拍板):Web SDK 由 `BaseHead` 按 `config.mjs telemetry.appId` 非空条件加载(appId 空 = 完全不加载,当前即此态);页面浏览 SDK 自动上报;`enhance.ts` 补 `ctaClick`(带 slot/to)与 `notifySubmit`(带 source)两类事件,SDK 缺席时静默不发。隐私页 en/zh-hant 已加「无 Cookie 网站统计」披露
4. **description 长度带按语言分**:`check_site_seo.py` 与 S02 `check_site_content.py` 同口径(en 140–160 / zh-hant 60–90,CJK SERP 截断更早);本轮为过检收紧了 8 页文案(en about/app/bazi-calculator/library、zh-hant home/library/privacy/support)+ 2 页 title 压到 ≤60
5. noindex 机制:带出生参数 URL(`?d=`/`?t=`/`?c=`)→ `noindex,follow` + canonical 指干净 URL,`BaseHead` 内联脚本实现,一期页面即生效(二期排盘器复用)
6. pair 归一重定向:`site/scripts/gen-pair-redirects.mjs` 按 `STEM_ORDER` 生成 `b-and-a → a-and-b` 301 规则段;当前无 compatibility 页(0 条规则),S11 有页面后自动生效
7. 结构化数据:`Base.astro` 输出 `Organization`(`alternateName` 观命/觀命)+ 各页 `WebSite`/`BreadcrumbList`/`FAQPage` 的 JSON-LD `@graph`;`MobileApplication` 待上架后(S08)再开

8. **双轮 review 修复批(2026-11-28,设计 8 项 + 红队/Codex 对抗)**:
   - OG en 标题缩短(`KnowFate Library`/`BaZi Calculator`,去 The/Free)防长题折行撞副题;`build_site_og.py` 渲染期加**排版探针**(`--dump-dom` 量 `.title` 行数与副题间距,折行≠1 或间距 <12px 直接抛,不靠肉眼);过期判定改 `og/manifest.json` 三向哈希(script/两 woff2/十 png,git 不保 mtime);`--check` 加 woff2 cmap 覆盖兜底(fontTools 惰性导入,已有依赖)
   - `check_site_seo.py` 补四查:hreflang **语言映射**错位(闭合不保证对位,en 页 hreflang-en 错指 zh-hant 腿此前照过)、og:image **语言腿**(en 页引 zh-hant 图照过)、**OG 枚举双源**(site.ts `OG_TYPES` ↔ build_site_og `OG_PAGES` 键集 + dist/og 全积)、相对路径**内链解析**(此前直接跳过 = 盲区);png_size 单源自 build_site_og 导入;支持 `--dist`(负向夹具)
   - `gen-pair-redirects.mjs` 重写:正序页也产出 `b-and-a → a-and-b` 反序 301(旧实现只有反序文件存在才出规则,用户访问反序 URL 直接 404);未知天干(terms.json 有、`STEM_ORDER` 无)抛错退出不静默
   - noindex 内联脚本改 `URLSearchParams`(原 regex 漏百分号编码键 `%64=`);`Base.astro` @graph JSON.stringify 后 `<` 转义 `<`(注入面收口);robots.txt 补 `&d=/&t=/&c=` 非首参位;`site/package.json` build 链尾挂 `check_site_seo.py`(绕过 = build 绿但 SEO 漂)
   - 新增 `site/tests/test_s06.py`(10 用例:checker 正/负向×5、pair 反序规则、未知天干抛错、枚举漂移、复原回绿;源文件变更 finally 回写,dist 变更全在临时副本。双 review 循环第 1 轮补 2e:根级首页 `en.html` 语言腿错挂——4b 映射检查原只认 `en/` 前缀,首页两页是盲区,闭合检查抓不住腿互换)
9. **两个坑(修复过程中实测)**:① og 语言腿提取不能用 `rsplit("-")`——`zh-hant` 自带连字符会拆出 `hant`,真实 dist 上 7 张 zh-hant 页全误报,须尾缀匹配(`endswith("-zh-hant")` 先于 `endswith("-en")`);② 共享组件中文**注释**的字进 TC 硬性集(源码扫描口径),review 批新注释的「逃逸/百分号」3 字逼一次字体重建,连带 OG manifest 字体哈希漂移 → 须按 fonts → og 重渲染 → --check 全序重跑(CLAUDE.md 已加守护栏条目)

**遗留(HITL)**:
- TelemetryDeck 注册拿 appId 填 `config.mjs`,并在真机核验全局名 `TelemetryDeck.signal` 是否真的到达(代码已双名兼容 `TelemetryDeck` / `td`);**填 appId 时一并拍板**:SDK 加 SRI 或自托管(review 提出 cdn.telemetrydeck.com 无 SRI)+ `sendBeacon` unload 存活核验
- Search Console sitemap 测试(S08 上线后)
- OG 图用户亲自过目 10 张(生成器探针已锁排版;本轮重渲后 2 张原缺陷图 library-en/calculator-en 已复核:单行标题 + 净间距)
- `ct` 归因参数(live 态 CTA 落点)归二期排盘器
