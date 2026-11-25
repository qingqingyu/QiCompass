# S01 站点骨架 + 设计 token + 基础组件

- **类型**: AFK
- **Blocked by**: 无 — 可立即开始
- **覆盖规格**: `design-ref/website/README.md` §6(技术 SEO 基础 / 性能预算 / 字体)、§9(设计系统 Web 映射)、§11(组件拆分)
- **Parent**: `docs/官网实现-slices/README.md`

## What to build

1. **`site/` 目录建 Astro 项目**(静态输出 `output: 'static'`,`trailingSlash: 'never'`,`build.format: 'file'` 或 `'directory'` 二选一,确保最终 URL 无尾斜杠且与规格 §3 一致)
2. **i18n 路由**:`/en/...` 与 `/zh-hant/...`;根路径 `/` 302 到 `/en/`(Cloudflare `_redirects`,不要用 JS 跳转);默认语言 en
3. **全局样式**:把 `docs/design-ref/website/assets/site.css` 搬为 `site/src/styles/global.css`。token(§1)原样保留;删掉 `.anno` 相关样式;字体变量改成自托管字体名
4. **自托管字体**(删掉 Google Fonts 外链):
   - 英文标题:Newsreader(OFL),只取用到的字重(300 / 400,含 italic 300),Latin 子集,woff2(若 `brotli` 未获批准则输出 woff)
   - 中文:从 `ios/QiCompass/QiCompass/Resources/QiSongti-Regular.otf`(简)与 `QiSongtiTC-Regular.otf`(繁)用 `fontTools.subset` 做 **Web 子集**。字表 = 站点全部内容 + 术语表实际用到的汉字 + 品牌字「观」「觀」「命」(构建脚本扫描 `site/src/**` 与导出的术语 JSON 生成),脚本放 `tools/build_site_fonts.py`,风格对齐 `tools/build_songti_fonts.py`(确定性产出、`--verify` 模式)
   - `font-display: swap`;只 `<link rel=preload>` Newsreader 400 一个文件
5. **基础组件**(`site/src/components/`):`BaseHead`(title / description / canonical / hreflang 三条 / OG / Twitter / theme-color / JSON-LD 插槽;title 后缀按语言:en `| KnowFate`、zh-hant `| 觀命 KnowFate`)、`Header`(含移动端菜单、语言切换、当前页朱点;品牌字按语言:en `KNOWFATE`、zh-hant「觀命」+ 小号 `KNOWFATE`,见规格 README §13)、`Footer`(全站内链枢纽,内容与设计稿一致,链接列表从数据生成)、`Enso`(SVG,带 draw 动画开关)、`Seal`(朱印,stamp 动画;品牌印默认字按语言取 en「观」/ zh-hant「觀」)、`Numeral`(壹–捌,实线 / 虚线)、`Brush`、`Kicker`
6. **增强脚本**:把 `site.js` 中通用部分(header 滚动线、菜单、reveal、seal stamp)改写成一个小模块 `site/src/scripts/enhance.ts`,`<script>` 由 Astro 打包;页面专属交互放到后续 slice
7. **一张示例页** `/en/_kitchen-sink`(构建产物里 `noindex`,不进 sitemap):展示所有基础组件、色板、字号阶梯、亮暗两种主题,用来做视觉回归

## Acceptance criteria

- [ ] `cd site && npm run build` 产出纯静态 HTML;`npm run dev` 能本地预览
- [ ] 示例页与设计稿 `index.html` 色板 / 字体 / 组件**视觉一致**(Playwright 截图对比,1440 与 390 两种宽度,附在交付报告里)
- [ ] 产物里没有 `fonts.googleapis.com` / `fonts.gstatic.com` 引用
- [ ] **关闭 JS** 打开示例页:所有文字可见(Playwright `javaScriptEnabled:false` 检查无 opacity<0.5 的文本节点)
- [ ] `prefers-color-scheme: dark` 下呈现夜宣纸;`prefers-reduced-motion` 下无 blur / 描边动画
- [ ] 390px 宽无横向滚动(`scrollWidth === 390`)
- [ ] Lighthouse(移动端)示例页:Performance ≥ 95,Accessibility ≥ 95,SEO = 100
- [ ] `python3 tools/build_site_fonts.py --verify` PASS;中文子集文件 < 400KB(超了在报告里写实测值和原因)
- [ ] 每页 `<head>` 有且只有一个 canonical,hreflang 三条(en / zh-Hant / x-default)互指

## 实现锚点

- 视觉源:`docs/design-ref/website/assets/site.css`(token 与组件)、`home.html` 的 header / footer 结构
- 字体源:`ios/QiCompass/QiCompass/Resources/QiSongti-Regular.otf`、`QiSongtiTC-Regular.otf`;参考 `tools/build_songti_fonts.py` 的子集写法
- 部署配置(`_redirects`、`_headers` 缓存头)放 `site/public/`

## 红线与约束

- 依赖只加 Astro 本体(和 S06 的 `@astrojs/sitemap`);**不加** Tailwind / React / Vue / 动画库 / 图标库
- 字体子集脚本确定性:同输入 → byte-identical 输出
- 不改 `ios/` 下的字体文件,只读取

## 测试

- `site/tests/` 放 Playwright 脚本:截图、关 JS 可读性、横向滚动、canonical/hreflang 断言(直接用环境里预装的 playwright,不要再 `playwright install`)
