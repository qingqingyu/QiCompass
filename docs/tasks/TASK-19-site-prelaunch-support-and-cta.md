# TASK-19 官网上架前的站务位:技术支持页入口 + 「取得 App」预上架状态

> 2026-11-27 外评复核建议。与官网 S05(`docs/官网实现-slices/S05-一期排盘器页与站务页.md`)**一起做**;依赖 TASK-18(上线开关单一事实源)先完成。

## 背景

App 提交审核时,App Store Connect 必须填「技术支持网址」和「隐私政策网址」,两者都指向官网(`/en/support`、`/en/privacy`,见 `docs/design-ref/website/README.md` §13 与官网 S08「最小上线」)。现状有两处空缺:

1. **技术支持页没有入口**:页脚「工具与指南」一栏有 Privacy,没有 Support;上线开关表里也没有对应区块(TASK-18 会补上 `support` 区块,但页脚还没有链接位)
2. **页头「取得 App」按钮在上架前是灰色不可点**:`Header.astro` 在 `app` 区块未上线时把按钮渲染成 `aria-disabled` 的灰色 `<span>`。规格 §7 要求上架前这里是「上架通知我」邮箱入口(Buttondown),上架后切成 App Store 徽章——灰按钮既不转化,也给人「网站坏了」的印象

## 方案

### 1. 页脚加技术支持入口

- `Footer.astro` 的 `tools` 数组在 Privacy 之后加一条:`{ p: "/support", name: "Support", nameHant: "技術支援" }`
- 门控走 TASK-18 的 `isLaunched("/support")`,与其他链接一致
- 页脚文案为站点 UI 文案,不属于后端术语,直接双语内联(与现有工具列做法一致)

### 2. 「取得 App」按钮按 CTA 状态渲染

S05 会建立全局配置 `site/src/config.ts` 的 `cta.state: 'prelaunch' | 'live'`。页头按钮改为读这个状态,而不是读 `app` 区块开关:

| `cta.state` | 渲染 | 文案 |
|---|---|---|
| `prelaunch` | 链接到当前语言首页的邮箱表单锚点 `langPath(lang, "/") + "#notify"` | en「Notify me」/ zh-hant「上架通知我」 |
| `live` | 链接到 `appStoreUrl`(外链,新窗口不强制) | en「Get the app」/ zh-hant「取得 App」 |

- 首页(S04 一期状态)的邮箱表单区块加 `id="notify"`;若当前页面就是首页,锚点直接滚动定位
- 两种状态都**不再**渲染灰色不可点的按钮;删除 `Header.astro` 里 `LAUNCH.app` 分支
- 文案进 `site.ts` 的 `UiStrings`(en / zh-hant 两腿齐全),新增 CJK 后重跑字体守护栏

## 测试

- 构建产物检查:`cta.state = 'prelaunch'` 时,`dist/en.html` 与 `dist/zh-hant.html` 的页头按钮 `href` 以 `#notify` 结尾,且首页存在 `id="notify"` 的元素;`live` 时 `href` 为 `appStoreUrl`
- `support` 区块关闭时页脚 Support 为灰显文字(无 `<a>`);打开后出链接,且产物死链检查要求 `/en/support`、`/zh-hant/support` 页面存在

## 验收

- `cd site && npm run build` 通过;`python3 tools/check_site_content.py` PASS(含产物死链 0)
- `python3 tools/build_site_fonts.py --verify` PASS(新增「技術支援」「上架通知我」等字)
- 截图:en / zh-hant × 预上架状态的页头与页脚,附在交付报告里
- 页头不再出现 `aria-disabled` 的按钮

## 全局约束(必读)

- 开工前读 `CLAUDE.md` 全文(「官网内容守护栏」为强制项)与 `docs/官网实现-slices/README.md` 全系列红线
- UI 改动先读 `DESIGN.md`:CTA 一律焦墨底、radius 5,朱红只做按钮里的菱形小点
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播;不得新增任何依赖(Buttondown 是纯 HTML 表单,已批准)
