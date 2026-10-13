# 命书 M0「主线结构」内容质量修复 plan

> 2026-10-12 · 来源:用户真机截图(深度 → 壹 主线结构)+ 外部读者反馈「太生硬」+ 代码核查
> 执行方:另一个 AI 实施 → Claude review。**本文是需求与验收清单,不是实现**。
> 做之前先读仓库根 `CLAUDE.md`(尤其「Prompt 回归守护栏」「三语模板同步守护栏」「context_token 绑定守护栏」「Design System」)。

---

## 0. 样本(问题现场)

命盘:**丙寅年 辛丑月 庚午日 庚辰时**(日主庚金,判偏旺)。引擎给的十神权重(`compute_ten_god_weights`,天干 5 / 地支主气 3 / 余气 1):

| 十神 | 权重 | 来源 |
|---|---|---|
| 七杀 | 6 | 年干丙 5 + 寅藏丙 1 |
| 劫财 | 6 | 月干辛 5 + 丑藏辛 1 |
| 比肩 | 5 | 时干庚 |
| 正印 | 4 | 丑主气己 3 + 午藏己 1 |
| 偏印 | 3 | 辰主气戊 3 |
| 偏财 | 3 | 寅主气甲 3 |
| 正官 | 3 | 午主气丁 3 |
| 伤官 | 2 | 丑藏癸 1 + 辰藏癸 1 |
| 正财 | 1 | 辰藏乙 1 |
| 食神 | 0 | — |

五行计数(`compute_element_balance`,**只数 8 字透出,不含藏干**):木1 火2 土2 金3 水0。

M0 实际输出(节选,原文照录):

- 主线:主导 七杀 / 次要 正印 / 潜伏「伤官与财星组(偏财、劫财)」
- 据:「七杀:年干丙坐于日主之上,权重6……正印:权重4,现于月支丑与日支午的藏干,土数为2……」
- 流向:「七杀(压力、外部要求)→ 正印(系统化…)→ 回到七杀(…)→ 七杀 → 正印」
- 驱动:「日主庚偏旺,有比肩(权重5)与劫财(权重6)扶持,因此命局能够承受七杀而不被压垮;土支(丑月、辰时、午日)生助正印……」
- 损耗:「此循环在水与木处泄漏:水为0,因此食伤桥梁(伤官/食神,食神=0)几乎不存在——转化后的印难以以可见的输出……」
- 据:「five_elements: 水0,木1;ten_god_weights: 食神0,伤官2,劫财6;……」
- 结构类型 · 名称:「杀印相生格 (杀印相生格)」
- 一句话 / 能力来源 / 末段:三处都在说「吸入强、输出弱、可见成果少」

---

## 1. 问题清单(按严重度)

### A. 违反项目红线 / prompt 自身规则

| # | 问题 | 证据 | 根因 |
|---|---|---|---|
| A1 | 输出硬格局名「杀印相生格」 | 结构类型 · 名称 | M0 第 3 问「这个结构**在命理中属于什么类型**?」直接诱导套传统格名,违反 ADR-0006 / CLAUDE.md「禁止给出××格硬分类」。evalkit `check_no_hard_geju` 只列了 13 个单十神格名,复合格名(杀印相生格/伤官配印格/食神制杀格/财滋弱杀格…)漏网 |
| A2 | 身旺盘把印、比劫讲成助力 | 驱动段「比劫扶持,因此能承受七杀」+ 正印作「转化通道」主叙事 | prompt 已有口径规则(v3 ⑤),LLM 未遵守,且无机器校验兜底 |
| A3 | 并列最重未写明,三层分级失真 | 七杀 6 = 劫财 6,劫财被放进「潜伏」 | prompt 已有规则(v3 ③),但只约束「最重」措辞,没约束 dominant/latent 分层必须与权重排序一致 |
| A4 | flow 复述链条且多转一圈 | 流向段 | prompt 已有规则(v3 ④),LLM 未遵守,无机器校验 |
| A5 | 机器字段名外泄 | 「据 · five_elements: …;ten_god_weights: …」 | prompt 禁用清单是「ten_god_weights、ten_gods、…之类」,未显式列 `five_elements`;且无机器校验。另需排查本条内容是否来自 translate 端点(见 D2) |

