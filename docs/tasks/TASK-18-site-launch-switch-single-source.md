# TASK-18 官网上线开关改为单一事实源 + 路由匹配修正

> **2026-11-28 复核:✅ 已完成**(实现提交 `2b234504`)。launch.json 单一事实源、TS / Python 匹配逻辑逐行一致、共享用例、误伤与漏判两处修正均实测通过。

> 2026-11-27 外评复核(对象:`3d90398d`「外评三处根治」)。上一轮外评的标题判据 / 产物死链扫描 / SC 字体改扫产物 / 天干拼名均已实测通过,本任务只处理复核中新发现的问题。

## 背景(复核发现)

`3d90398d` 给 `tools/check_site_content.py` 加了上线感知:解析 `site/src/data/site.ts` 的 `LAUNCH` 表,再用脚本内的 `LAUNCH_ROUTE_PREFIXES` 把开关键映射成路由前缀。实测发现 5 个问题:

1. **前缀匹配误伤**:`_route_offline` 对 `rest.startswith(p + "-")` 也判离线,所以 `dayMaster` 关闭时,`/day-master-calculator`(日主查询,属另一个开关)也被判为未上线。日主页未上线、查询工具先上线的组合下,合法内链会被误报为死链。实测:`_route_offline("/en/day-master-calculator", ["/day-master"]) == True`
2. **单个日柱页漏判**:规格 §3 的日柱页路径是单数 `/day-pillar/{gan-zhi}`,开关映射只登记了复数 `/day-pillars`。实测 `_route_offline("/en/day-pillar/jia-zi", ["/day-pillars"]) == False`——60 个日柱页永远不受开关约束
3. **「tools」开关三处语义不一致**:
   - `Footer.astro`:`tools` 同时管排盘器 `/bazi-calculator`、日主查询 `/day-master-calculator`、今日黄历 `/today` 三个链接
   - `Header.astro`:排盘器、今日黄历各用 `calculator`、`today` 两个独立开关
   - `check_site_content.py`:`tools` 只对应 `/day-master-calculator`
   - 后果:打开 `calculator` 开关后页头出链接,页脚仍灰显;校验脚本认为排盘器已上线,页脚却不出链接
4. **两处定义已经漂移**:开关表在 `site.ts`(TypeScript),路由映射在 Python 脚本里,靠正则解析 `site.ts` 对齐。第 3 条就是这种双写结构的直接后果,以后每加一个区块都要两处同改
5. **草稿页仍算「存在的路由」**:`main()` 用 `content/**` 下全部 `.md` 推导内容路由,没有过滤 `published: true`。产物死链扫描能兜底(草稿不构建 → 构建后被拦),但源码阶段的检查给出的是错误信号

另有两处小问题:

- `check_site_content.py` 路由过滤里有一行无意义表达式 `not any(seg := False for _ in ())`(恒为真),应删除
- `KNOWN_STATIC_ROUTES` 里的 `/support` 没有对应开关,目前恒算「已上线」,而该页还不存在(S05 才建)

## 方案

### 1. 开关表改为单一事实源 `site/src/data/launch.json`

```json
{
  "sections": {
    "calculator":      { "enabled": false, "prefixes": ["/bazi-calculator"] },
    "dayMasterFinder": { "enabled": false, "prefixes": ["/day-master-calculator"] },
    "today":           { "enabled": false, "prefixes": ["/today"] },
    "library":         { "enabled": false, "prefixes": ["/library"] },
    "guides":          { "enabled": false, "prefixes": ["/guides"] },
    "app":             { "enabled": false, "prefixes": ["/app"] },
    "about":           { "enabled": false, "prefixes": ["/about"] },
    "privacy":         { "enabled": false, "prefixes": ["/privacy"] },
    "support":         { "enabled": false, "prefixes": ["/support"] },
    "dayMaster":       { "enabled": false, "prefixes": ["/day-master"] },
    "tenGods":         { "enabled": false, "prefixes": ["/ten-gods"] },
    "fiveElements":    { "enabled": false, "prefixes": ["/five-elements"] },
    "stars":           { "enabled": false, "prefixes": ["/stars"] },
    "dayPillars":      { "enabled": false, "prefixes": ["/day-pillars", "/day-pillar"] },
    "zodiac":          { "enabled": false, "prefixes": ["/zodiac"] },
    "compatibility":   { "enabled": false, "prefixes": ["/compatibility"] },
    "glossary":        { "enabled": false, "prefixes": ["/glossary"] }
  }
}
```

