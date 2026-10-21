# 命书阅读页段落排版 A′ plan

> 2026-10-21 · 用户拍板:四版对比稿里选 **A′「结论即标题,段首不缩进」**
> 执行方:另一个 AI 实施 → Claude review。**本文是需求与验收清单,不是实现**。
> 对比稿:`docs/design-ref/mingshu-paragraph/对比稿.html`(浏览器打开)/ `对比稿.png`(截图),第三列 A′ 是定稿。
> 做之前先读 `CLAUDE.md`(「Prompt 回归守护栏」「三语模板同步守护栏」「Design System」)与 `DESIGN.md` § Typography、§ Decisions Log 2026-10-09 条。

---

## 0. 现状问题(v10,main `c24e390`)

1. **结论句不显眼**:M0 每节的 headline 是 17pt,正文 16pt,宋体只有一个字重,看起来像普通的第一段。v9「每节第一句不懂命理也能看懂」的设计意图在版面上没体现出来。
2. **代价段太长**:`core_loop.leak` 一个字段装了「代价 + 何时会变 + 现在怎么做」,在手机上是五六行的一大段。
3. **段首缩进**:用户不喜欢每段开头空两格(`"　　"` 前缀)。

## 1. 定稿规格(A′)

| 项 | 现状 | A′ | 适用范围 |
|---|---|---|---|
| 正文段首缩进 | 2em(全角空格前缀) | **取消** | **全部章节**(M0-M7 结构化渲染 + 散文回退态) |
| 段与段间距 | 小节内 16pt | 保持 16pt(不缩进后靠这个分段) | 全部章节 |
| 小节名(含结论句的小节) | 20pt 宋体 + 16×1.5 墨横 | **12.5pt `inkMuted`,tracking 2,前置 12×1 `inkMuted` 短横** | 仅首个子节点为 `.headline` 的小节(目前只有 M0 v9+) |
| 结论句 `.headline` | display 17pt,行距 6 | **display 21pt,`ink`,tracking 0.5,行距约 1.5×**;与下方正文间距 14pt | M0 |
| 小节与小节间距 | 28pt | **44pt**(只用留白,不加线) | 仅 M0 章节(含 headline 的章节) |
| `core_loop.leak` | 一段 | **三段**:代价 / 何时会变 / 现在怎么做 | M0(需模板改动,见 S2) |

不变的:正文 16pt、行距约 1.65×、颜色 token、章题与副题、左缘章号栏、「据 ›」折叠、章末批印、M1-M7 的小节题样式与节间距。

**原则**:不新增颜色、字重和字体;M1-M7 除「去缩进」外视觉零变化。

---

## 2. 切片

### S1 · iOS 排版(`ios/QiCompass/QiCompass/Features/DeepAnalysis/`)

1. **去缩进(全局)**:
   - `ChapterContentView.swift` `leadParagraph`:去掉 `"　　" +` 前缀
   - `ChapterReadingView.swift` `indentedProse`(散文回退态):去掉缩进。原逻辑「多段逐段缩进,空行保留为段间距」改为:按换行拆段,非空行各成一段,段间距 16pt(与结构化渲染一致);连续空行不产生额外空隙。函数名改成与新行为一致的名字
   - 同步更新两处文件头和函数注释里「首行缩进 2em」的描述
2. **`.lead` 支持文内换行分段(全局)**:`.lead` 文本含 `\n` 时按换行拆成多段渲染,段间距 16pt,空行忽略。这样 S2 的 leak 三段可以直接显示;M1-M7 偶有换行的旧内容也会正确分段。在 `ChapterContent` 组装层拆或在 View 层拆都可以,要选一处、写测试
3. **含结论句小节的标题样式(M0)**:在 `sectionHeader`(或组装层给小节加标记)中判定:小节首个子节点是 `.headline` 时,用 A′ 小标样式(见第 1 节表格);否则保持现有 20pt + 墨横。判定条件要写在注释里,不要按章节号硬编码
4. **结论句样式**:`headlineParagraph` 改为 21pt、tracking 0.5、行距约 1.5×;`headlineLineSpacing` 相应调整;headline 与后续正文间距 14pt
5. **M0 节间距 44pt**:仅当章节内容含 `.headline` 节点时,顶层 `VStack` 的 spacing 用 44,否则保持 28
6. **测试**:`ios/Tests/Shared/ChapterContentTests.swift` 补:
   - `.lead` 含 `\n\n`、`\n`、首尾空行时拆段结果正确
   - v7/v8 老缓存(无 headline)的 M0 渲染树不受第 3、5 条影响
   - 散文回退态不再出现全角空格前缀
7. **DESIGN.md 同步**:§ Typography 的 Body 行和第 39 行「首行缩进 2em」改为「不缩进,段间距 16pt」;§ Decisions Log 加一条 2026-10-21:用户在对比稿中选定 A′,修订 2026-10-09「首行缩进 2em 保留」;写明结论句 21pt、小节小标、M0 节间距 44 的口径与适用范围