### B. 命理事实错误(会被懂行用户一眼识破,伤「专业不忽悠」定位)

| # | 问题 | 正确事实 |
|---|---|---|
| B1 | 「土支(丑月、辰时、午日)」 | 午属**火**;本盘土支只有丑、辰 |
| B2 | 「财星组(偏财、劫财)」 | 劫财属**比劫**,不是财星 |
| B3 | 「年干丙坐于日主之上」 | 年干与日主无「坐」的关系(「坐」指天干坐下方地支) |
| B4 | 正印讲了,偏印 3(辰主气戊)全文未提 | 印星结构只讲一半 |

### C. 数据口径冲突(引擎层根因)

| # | 问题 | 根因 |
|---|---|---|
| C1 | 「水为0,食伤几乎不存在」与「伤官权重2」并存 | `five_elements` 只计透出 8 字;`ten_god_weights` 含藏干。两套口径同时进 chart,LLM 把「藏而不透」说成「缺失」。prompt 也没告诉 LLM 两者口径不同 |

### D. 叙事框架与语言

| # | 问题 |
|---|---|
| D1 | 全篇损耗视角:「可见成果很少 / 最弱 / 泄漏 / 流失 / 巩固能力差」;短板只下结论,不给「什么条件下会变」和「怎么用」→ 读者感觉被判决 |
| D2 | 翻译腔痕迹:「杀印相生格 (杀印相生格)」括注自我重复、「难以以可见的」、「在水与木处泄漏」——疑似 en 生成后经 `/api/interpret/translate` 译回 zh,或 LLM 模仿 en 版「English (中文)」格式。**需先查实来源再决定修哪层** |
| D3 | 同一结论重复 4 次:一句话 / 损耗 / 能力来源 / 末段(structure_fingerprint)都在说「吸入强输出弱」。字段职责没划清 |
| D4 | 抽象名词堆叠:「转化环节」「承载能力」「输出至财的一段」——违反 `_V1_SYSTEM_PROMPT`「用可观察行为描述」要求 |

### E. 呈现层(iOS)

| # | 问题 |
|---|---|
| E1 | `ChapterContent.swift` 通用键值渲染把 JSON 结构原样摊开:主导/次要/潜伏/起点/终点/流向/驱动/损耗 8 个小标签连排 + 灰色「据 ·」,读感像表单不像命书 |

---

## 2. 修复切片

> 每片独立可 review。S1-S3 是本轮必做;S4 需用户拍板后再做;S5 只记录不做。

### S1 · M0 prompt 修红线 + 命理自检(必做)

改 `backend/app/ai/prompts/{zh,zh-hant,en}/m0_structure_v6.md`(新建三份,v5 保留不动)+ `prompts.py` 里 `PROMPT_VERSIONS["m0_structure"]` 5→6 并在其上方按既有格式写版本注释。**注意**:`prompts.py` 的 `M0_STRUCTURE_TEMPLATE` 常量与 zh 当前版本文件 byte-identical,由 `tests/test_v1_prompt_render.py` 锁定——zh v6 文件与常量必须同步改成一致。

