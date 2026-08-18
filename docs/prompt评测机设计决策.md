# Prompt 回归评测机(evalkit)设计决策

Generated on 2026-08-17
Status: **ACCEPTED**(2026-08-17,待实施;slice 明细见 `docs/prompt评测机-slices/`)
关联文档: `bazi-app-design-doc.md` / `命理引擎设计决策.md` / `DESIGN.md` / `CLAUDE.md`(红线:确定性 / LLM 只润色不判断 / 错误显式传播 / 不擅自加依赖)
关联 ADR: `docs/adr/0004`(喜忌确定性)/ `0005`(神煞 20 固定清单)/ `0006`(格局砍掉模糊叙事)/ `0007`(从格诚实降级)/ `0009`(AI 两级缓存)/ `0010`(AI provider 单选无 fallback)

## 背景(现状审计结论)

QiCompass 是**确定性排盘 + LLM 叙事**的混合结构。两层的回归保护严重不对称:

- **排盘层**:30 用例对盘(库层 20 + 封装层 10)+ `test_xiji.py` / `test_shensha.py` / `test_pillars.py` 等,改动即刻有信号
- **叙事层**:**零回归保护**。改一次 `app/ai/prompts.py` 的模板,无法回答"哪几盘变好了、哪几盘悄悄退化了",全靠人肉抽看

这正是混合结构最容易出的故障模式:**改好了 A 场景,悄悄搞坏了 B 场景**。

### 已有零件盘点

`backend/spikes/prompt_validation/` 已有约 70% 的零件,但定位是"一次性脚本(不进生产)":

| 能力 | 位置 | 状态 |
|---|---|---|
| 20 盘固定输入 | `spikes/prompt_validation/fixtures.py` | **完好**:15 普通盘(四季 × 强弱)+ 2 专旺 + 3 从格,含配额断言 |
| 链式生成 | `run_v1_chain_spike.py` | **完好**:M0→M7 依赖图注入 + 逐模块落盘 + `--dry-run` |
| 确定性校验 | `run_v1_chain_spike.py:195 validate_v1_module_output()` | **完好**:必填字段 + 数组长度 + `structure_fingerprint` ≤40 字 + 双层禁词 |
| 生产禁词守卫 | `app/ai/forbidden_words.py` | **完好**:`scan()` / `validate_interpretation()`,命中即拦截不替换(D10) |
| 7 维评分 rubric | `spikes/prompt_validation/eval_prompt.md` | **只是文档,无代码调裁判** |
| 报告骨架 | `spikes/prompt_validation/report_template.md` | **只是模板,靠手填** |
| 跨版本对比 | — | **不存在** |
| Web UI | — | **不存在** |

### 两个审计发现(必须写进实施约束)

1. **`run_spike.py` 从未真跑过,且真跑会失败**。`run_spike.py:298` 同步调用 `ai_client.interpret(...)`,但该方法在 `app/ai/client.py:22` 是 `async def`——返回的是 coroutine 对象,存进 `result_entry` 后被 `json.dumps` 炸掉,落进外层 `except`。证据:`output_v1/results.jsonl` 全部 20 行 `"llm_response": null` 且 `"request_duration_ms": 0`,即只跑过 `--dry-run`。
   该脚本服务老 3 模块,属本系列范围外——**只在其 docstring 顶部标注失效,不顺手改**(避免范围蔓延)。

2. **`run_v1_chain_spike.py` 是后写的(Stage 6),async 用法正确**(`await ai_client.interpret(...)`,`asyncio.run()` 入口),是应该被提炼演进的那条线。

### 目标

把 spike 提升为常驻评测机 `backend/evalkit/`,补上**LLM 裁判 + 跨 run 对比 + 本地 Web UI** 三块。改完 prompt 跑一次,网页上直接看到"相对上一版,哪几盘哪几维退化了"。

## 决策汇总