**新文件**:原则上不新建 `.swift` 文件。如果必须新建,按 CLAUDE.md 在 pbxproj 中 4 处登记一致的 24 位 ID。

### S2 · M0 模板 v10 → v11:leak 分三段

新建 `backend/app/ai/prompts/{zh,zh-hant,en}/m0_structure_v11.md`(v10 不动);`PROMPT_VERSIONS["m0_structure"]` 10 → 11,写版本注释;`M0_STRUCTURE_TEMPLATE` 常量与 zh v11 保持 byte-identical,同步更新 `tests/test_v1_prompt_render.py` 中的期望版本。

1. `core_loop.leak` 写法改为**三段,用换行符分隔**,顺序固定:
   - 第一段:代价(只讲代价)
   - 第二段:何时会变(大运写法与 v10 相同:「约 X 岁起的那十年(某某运)」)
   - 第三段:现在可以怎么做
   - 每段 1-2 句;不加「代价:」之类的段首标签(对比稿 C 方案的提示词用户没选)
2. 同步改所有提到 leak 写法的地方:【证据引用纪律】「短板不许只下判决」一条、【三层写法】第 1 条、问题 2、【字段职责表】leak 一行、【写法示范】循环 · leak 示例(示例也写成三段,只用占位符,不写真实干支和岁数)、文末「校验:」一行
3. **JSON 转义要明确写进模板**:换行必须写成 JSON 字符串里的 `\n` 转义,不能在字符串里直接回车(直接回车会让整个 JSON 解析失败)。这一条和 v5 的「中文引号」规则放在一起
4. 如果示范短语有改动,同步更新防抄清单 `M0_V9_EXAMPLE_PHRASES`
5. evalkit:在 `grounding.py` 加一个只统计不判失败的 warning(走 `collect_banned_register_warnings` 同款旁路),检查 leak 是否恰好三段非空段;先观察分布,不进 verdict

**验收**:
- `python3 tools/check_prompt_sync.py` PASS
- `cd backend && python -m pytest` 全绿(含 `test_v1_prompt_render.py`、`test_i18n.py`、`test_evalkit_grounding.py`)
- 样本盘(丙寅 辛丑 庚午 庚辰,`1987-01-21T08:00:00+08:00` 男)实跑 M0 ≥3 次:leak 是否三段、JSON 是否都能解析,附原始 JSON
- `cd backend && python -m evalkit.runner` 全量,对比当前 BASELINE(`20261016T043426-410fed`)无真退化。**重点单列 M0 的 JSON 解析失败数**:比 BASELINE 多就说明换行转义出了问题,先停下报告。BASELINE 不改

### S3 · 真机走查(用户)

实施完成后由用户在真机上目验:M0 章(新生成内容)、M0 老缓存、M1 章、散文回退态各一屏截图,亮色和暗色各一套。结论句字号如需微调(如 21 → 19),一行改动,在走查后定。

---

## 3. 不在本轮

- 对比稿 C 方案的段首提示词(「代价 · / 何时会变 ·」):用户没选,真机试读后如果觉得代价段仍不好扫读再议
- M1-M7 引入结论句层:需要模板改动和 schema 变化,另立项
- EN 排版:EN 原来也有缩进前缀,去缩进随全局生效;EN 的结论句字号是否同为 21 由 S3 走查一并确认

## 4. 实施记录(实施方填写)