1. **改第 3 问**(A1):去掉「在命理中属于什么类型」。改为「用一个描述运转方式的白话名字概括(如「压力转化型」「蓄而不发型」),**不得**使用任何以「格」结尾的传统格局名,包括复合格名(杀印相生格、伤官配印格、食神制杀格、财滋弱杀格等)」。`structure_type.name` 校验行同步加此约束。
2. **分层与权重一致**(A3):dominant / secondary / latent 必须按 `ten_god_weights` 降序分层;并列最高的十神必须同处 dominant 层并写「并列最重」;权重更高的十神不得落在比低权重十神更低的层。
3. **十神归类与地支五行自检**(B1-B3),加进【证据引用纪律】:
   - 十神五类归属固定:比肩/劫财=比劫,食神/伤官=食伤,偏财/正财=财星,七杀/正官=官杀,偏印/正印=印星;归类不得跨类
   - 地支五行固定:寅卯木,巳午火,申酉金,亥子水,辰戌丑未土;列举「土支 / 水支…」时只能列该五行的地支
   - 「坐」只用于天干与其下方地支的关系
4. **印星正偏都要交代**(B4):印星 / 财星 / 官杀等若正偏两者权重都 >0,叙事须同时交代,不许只提一个。
5. **五行口径声明**(C1,prompt 侧):在 chart 前加一行说明——「五行计数只数四柱 8 个透出的字,不含藏干;十神权重含藏干。某行五行计数为 0 但对应十神权重 >0,意思是『藏而不透』,必须写成『藏 / 未透出』,不得写成『没有 / 缺失 / 不存在』」。
6. **缺 / 藏 / 弱 三分法**:写短板时只能用这三种措辞之一,且须与上条数据一致。
7. **短板配条件和出路**(D1):`core_loop.leak` 与 `capability_source.text` 每提一个短板,必须同时写①它在什么条件下会改变(引用 `luck_pillars` 里实际存在的大运干支,或写「遇到 X 行旺的运」)②当下可以怎么用 / 怎么补。只下结论不给条件 = 不合格。
8. **字段职责去重**(D3):
   - `structure_type.one_line`:只讲「它怎么运转」,不讲代价
   - `core_loop.leak`:讲代价 + 条件 + 出路(唯一讲代价的地方)
   - `capability_source.text`:只讲优势从哪来、在什么场景最强,不复述代价
   - `structure_fingerprint`:沿用现规则
   - 加一条:「同一判断只在一个字段出现」
9. **机器字段名清单补全**(A5):禁用列表显式加 `five_elements`、`ten_god_weights`、`day_master`、`useful_god_candidates`、`luck_pillars`、`current_luck`、`shishen_zhi`、`shishen_gan`,保留「之类」兜底。
10. **语言**(D4):加 ✗/✓ 对照一组,例如 ✗「输出至财的一段薄弱」 ✓「你把事做成了,但不太会把它变成钱或可见的成果」。

> zh-hant / en 三份按同语义各自写,不是机翻;术语用词对齐 `term_translations.py`。

**验收**:
- `python3 tools/check_prompt_sync.py` PASS
- `cd backend && python -m pytest tests/test_i18n.py tests/test_v1_prompt_render.py` 全绿(三语文件 parity + 常量/文件 byte-identical)
- 用样本盘(丙寅 辛丑 庚午 庚辰)实跑 M0 至少 3 次(temp 0.3 有随机性),输出逐条对照第 1 节问题清单,附原始 JSON
- `cd backend && python -m evalkit.runner` 退出码 0(**禁止**改 BASELINE 掩盖退化)

### S2 · evalkit 机器校验补洞(必做)

改 `backend/evalkit/checks/grounding.py` 和/或 `deterministic.py`,每条配单测(放 `backend/tests/test_evalkit_grounding.py` / `test_evalkit_deterministic.py`)(用第 0 节样本输出做正例 fixture,另配不误报的反例)。遵守该文件「宁可漏报不可误报」立场。