| # | 决策点 | 结论 |
|---|---|---|
| Q1 | 范围 | 只接 **v1 链式 M0-M7**(8 模块 JSON 输出);老 3 模块二期,`checks` 层按 module-agnostic 设计不返工 |
| Q2 | 落点 | spike 提升为 `backend/evalkit/`;**独立本地 FastAPI app,不碰 `app/main.py`**,不进生产镜像 |
| Q3 | 判据分层 | **L1 确定性 / L2 接地 / L3 LLM 裁判** 三层,越往上越贵;新失败模式优先下沉到 L2 |
| Q4 | 裁判配置 | 独立 `JUDGE_PROVIDER` / `JUDGE_MODEL` / `JUDGE_API_KEY`,默认回落现有 `AI_*`;复用 `create_ai_client()`,**不新写 HTTP client** |
| Q5 | Run 身份 | `(prompt_versions 快照, provider, model, rubric_version, judge_model, cases_hash)`;任一维变了即新 run |
| Q6 | 成本控制 | 响应缓存键含**渲染后 prompt 的 sha256 + 上游注入内容**;只改 M5 → 只重跑 M5 及下游 M7 |
| Q7 | 基线与 diff | `runs/BASELINE` 单行 run_id **进 git**,`runs/*/` 其余 gitignore;diff 四分类 regressed / fixed / still_failing / unchanged |
| Q8 | UI | vanilla HTML/JS 单页,零构建零新依赖;退化清单置顶 + 20×8 矩阵;遵循 `DESIGN.md` 色板 |
| Q9 | 落地 | S01-S06 vertical slice;CLAUDE.md 增补守护栏(动 M0-M7 模板必跑 evalkit 且无 regression) |

---

## Q1 范围:只接 v1 链式 M0-M7

v1 prompt 系统(`PROMPT_VERSIONS` 里 `m0_structure` ~ `m7_manual`)输出**结构化 JSON**,机器可判的部分远多于老 3 模块的散文输出,回归信号最强;且 `validate_v1_module_output()` 已经存在,起步成本最低。

- **包含**:M0-M7 共 8 模块,20 盘全量 = 160 次 LLM 调用/轮(靠 Q6 缓存把重复轮次的成本压到只跑改动模块)
- **不做**:老 3 模块(`bazi_deep` / `compatibility` / `daily_fortune`)。它们是散文输出,几乎全靠 L3 裁判打分,确定性检查只剩禁词,性价比低
- **约束**:`checks/` 层签名必须 module-agnostic(入参 `(module, parsed_output, engine_result)`),二期接老 3 模块时不返工

## Q2 落点:独立 `backend/evalkit/` + 独立本地服务

从 `spikes/`(一次性)提升为 `evalkit/`(常驻),目录:

```
backend/evalkit/
  __init__.py
  cases.py            # 20 盘 fixture(迁自 spikes/prompt_validation/fixtures.py)
  runner.py           # 编排:排盘 → 链式生成 → L1/L2/L3 → 落盘
  checks/
    __init__.py
    deterministic.py  # L1
    grounding.py      # L2
  rubric.py           # L3 rubric 模板 + RUBRIC_VERSION
  judge.py            # L3 裁判 client + 调用 + 严格 JSON 解析
  store.py            # run 持久化 + 响应缓存 + 跨 run diff
  server.py           # 本地 FastAPI app(独立于 app.main)
  static/index.html   # 单页 UI
  runs/               # 结果目录(gitignore,除 BASELINE)
```

**为什么不挂进生产 app**:评测路由与生产路由同进程会带来"dev 开关漏关"的泄漏风险,且评测跑批会占用生产 app 的事件循环。独立 app 起在 `127.0.0.1:8899`,不进生产镜像,泄漏面为零。

**代价**:起服务多一条命令(用 `eval.sh` 包一层)。可接受。

## Q3 判据分层:L1 确定性 / L2 接地 / L3 裁判

评测机的价值取决于**尽可能多的判据是确定性的**。LLM 裁判贵、慢、且自身会漂移,只应兜底真判不了的部分。

> **立场**:L2 每从 L3 抢走一条判据,评测就便宜一分、稳一分。新发现的失败模式优先想办法沉到 L2,实在判不了才留在 L3。

### L1 确定性(不花钱,必跑)

直接复用 `validate_v1_module_output()`,不重写:

