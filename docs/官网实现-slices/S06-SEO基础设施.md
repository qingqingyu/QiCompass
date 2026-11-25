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

- [ ] `python3 tools/check_site_seo.py` 对构建产物 PASS;故意制造重复 title → FAIL
- [ ] sitemap 能被 Search Console 的「测试」解析(上线后在 S08 验证;本地先用 XML schema 校验)
- [ ] 每页都有 og:image,尺寸 1200×630
- [ ] robots.txt、llms.txt、404 页上线可访问