- `site.ts` 删除 `LAUNCH` 常量,改为 import 这份 JSON,导出一个函数 `isLaunched(rest: string): boolean`(`rest` 是不带语言前缀的路径)
- **匹配规则**(TS 与 Python 两侧必须一致):命中某个 `prefix` 当且仅当 `rest === prefix` 或 `rest.startsWith(prefix + "/")`。**不**做「前缀 + 连字符」匹配(第 1 条误伤的根源)。一个路径若同时命中多个区块,取**最长**前缀所属区块。未命中任何区块的路径视为已上线(首页、语言根)
- `Header.astro` / `Footer.astro` 不再按开关键门控,统一改为对每条链接的 `rest` 路径调用 `isLaunched(...)`。页脚 `tools` 数组删除 `launch` 字段(第 3 条的根源)
- `check_site_content.py` 删除 `LAUNCH_ROUTE_PREFIXES`、`parse_launch_false()` 和对 `site.ts` 的正则解析,改为直接读 `launch.json`,用同样的匹配规则实现 `is_launched(rest)`。JSON 读取或结构不符时直接失败退出(错误显式传播)

### 2. 内容路由只算已发布页面

`main()` 推导内容路由时,只收 frontmatter `published: true` 的文件(复用现有的 frontmatter 解析),再与开关表取交集。

### 3. 清理

- 删除背景「另有两处小问题」里提到的那行无意义表达式
- `KNOWN_STATIC_ROUTES` 保留,但每条都要经过 `is_launched` 过滤(`/support` 等随之受开关约束)
- `site.ts` 与 `check_site_content.py` 里「翻开关须两处同改」的注释全部删掉,改写为「开关只改 `launch.json`」
- `CLAUDE.md`「官网内容守护栏」补一句:上线开关唯一事实源是 `site/src/data/launch.json`

## 测试

- 新增共享用例文件 `site/tests/fixtures/launch-cases.json`:每条用例 = `{ "enabled": [...开启的区块], "rest": "...", "expect": true/false }`,至少覆盖:
  - `dayMaster` 关、`dayMasterFinder` 开 → `/day-master-calculator` 为 true,`/day-master/jia-wood` 为 false
  - `dayPillars` 关 → `/day-pillar/jia-zi` 与 `/day-pillars` 都为 false
  - `calculator` 开 → `/bazi-calculator` 为 true
  - 首页 `/`、未登记路径为 true
  - `/guides-x` 这类仅字符串前缀相同的路径**不**被 `guides` 门控
- Node 测试(`site/tests/` 下新增 `launch.test.mjs`)与 Python 测试(`site/tests/test_s02.py` 或新文件)读**同一份**用例文件,分别断言 TS 与 Python 实现结果一致
- 内容校验:放一个 `published: false` 的测试内容页,另一页正文链到它 → `check_site_content.py` FAIL;改成 `published: true` 后 PASS(用 `site/tests/fixtures/` 下的夹具,不要往真实 `content/` 里放)
- 一致性:构建后,对每个开关组合(至少「全关」「只开 calculator」两种)检查页头与页脚中 `/bazi-calculator` 的出链状态一致

## 验收

- `cd site && npm run build` 通过
- `python3 tools/check_site_content.py` PASS;构建产物死链为 0
- 新增的 Node 与 Python 用例全部通过,且两侧读的是同一份 `launch-cases.json`
- `grep -rn "LAUNCH_ROUTE_PREFIXES\|parse_launch_false\|export const LAUNCH" site tools` 无结果
- 当前全部开关为 false 时,页头页脚的视觉与现在完全一致(灰显项数量不变)

## 全局约束(必读)

- 开工前读 `CLAUDE.md` 全文(「官网内容守护栏」为强制项),以及 `docs/官网实现-slices/README.md` 的全系列红线
- commit 必须三段式 body:Why / What / Impact
- 错误显式传播:禁止空 catch / 吞异常 / 用默认值掩盖失败
- 不得新增任何依赖
- 构建只用 `cd site && npm run build`;字体守护栏 `build_site_fonts.py --verify` 依赖构建产物,改完后一并重跑