- JSON 可解析(`parse_llm_json()` 处理 markdown code fence 包裹)
- 必填顶层字段齐(`_MODULE_REQUIRED_FIELDS`,如 `m0_structure` 需 `main_axis` / `core_loop` / `structure_type` / `capability_source` / `structure_fingerprint`)
- 数组长度**精确**匹配(`reset_7day` 必须 7 条、`environment_checklist` 必须 5 条、`use_cases` 必须 3 条等)
- `structure_fingerprint` 非空且 ≤40 字
- 双层禁词:生产 `ABSOLUTE_CONCLUSIONS` + v1 §4 扩展词表

### L2 接地(不花钱,本次最有价值的新增)

把"编造"从"要靠裁判读出来"变成"机器直接判死"。五类:

| 校验 | 判据 | 对齐 |
|---|---|---|
| **喜忌一致性** | 输出中的五行推荐不得与 `engine_result["favorable_elements"]` / `["unfavorable_elements"]` 矛盾 | ADR-0004、CLAUDE.md「LLM 只润色不判断」 |
| **神煞不超界** | 输出中出现的神煞名 ⊆ `SHENSHA_NAMES`(20 固定清单)∩ 本盘 `engine_result["shensha"]` 实际命中项 | ADR-0005 |
| **格局红线** | 扫"正官格 / 偏印格 / 七杀格 / 伤官格"等硬分类,命中即 fail | ADR-0006、CLAUDE.md「只准命局呈现××倾向」 |
| **special_pattern 诚实** | 5 个特殊盘上 `favorable_elements` 为空时不得编造喜忌,且须出现"不入常格"类表述 | ADR-0007 |
| **链式一致性** | M1-M6 上下文里注入的 `structure_fingerprint` 逐字等于 M0 产出;M7 引用的 M1/M2/M3/M6 字段同理 | v1 链式设计 |

神煞清单**从 `app/engine/shensha.py:240 SHENSHA_NAMES` 取,不复制第二份**——复制即引入第二事实源,与城市搜索系列的「单一事实源」红线同理。

### L3 LLM 裁判(花钱,可 `--skip-judge`)

把 `spikes/prompt_validation/eval_prompt.md` 的 7 维 rubric 代码化,只判 L1/L2 判不了的:术语准确性 / 是否读着像算命软件 / 行文是否有洞察。

- 输入:ground truth(喜忌 / 五行统计 / 神煞 / 大运流年 / 从格特征)+ LLM 输出
- 输出:严格 JSON(`scores` / `overall` / `failures` / `passed`)
- **JSON 解析失败显式报错,不给默认分**——给默认分正是 CLAUDE.md「用默认值掩盖失败」的反面教材
- rubric 带 `RUBRIC_VERSION`,rubric 改必 bump;**老分数不与新分数比**(同 `PROMPT_VERSIONS` bump 让缓存自然失效的思路)

**裁判本身需要被校准**:S05 验收强制人工过一遍评分——若裁判给明显编造的输出打高分,先修 rubric 再谈基线。

## Q4 裁判配置:独立 env,可跨 provider

`app/config.py` 尾部追加(沿用现有 `os.environ.get(...) or 默认` + 空值显式 raise 写法):

```
JUDGE_PROVIDER   默认 = AI_PROVIDER
JUDGE_MODEL      默认 = 对应 provider 的默认模型
JUDGE_API_KEY    默认 = 对应 provider 的 key
```

- **为什么独立**:同模型自评有系统性偏袒;独立配置才能"用更强的模型当裁判",也才能做「Anthropic 生成 / OpenAI 裁判」的交叉验证
- **裁判身份进结果记录**:换裁判 = 换一批分数,不与旧分数混比
- **复用 `app/ai/client.py:create_ai_client()`**,只喂不同参数,不新写 HTTP client
- ADR-0010「AI provider 单选无 fallback」在评测侧同样适用:judge provider 也是单选,不做 fallback

## Q5 Run 身份:六维元组

一次 run 由 `(prompt_versions 快照, provider, model, rubric_version, judge_model, cases_hash)` 定义。任一维度变了就是新 run,不混淆。

`meta.json` 记录完整身份 + 起止时间 + 调用次数 + 缓存命中数 + 总耗时。