1. **复合格名**(A1):`check_no_hard_geju` 从固定词表扩成「词表 + 模式」:`[一-鿿]{2,6}格` 结尾命中,排除白名单(格局、性格、风格、规格、资格、价格、人格、表格、格外、严格、合格、及格、品格、体格、定格、破格、升格、降格、格式 等,实现时按误报补齐)。反例测试必须包含这些日常词。
2. **机器字段名外泄**(A5):扫所有输出字符串,命中 chart JSON 的 key 名(从 chart 实际 keys 动态取,不要手写死清单)即 fail。
3. **地支五行归属**(B1):句中出现「X支(…)」或「X支:…」列举时,括号内地支须全部属于五行 X。保守实现:只在「土支/木支/火支/金支/水支」字面后紧跟括号列举时判。
4. **十神类别归属**(B2):「财星 / 官杀 / 印星 / 食伤 / 比劫」后紧跟括号列举的十神,须全部属于该类。
5. **flow 复述链条**(A4):`core_loop.flow` 里出现 ≥2 个「→」/「->」即 fail。
6. **分层与权重一致**(A3):`main_axis.dominant` 提到的十神,其权重须 ≥ `latent` 里提到的任一十神权重;并列最高者不得出现在 latent。提取不到十神名时跳过不判。

**验收**:`cd backend && python -m pytest tests/test_evalkit_grounding.py tests/test_evalkit_deterministic.py` 全绿;样本输出喂进去,A1/A3/A4/A5/B1/B2 六条全部命中 fail。

### S3 · 查清 D2 翻译腔来源(必做,先查后改)

1. 确认截图这份 zh 内容是 zh 直出还是 `/api/interpret/translate` 译回(查后端 SQLite 缓存行 / 日志 / iOS 走查路径,写明结论和证据)
2. 若是翻译产物:检查 `prompts/zh/translate_v1.md` 是否要求保留术语原文 / 括注原文;补「术语已是中文时不加括注」「不得保留源语言的机器字段名」规则 → `translate` 版本 1→2,三语同步
3. 若是 zh 直出:在 S1 的 zh 模板里加「名称不加括注,不重复」
4. 结论写进本文第 4 节「实施记录」

### S4 · iOS 呈现(**需用户拍板后才做**,不要擅自动 UI)

按 CLAUDE.md:UI 改动必须先读 `DESIGN.md`,偏离须用户批准。实施方只出方案,不改代码:

- 方案草案:M0 章节专用渲染——`from`/`to`/`flow` 合成一句叙述;`dominant/secondary/latent` 合成一行「主导 七杀 · 次要 正印 · 潜伏 伤官」;`evidence` 默认折叠成「据」小字可展开
- 给出两三个方案对比 + 改动面(`ChapterContent.swift` / `ChapterContentView.swift`),新 .swift 文件须 pbxproj 4 处登记

### S5 · 不在本轮(仅记录)

- M0 引入大运维度(「命是底盘,运是时机」只能靠 M0 读 `luck_pillars` 部分体现;S1 第 7 条已要求短板引用大运,完整的运维度改造另立项)
- 引擎侧给五行加「含藏干的力量」新字段(动 `chart_builder` / `context_binding` 绑定字段 / iOS `PromptContextBuilder` 镜像,触发 context_token 守护栏,改动面大;S1 第 5 条 prompt 声明先止血,数据层方案另立项待拍板)
- `_V1_SYSTEM_PROMPT` 共享 header 改动(会让 8 个模块全部 bump + evalkit 全量重跑);本轮所有规则只加在 M0 模板里

---

## 3. 链式影响提醒

- M0 bump → `structure_fingerprint` / `main_axis` / `core_loop` 变 → M1-M7 下游缓存键连带失效并重生成(既有行为,无需额外处理)
- M1/M2/M3 注入了 M0 字段。S1 第 8 条改了字段职责,需抽查 M1-M3 在样本盘上是否仍读得通(不要求改它们的模板)
- 不碰 `ten_god_weights` / `five_elements` 的计算与 chart 字段结构 → 不触发 context_token 守护栏。**如果实施中发现必须改,先停下问用户**

## 4. 实施记录(实施方填写)

> 实施方:Claude(jiexi worktree),2026-10-12。

