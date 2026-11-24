# S04 首页 + Library + 交互组件

- **类型**: AFK
- **Blocked by**: S03
- **覆盖规格**: `design-ref/website/README.md` §4.1、§4.4、§10、§12(一期状态)
- **视觉稿**: `docs/design-ref/website/home.html`、`library.html`
- **Parent**: `docs/官网实现-slices/README.md`

## What to build

1. **交互组件**:
   - `ShichenDial`:SVG 由构建期生成(参考 `docs/design-ref/website/home.html` 里的 dial SVG 坐标;十二地支是指向 `/en/guides/chinese-hours#{branch}` 的链接),浏览器端只做「按访客本地时间点亮当前时辰」(这是读时钟不是历法计算,允许)
   - `WuxingCycle`:SVG + 点选高亮(生线墨青 / 克线浓墨 / 其余 14%)+ 释义面板;关 JS 时默认显示「木」
   - `DayMasterGrid`(首页 5×2)与 `DayMasterRow`(Library 10 列)
   - `JiaziGrid`:60 格,数据来自构建期导出(干支、拼音、纳音英文名,纳音取 `terms.json`);今日日柱标记见下
   - `LibrarySearch`:对静态链接做过滤(Library 普通条目隐藏,甲子格子淡出 + 模糊),显示命中数
2. **首页 `/en/`**:区块顺序按规格 §4.1。**一期状态**:hero 表单换成「Notify me when the calculator opens」邮箱表单 + 「Browse the library」次按钮;App 区为邮箱表单
3. **今日条 + 甲子矩阵今日标记**:数据由构建期脚本 `tools/export_site_calendar.py` 调后端引擎(`lunar_python`,必须 `setSect(1)`)生成未来 400 天的「日期 → 年月日干支、农历、节气」JSON;页面按 UTC+8 当天取值渲染。Cloudflare Pages 每天定时重建一次(Deploy Hook + cron,S08 配置)。**构建环境调不到引擎 → 构建失败**,不要静默隐藏
4. **Library `/en/library`**:区块按规格 §4.4;吸顶分区 chips;所有条目是真实链接,一期尚未发布的页面:链接照常生成但该条目显示为灰色不可点(`aria-disabled`,不输出 `href`),避免死链
5. **zh-hant 首页与 Library**:同模板换语言(`lang="zh-Hant"`、`--f-zh-tc`、术语取 zh-hant 值);中文 H1 可做「竖排题签 + 横排标题」双写(竖排部分 `aria-hidden`)

## Acceptance criteria

- [ ] 首页、Library 与设计稿在 1440 / 390 视觉一致(截图附报告);一期状态的 hero 用设计稿 `.anno` 注释描述的样子
- [ ] 关 JS:时辰盘静态显示(无当前时辰点)、五行面板显示木、Library 全部条目可见
- [ ] `export_site_calendar.py`:抽查 2026-11-24 = 丙午 己亥 壬寅、1992-04-18 = 甲子日;23:00 后的时刻按次日算(setSect(1))
- [ ] 甲子矩阵 60 格纳音英文名全部来自 `terms.json`(`check_term_sync.py` PASS)
- [ ] 键盘可操作:五行节点 Tab 可聚焦、Enter / Space 触发;Library 搜索框有 label
- [ ] 无死链(`check_site_content.py` 的链接检查覆盖首页与 Library)
- [ ] Lighthouse 移动端 Performance ≥ 95

## 红线与约束

- 浏览器端不计算任何干支;「今日」只是查构建期生成的表
- 不用 canvas / WebGL / 动画库;全部 SVG + CSS + 少量原生 JS
- 禁止视差、自动轮播、装饰性发光(DESIGN.md Motion「禁止」条)
