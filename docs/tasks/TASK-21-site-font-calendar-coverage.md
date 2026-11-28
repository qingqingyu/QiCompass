# TASK-21 官网字体覆盖「随日期变化的字」+ 重建当前缺字

> 2026-11-28 外评复核(对象:官网 S03–S05 与 TASK-18 / TASK-19 合入后的 `main`)。**12 月 21 日(冬至)前必须完成**,否则英文首页当天会出现缺字。

## 背景(复核发现)

### 1. 字体子集校验当前不通过

`python3 tools/build_site_fonts.py --verify` 在 `main` 上 FAIL:

- 简体子集(`site/public/fonts/knowfate-sc.woff2`)缺「或」「案」
- 繁体子集(`site/public/fonts/knowfate-tc.woff2`)缺「折」

「或」「案」出现在繁中「关于」「隐私」等页面正文里(简体字体也会作为后备渲染 Big5 外的字)。字体最后一次重建在 S04 提交 `a1d778ce`,S05 的站务页合入后没有重建。

### 2. 结构问题:简体字体只收了「构建当天」出现的字

`build_site_fonts.py` 的简体腿改为扫描构建产物(`3d90398d`)后,只收英文页**构建当天实际显示**的汉字。但英文首页的「今日」条(`site/src/pages/en/index.astro` 第 118–121 行)每天按 `site/src/data/calendar.json` 渲染:

- 当天的年 / 月 / 日干支(`today.y` / `today.m` / `today.d`)
- 当前节气与下一个节气名(`today.jieqi` / `today.nextJieqi`,包在 `<span class="zh">` 里)

实测当前简体字体**缺 24 节气用字中的 20 个**(冬、至、立、春、分、夏、秋、寒、暑、雨、露、霜、降、清、惊、蛰、芒、种、谷、满、白)。下一次出问题是 **2026-12-21**:当前节气变为「冬至」,两个字都不在字体里,浏览器会用系统字体顶替,与宋体混排。

这个问题**平时报不出来**:每日定时重建只更新页面、不重建字体;`--verify` 只拿当天的构建产物对比,当天的字永远是全的。

### 3. 内联脚本里的中文报错文案被打进英文页

`site/src/components/WuxingCycle.astro` 第 110 行:`throw new Error(".wx-grid 缺 .wx-svg 或 wood 文案——组件模板被改坏")`。这段脚本内联进页面 HTML,英文页也带着这串中文;字体扫描读的是产物 HTML,会把这些开发者报错用字算作页面用字,白白增加字体体积。

## 方案

### 1. 简体硬性集合加入「日历窗口」全量用字

在 `tools/build_site_fonts.py` 里仿照现有的 `en_rendered_term_chars()`,新增 `en_calendar_chars()`:

- 读取 `site/src/data/calendar.json`,遍历 `days` **全部条目**(不是只取 `buildDay` 那天)
- 收集英文页会渲染的字段:`y`、`m`、`d`、`jieqi`、`nextJieqi` 的全部 CJK 字符
- 字段缺失或结构不符直接抛错(错误显式传播,严格取键,不静默返回空集)
- 并入 `scan_hard_chars()` 返回的简体硬性集合:`sc_chars | brand | en_rendered_term_chars() | en_calendar_chars()`
- 函数 docstring 写明:英文页若以后渲染 `calendar.json` 的其他中文字段,必须同步加进这里

> 繁体腿目前扫描源码(含 `src/data/calendar.json`),已覆盖;不要改繁体腿的扫描方式。

### 2. 修报错文案

`WuxingCycle.astro` 的报错改为英文(例如 `".wx-grid is missing .wx-svg or the wood copy — component template changed"`)。顺手检查 `site/src/components/` 与 `site/src/pages/` 下其他**会进入页面 HTML 的内联脚本**,把中文报错 / 日志文案一并改成英文;源码注释不受影响(注释不进产物)。

### 3. 重建字体

```bash
cd site && npm run build && cd ..
python3 tools/build_site_fonts.py          # 重建(依赖构建产物)
cd site && npm run build && cd ..          # 让新字体进 dist
python3 tools/build_site_fonts.py --verify
```

### 4. 加一个跨日期回归测试

在 `site/tests/` 新增 Python 测试(用 `python3 -I` 运行,与现有测试风格一致):

- 读取 `calendar.json` 的全部 `days`,取每天的 `y` / `m` / `d` / `jieqi` / `nextJieqi` 字符
- 读取 `site/public/fonts/knowfate-sc.woff2` 的字符表(fontTools)
- 断言:**每一天**的这些字都在简体字体里;失败时列出日期和缺的字
- 再断言 24 个节气名的全部用字都在简体字体里(防 `calendar.json` 窗口恰好没覆盖某个节气)

## 验收

- `python3 tools/build_site_fonts.py --verify` PASS
- 新增的跨日期测试 PASS;临时把 `calendar.json` 的某天 `jieqi` 改成字体里没有的字,测试能报出该日期与缺字(验证后还原)
- 简体字体体积在交付报告里写明前后对比(预期只增加几十个字,几 KB)
- `cd site && npm run build` 通过;`python3 tools/check_site_content.py` PASS(含产物死链 0)
- 英文页产物 HTML 里不再出现「缺 .wx-svg」这类中文报错文案:`grep -l "缺 \.wx-svg" site/dist/en*.html site/dist/en/*.html` 无结果

## 全局约束(必读)

- 开工前读 `CLAUDE.md` 全文(「官网内容守护栏」为强制项)与 `docs/官网实现-slices/README.md` 全系列红线
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 不得新增任何依赖(fontTools、brotli 已批准)
- 构建只用 `cd site && npm run build`