**为什么 `prompt_versions` 存整份快照而非单个版本号**:链式调用里 M7 的质量受 M1-M6 全部影响,只记 M7 自己的版本号无法解释它为何变化。

## Q6 成本控制:响应缓存

20 盘 × 8 模块 = 160 次调用/轮。若每次改 prompt 都全量重跑,经济上不可持续——**缓存是"每次改 prompt 都跑一遍"这件事成立的前提**。

`runs/.cache/<sha256>.json`,键 =

```
(case_id, module, prompt_version, provider, model, 渲染后 prompt 的 sha256, 上游注入内容)
```

含「渲染后 prompt 的 sha256」而非只含 `prompt_version`,理由同 `app/ai/cache_key.py` 的 `prompt_hash` 维度:防止同 `content_hash` 不同 context 污染。含「上游注入内容」是链式特有——M0 输出变了,M1-M7 的缓存必须失效。

效果:只改了 M5 的模板 → 只重跑 M5 及其下游 M7,其余 6 模块全部命中缓存。

`--no-cache` 强制全量重跑(换模型、验证温度抖动时用)。

## Q7 基线与 diff

`store.py` 给定 `baseline_run_id` 与 `current_run_id`,按 `(case_id, module)` 对齐,产出四分类:

| 分类 | 含义 | UI 位置 |
|---|---|---|
| `regressed` | baseline pass → current fail | **首屏置顶,朱砂红**。这是整个工具存在的理由 |
| `fixed` | baseline fail → current pass | 次要区域,墨青 |
| `still_failing` | 两边都 fail | 折叠区 |
| `unchanged` | 两边都 pass | 只计数 |

`runs/BASELINE` 单行文本记当前基线 run_id,**进 git**(团队/多机共享同一基线);`runs/*/` 其余内容 gitignore(体积大且可重生成)。

## Q8 UI:vanilla 单页

`evalkit/static/index.html`,零构建零新依赖(fastapi / uvicorn 已在 `backend/requirements.txt`)。四块:

1. **顶部**:run 选择器(current vs baseline)+ 总览(通过率 / 退化数 / 缓存命中 / 成本 / 耗时)
2. **退化清单**:`regressed` 置顶。空时显示"无退化"
3. **矩阵**:20 行(case)× 8 列(module)色块网格。**一眼分辨"某一盘全崩"还是"某个模块全崩"——这两种失败的修法完全不同**(前者是 fixture 边界问题,后者是模板问题)
4. **详情抽屉**:点格子展开,左 rendered prompt / 右 response JSON / 下 L1L2L3 逐条判据 + 与 baseline 并排 diff

视觉遵循 `DESIGN.md`:`#FDFCFA` 背景 / `#EBE3D0` 卡片 / `#C33B3B` 朱砂标退化 / `#2C5F3F` 墨青标通过 / 4pt 圆角 / 0.5pt hairline / **禁渐变** / 系统字体不打包。内部工具不追求精致,但不违反设计系统。

## Q9 落地:S01-S06

见 `docs/prompt评测机-slices/`。收尾时 CLAUDE.md 增补守护栏:动了 `app/ai/prompts.py` 的 M0-M7 模板 → 必须跑 evalkit 且无 regression。沿用现有「本地优先、不接 GitHub Actions」的约定(2026-08-14 决定),拦截靠规则不靠 CI。

---

## 不做(明确砍掉)

| 项 | 理由 |
|---|---|
| 老 3 模块接入 | 二期。散文输出确定性检查只剩禁词,性价比低 |
| 多裁判投票 / 置信区间 / 显著性检验 | 20 盘规模下过度设计。先让单裁判跑起来 |
| GitHub Actions | 对齐 2026-08-14「用户工作流本地优先」决定 |
| 扩展生产禁词表 | `run_v1_chain_spike.py:185` 注释已说明是独立决策,扩了会影响老 module |
| 自动 bump `PROMPT_VERSIONS` | 评测机只读。bump 是人的决定 |
| 评测路由进生产 app | 见 Q2 |
| 修 `run_spike.py` 的 async bug | 老 3 模块脚本,本系列范围外。只标失效 |
| 新增任何依赖 | fastapi / uvicorn / httpx / pytest 全部已在 `backend/requirements.txt` |