- [x] S1 commit:`76a9342`(iOS 4 文件 + DESIGN.md;+169/-48)
- [x] S2 commit:`722b9c9`(backend:三语 v11 模板 + prompts.py + evalkit warning + 2 测试文件;+516/-14)
- [x] 样本盘实跑结果(丙寅 辛丑 庚午 庚辰,1987-01-21T08:00+08:00 男,M0 v11 直连 ×3):3/3 全成——JSON 全部可解析,leak 全部恰好三段非空段(代价/何时会变/现在怎么做,无段首标签),大运括注岁数干支对账全过;原始 JSON 存 `/tmp/mingshu_v11_sample_out.txt`(throwaway,不入 git)
- [x] evalkit run id + M0 解析失败数对比:首轮 `20261021T071156-38645a`(M0 解析失败 3→1,leak 三段 20/20;diff 35 regressed 中 23 条为 z.ai 网络瞬断级联,无对比数据);按 §6-2 缓存清洗重跑 `20261021T133548-38645a`(118/160 命中缓存,只重掷失败条)——**M0 JSON 解析失败 3→0,leak 三段 20/20,字面 \n 双写 0 命中,m0 生成侧 0 异常**。清洗轮 diff 18 regressed 逐条判定全部非真退化:5 条链式 error(根因=本轮 3 次下游新掷 JSON 解析失败 → 缺字段级联;glm 长模块已知脆弱,BASELINE 同类 6 条)+ 13 条内容降级,全部命中 BASELINE 已存在类别(生产禁词 9 / special_pattern 10 / 解析失败 6 / 干支 4 / 照抄 2 条),且同时存在 **40 条 fixed**(基线 fail → 本轮 pass/warn)——temp≠0 全链重掷的 verdict 翻转双向对称,单看 regressed 数无意义,逐条类别核对无一为 v11 新引入(case_19「绝对」簇已溯源为共享 header 规则文本被模型违反、fingerprint 干净,非链字段注入;m1-m7 模板与共享 header 本批未动)。BASELINE 未改
- [x] DESIGN.md 更新位置:§Typography Body 行 + Type scale Body 行 + §「深度解析盘面小景」阅读页段 + §Decisions Log 新增 2026-10-21 条(修订 2026-10-09「首行缩进 2em 保留」)
- 验收补充:`tools/check_prompt_sync.py` PASS;backend pytest 1351 绿;iOS 全量 658 绿(ChapterContentTests 28 条含新 3 条);双 review 循环 2 轮收敛(第 2 轮双方 0 问题,唯一修复为注释级)
- 偏离本 plan 的地方及理由:
  1. 「JSON 换行转义规则与 v5 中文引号规则放在一起」——中文引号规则在共享 `_V1_SYSTEM_PROMPT`,而共享 header 不能动(m1-m7 常量与其现役文件的 byte-identical 断言依赖,动它等于全模块 bump)。改为以 `_M0_NEWLINE_ESCAPE_CHECK` 常量行**拼接**在共享 header 自检块末行之后(zh v11 文件内与中文引号规则同块),语义等价
  2. `.lead` 拆段选**模型层**实现(`ChapterContent.leadParagraphs`),且结构化渲染与散文回退态共用同一函数——plan 允许两层任选,单源可避免两处分头拆段漂移,测试打在模型层
  3. 写法示范岁数从「约三十岁」改为「约 X 岁」占位(plan 第 2.1 节脚注「不写真实干支和岁数」的从严执行);示例短语全部保留 → `M0_V9_EXAMPLE_PHRASES` 零改动

## 5. Review 清单(Claude review 时逐条核)

- [x] 全局去缩进:结构化渲染与散文回退两处都改了,注释同步
- [x] `.lead` 换行拆段有测试;老缓存 M0 渲染树不受小节样式和节间距影响
- [x] 小节样式判定基于章内节点形态(`containsHeadline`),没有按章节号硬编码——**2026-10-21 review 修订:按节判定改按整章判定**(模型漏写某节 headline 时该节回退 20pt 大标题与同章小标混排,v10 实测漏过 capability_source.headline)
- [x] 没有新增颜色、字重、字体;DESIGN.md 已更新并记入 Decisions Log
- [x] 三语 v11 同步,v10 未改,常量 byte-identical;JSON 换行转义规则写进模板
- [x] evalkit 全量 M0 解析失败数未上升(3→1);BASELINE 未改
- [x] commit 三段式(Why / What / Impact)

## 6. Review 后续修复(2026-10-21 晚,同批落地)

外部 review 四条,全部落地:

1. **小标按整章判定**(iOS,`ChapterContentView`):`chapterHasHeadline` 逐层下传,章内含任一结论句则本章所有小节统一小标——漏写某节 headline 不再回退 20pt 大标题混排;测试补 `test_containsHeadline_trueEvenWhenSomeSectionMissesHeadline`
2. **evalkit 清洗重跑**:首轮 run 的 23 条网络瞬断退化无对比数据不算数;缓存命中只重掷失败条重跑全量(`20261021T133548-38645a`,118/160 命中)——M0 全指标优于基线(解析失败 3→0 / leak 三段 20/20 / 字面 \n 0),剩余 18 regressed 逐条判定全部为存量债类别 + 重掷噪声(双向对称,另有 40 条 fixed),无 v11 引入的真退化,过闸(详见 §4)
3. **换行双写判据**(`evalkit/checks/grounding.py::check_no_literal_newline_escape`,判 fail 不止 warning):任何输出字符串叶子含字面 `\n` 两字符 → fail(模型把 JSON 转义多写一层时,iOS 不拆段且正文直接显示「\n」;本轮 glm 0 命中,换模型/换供应商的风险面);与「JSON 解析失败」判据合成漏写/双写双向守;补 2 条测试
4. **translate v4**(三语):加第 10 条「字符串值内的换行(\n)原样保留,分段位置与段数一一对应,JSON 输出照旧 \n 转义」——翻译模板原只要求同构 JSON,M0 v11 leak 三段译后可能被合成一段;按 D10.6 已接受口径 bump 不让已缓存译文失效