- [x] S1 完成,commit:见本批 commit(m0 v7 三语 + PROMPT_VERSIONS 6→7 + translate 1→2)
- [x] S2 完成,commit:同上(evalkit/checks/grounding.py 六项 + tests/test_evalkit_grounding.py)
- [x] S3 结论:**翻译产物,已修 translate 层**。证据:主仓 backend SQLite `interpretation_cache` 中同 `content_hash`(d83aa2007e5e…)存在 en 行(2026-10-09 12:14 生成,prompt_version=2)与 zh 行(2026-10-12 12:05,即截图当日),逐句结构对应;en 源 `name` 原文即 `"Killings-and-Resource Converter (杀印相生格)"`——括注是 EN 生成侧(10-11 EN 质量批**之前**的 v2 模板)带的,译回 zh 时译名与括注重复产出「杀印相生格(杀印相生格)」;evidence 的 `five_elements: Water 0…` 裸字段名同样是 EN v2 时代泄漏被忠实搬运。修复:translate v1→v2 三语补两规则(①译名与括注相同时删括注 ②字符串值不得保留源语言机器字段名,按含义译)。生成侧根因由 S1 v7 一并收口(EN v7 同步禁格名/字段名/加括注禁令)
- [x] S4 方案:见下方 S4 实施方案(待用户拍板)
- 样本盘实跑 3 次 M0 输出:出生 `1987-01-21T08:00:00+08:00` male(引擎确认丙寅辛丑庚午庚辰,七杀6=劫财6 并列最重,水0木1,偏旺)。三次均 L1+L2 PASS;原始 JSON 暂存 `/tmp/m0_sample_runs/run{1,2,3}.json`(会话产物,不入库)。逐条对照第 1 节:A1(名字:硬扛聚能型/借压定型型/压力内收型,无格名无括注)✓ A2(比劫按负担/分流/自我复制框架讲,run2 明写「比劫本身是负担」)✓ A3(并列最重三次都同处 dominant 并写明)✓ A4(无箭头)✓ A5(无字段名)✓ B1(无地支五行错置)✓ B2(无跨类归类)✓ B3(无「坐」误用)✓ B4(正印/偏印三次都双提)✓ C1(「藏而不透/未透出」措辞+口径声明生效)✓ D1(短板全部引用真实大运壬寅5/癸卯15/甲辰25/乙巳35+当下出路)✓ D2(zh 直出无翻译腔)✓ D3(大幅改善:「吸入强输出弱」四连删;残余:run1/run3 的 capability_source 尾部仍轻提输出端弱——语义级,机器不可判,留给后续 prompt 迭代)△ D4 ✓
- evalkit 结果:**两轮全量真实 run(20 盘 × 8 模块,glm-5.2,带 L3 裁判)**。第一轮(20261012T133438)FAIL(41/12)→ 分诊出本批判据 bug 五处(geju 满格/正格白名单、A3 家族分层误报改层领衔权重比对、全角分号/！？切句缺失、judge 维度名漂移+数字串分值、补水词义歧义否决)+ v7 缺从格条款,修后重跑;第二轮(20261012T161603,判据终态)FAIL(33 fail + 10 error,pass 22 / warn 95)。**m0 自身验证通过**:geju 外泄/分层失真/字段名外泄/从格编造喜忌/隐藏降级 **全部归零**(上轮 m0 9 fail → 3);剩余 3 条 m0 fail = 2×「绝对」禁词(temp 0.3 随机,共享 header 既有规则的 L1 噪声类)+ 1×flow 双箭头(A4 检查正确命中 LLM 违约,判据工作正常)。其余 40 条非 pass 全部为本批未动的 m1-m7 既有类别:special_pattern 指令缺口 13(m1-m7 模板从未含诚实告知指令,suffix 只挂 bazi_deep 家族——S5 范围外,后续模板 bump 时补)、禁词 8、JSON 解析失败连锁 14、裁判网络瞬断 1、单例(链式改写/喜忌隐喻误报各有 1-2)。**结论:退出码非 0 属「无基线下的首轮真实 run」常态(CLAUDE.md 明文:首轮基线+L2 全量复核属真人步骤);本批引入的检查在 m0 上零误报零漏报,v7 模板质量目标全达**。**2026-10-13 用户拍板:20261012T161603 已设为 BASELINE**(d4d576f,run 数据拷入主仓 evalkit/runs/ 供缓存复用;后续 run 进入「对比判」阶段,33 条既有 fail 成为 still_failing 基准,只拦 regressed)
- 偏离本 plan 的地方及理由:
  1. **版本号 v6→v7 而非 v5→v6**:plan 基点 origin/main(55e43b2)m0=v5;实施基点本地 main(4fa04a8,领先 origin 6 commit)已在 10-11 EN 质量批把 m0 bump 到 v6(zh 内容未动)。按守护栏「改模板必须 bump 当前版本」,本批在 v6 基础上 bump 至 v7;plan 中「v5 保留不动」相应为「v6 保留不动」
  2. evalkit 新检查五项(A3/A4/A5/B1/B2)**仅对 m0_structure 生效**(A1 格名模式扩到全模块):zh m1-m7 模板尚未含机器字段名禁令等规则(plan S5 范围外),全开会把旧模板的概率性泄漏放大成 evalkit fail 且本批无法修复;m1-m7 模板补齐规则时再放开(代码注释已留说明)
  3. S2 复合格名白名单比 plan 草稿多收「常格」等:special_pattern 诚实降级措辞「不入常格」是 `_HONEST_WORDS` 认可的输出,不白名单会误杀(单测锁死)
  4. **双 review 循环(10-12)对 S2 的修正**(都属「宁可漏报」收紧误报面,非语义改动):①`_GEJU_RE` 加负向前瞻排除「格局/格式/格外/格调/格子…」——plan 点名的这三四个白名单词是格字**开头**词,`token.endswith` 结构性救不了,实测「这个格局偏流动/输出格式很干净」全误报;②「从格」进后缀白名单且**仅 special_pattern 盘放行**(suffix 模板明文要求从格盘写「从格特征」,20 盘语料 5 盘,无条件放行会让普通盘讲错身强身弱漏拦,无条件拦截会大面积假红);③后缀白名单补「出格/九宫格」;④`_BRANCH_COLON_RE` 停止类补全角「；！？」(否则「土支:丑辰；火支:巳午」把巳午吞进土支 → 误报);⑤模式层 token 同 leaf 去重;⑥prompts.py v7 版本注释「偏印 4」笔误改 3。回归测试 12 条新增全绿(8 反例参数化 + 4 独立用例)
  5. **全量 run 分诊追加修正**(两轮 run 实测,同属误报面收紧):①A3 分层比对从「dominant 提及十神最低权重」改「层领衔十神(最高权重)」——LLM 按十神家族分层是正当命理实践,家族内低权重神是叙事说明;②「满格/掉格/正格」白名单(电池条/从格否定语域);③`_SENTENCE_SPLIT` 补全角；！？(原集合半角重复 bug);④信号词-五行 gap 排除开括号(「回补(水行计数0」非推荐);⑤「补」进水的非五行前缀(补水=饮水/流动性隐喻,宁可漏报);⑥judge 维度名分隔符漂移容错+数字串分值转 int(裁判输出格式漂移不得毁掉生成侧结论,碰撞/真未知维度仍 raise)
  6. **v7 模板追加从格条款**(第一轮 run 发现:⑦短板配条件指令在从格盘被 LLM 写成「补水」撞编造喜忌判据):喜忌为空须诚实告知一次+大运条件句只作观察禁「补X/宜X」推荐措辞,三语同步;第二轮 run 验证 m0 从格 5 盘全部归零
  7. **S4 用户拍板方案 A 并实施**(超出 plan 原定「仅出方案」范围,用户 10-13 明示选择):M0 章 iOS 行内标签段落化——ChapterContent 新增 m0Nodes 特化组装(inlineLabel/loopFromTo/evidenceFold 三节点,固定阅读序,缺 main_axis/core_loop 回落通用渲染)+ ChapterContentView 三样式(段首行内标签/起止一行小字/章末「据」折叠区,零新增 xcstrings key,无新文件无 pbxproj 登记)+ ChapterReadingView 传 module;ChapterContentTests 17/17 绿

### S4 实施方案(待拍板,三选一)

> 现实前提变化:S1 v7 后 dominant/secondary/latent 的值已是**完整长句**(带权重依据),不再是十神名短语——plan 原草案「合成一行『主导 七杀 · 次要 正印 · 潜伏 伤官』」不再可行,方案按新现实出。

**方案 A · 行内标签段落化(轻,推荐)**
- main_axis 三行去掉逐行 caption 小标签,改为段首行内标签:「主导——{长句}」楷体连排,三层一段接一段,像书页小节;core_loop 的 from/to 两行合成为一行小字「循环自 X,行至 Y」(不再两个孤立标签行),flow/driver/leak 照旧但同段式处理;四组 evidence 从各小节中抽出,收拢为章末一个「据 ·」折叠区(默认收起,轻触展开)
- 改动面:仅 `ChapterContent.swift`(M0 特化组装,按 module 分流)+ `ChapterContentView.swift`(行内标签行样式);无新文件,无 pbxproj 登记;不动后端/schema;M1-M7 渲染零变化
- 风险:ChapterContent 通用映射逻辑要多一条 M0 分支,长期是特例债

**方案 B · M0 专用整章渲染器(中)**
- 新建 `M0ChapterView.swift`:M0 章不走通用节点树,直接消费原始 JSON——主线整段散文(三层句子连续、十神名行内加粗)+ 循环段自然段(flow/driver/leak 各成段,小节题照旧)+ 据/章末折叠;排版自由度最高(可做「墨圆起止」的品牌指纹)
- 改动面:新 .swift(pbxproj 4 处登记 24 位 ID)+ `ChapterReadingView` 分流;`ChapterContent.swift` 不动
- 风险:双渲染路径,M0 的 schema 若再变要同步两处;新文件登记是已知坑(漏登记=静默不编译)

**方案 C · 模板侧章节化(重,不推荐)**
- 后端 M0 schema 改成 prose 化字段(main_axis 合成整段散文输出)——动 prompt/evalkit/缓存链,v7 刚定稿即推翻,连锁成本高,仅当 A/B 都不满意再议

建议:A 起步(一小时级改动,不碰契约),TestFlight 真机读感不行再升 B。

## 5. Review 清单(Claude review 时逐条核)

- [x] 第 1 节 A1-A5、B1-B4、C1、D1-D4 每条在新输出里消失,或有机器校验兜底(样本盘 3 次实跑见第 4 节;A1/A3/A4/A5/B1/B2 另有 evalkit 机器校验兜底;A2/D3/D4 prompt 规则层兜底,plan 未要求机器化)
- [x] 三语 v7 模板语义对齐(diff 逐行核过:v6 内容零删失、纯增量),zh-hant 用词符合 v6 既有惯例(藏干/七殺/財星 与 `term_translations.py` 一致)
- [x] `PROMPT_VERSIONS` bump 有注释,v6 文件未被修改(git status 无模板文件改动)
- [x] 新 evalkit 检查有正例 + 日常词反例单测,无误报(review 双循环又补 12 条用例:格局/格式/格外/出格/九宫格/从格双态/全角分号排比等)
- [x] `check_prompt_sync.py` / `test_i18n.py` / `test_v1_prompt_render.py` / `test_evalkit_*.py` 全过(1255 绿);BASELINE 未被改。`evalkit.runner` 全量 run 由本批后台承担,review 会话不跑(守护栏:避免与后台 run 撞 runs/)
- [x] 未改 context 字段结构、未动 iOS UI(S4 仅方案)、未加新依赖
- [ ] commit 符合三段式(Why / What / Impact)——由主会话 commit 时落实
