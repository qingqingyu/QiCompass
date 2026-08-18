# S04 run 持久化、响应缓存与跨 run diff

- **类型**: AFK
- **Blocked by**: S02、S03
- **覆盖决策**: Q5(run 身份)、Q6(成本控制)、Q7(基线与 diff)
- **Parent**: `docs/prompt评测机设计决策.md`

> 没有 diff,评测机只能回答"现在好不好";有了 diff,才能回答"**相比上一版,哪几盘退化了**"——后者才是回归测试。

## What to build

`backend/evalkit/store.py`,四件事:run 身份、落盘、响应缓存、跨 run diff。

### 1. Run 身份(Q5 六维)

```python
@dataclass(frozen=True)
class RunIdentity:
    prompt_versions: dict[str, int]   # PROMPT_VERSIONS 中 m0-m7 的整份快照
    provider: str
    model: str
    rubric_version: int               # S05 前固定为 0(未接裁判)
    judge_model: str                  # S05 前固定为 ""
    cases_hash: str                   # S01 的 CASES_HASH
```

- `run_id` = 时间戳 + 身份摘要短 hash,如 `20260817T1432-a3f9c1`(时间戳保证可排序,hash 保证同身份可辨认)
- **存整份 `prompt_versions` 快照而非单个版本号**:链式调用里 M7 的质量受 M1-M6 全部影响,只记 M7 自己的版本号无法解释它为何变化

### 2. 落盘布局

```
backend/evalkit/runs/
  BASELINE                     # 单行 run_id,进 git
  .cache/<sha256>.json         # 响应缓存,gitignore
  <run_id>/
    meta.json                  # RunIdentity + 起止时间 + 调用数 + 缓存命中数 + 总耗时
    results.jsonl              # 每行一个 (case, module)
    case_00/m0_structure/prompt.txt | response.json | checks.json
```

`results.jsonl` 每行:

```jsonc
{
  "case_id": "case_00", "module": "m0_structure",
  "category": "normal", "expected_strength": "balanced",
  "prompt_version": 1, "provider": "...", "model": "...",
  "l1": {"passed": true,  "failures": []},
  "l2": {"passed": false, "failures": ["神煞越界:文本提及「天医」,不在 SHENSHA_NAMES(原文:...)"]},
  "l3": null,
  "verdict": "fail",
  "cached": false,
  "elapsed_ms": 3120,
  "error": null
}
```

**`verdict` 判定**(S04 版本,S05 接入裁判后补 warn 分支):
- `l1` 或 `l2` 任一 `passed == false` → `"fail"`
- `error` 非空 → `"error"`(与 fail 区分:一个是质量问题,一个是跑挂了)
- 否则 → `"pass"`

### 3. 响应缓存(Q6,成本控制的关键)

20 盘 × 8 模块 = 160 次调用/轮。全量重跑每一次 prompt 改动在经济上不可持续——**缓存是"每次改 prompt 都跑一遍"这件事成立的前提**。

缓存键 = 下列各项的规范化 JSON 的 sha256:

```
(case_id, module, prompt_version, provider, model,
 渲染后 prompt 的 sha256, 上游注入内容的 sha256)
```

- 含**渲染后 prompt 的 sha256** 而非只含 `prompt_version`:理由同 `app/ai/cache_key.py` 的 `prompt_hash` 维度——防止同 `content_hash` 不同 context 污染
- 含**上游注入内容**:链式特有。M0 输出变了,M1-M7 缓存必须全部失效
- 缓存**只存 LLM 原始响应文本**,不存判据结果——判据代码改了要能重算而不重新烧钱。这是本设计的关键取舍
- `--no-cache` 强制全量重跑(换模型、验证温度抖动时用)
- `meta.json` 记录缓存命中数,CLI 摘要打印"本轮 N 次调用,M 次命中缓存"

**验收效果**:只改 M5 模板 + bump `PROMPT_VERSIONS["m5_wealth"]` → 只重跑 M5 及下游 M7,其余 6 模块全部命中。

### 4. 跨 run diff(Q7)

```python
def diff_runs(baseline_run_id: str, current_run_id: str) -> DiffResult
```

按 `(case_id, module)` 对齐,四分类:

| 分类 | 含义 | 处理 |
|---|---|---|
| `regressed` | baseline `pass` → current `fail`/`error` | **首屏置顶**。工具存在的理由 |
| `fixed` | baseline `fail`/`error` → current `pass` | 次要展示 |
| `still_failing` | 两边都非 pass | 折叠 |
| `unchanged` | 两边都 pass | 只计数 |

- baseline 有而 current 没有的键(如 current 用了 `--modules` 子集)→ 归入 `skipped`,**不计入 regressed**(否则跑子集会误报一片红)
- current 有而 baseline 没有的键(新增模块/新增盘)→ 归入 `new`
- 两个 run 的 `RunIdentity` 差异一并返回,UI 上提示"本次对比跨了 model 变更"这类混淆因素

### 5. CLI 接线

- `python -m evalkit.runner` 跑完自动与 `runs/BASELINE` 对比,摘要打印四分类计数
- **有 `regressed` → 退出码 1**;无退化 → 0;脚本自身错误 → 2
- `python -m evalkit.store --set-baseline <run_id>` 设定基线
- `python -m evalkit.store --diff <baseline> <current>` 独立跑 diff

## Acceptance criteria

- [ ] `store.py` 建成:`RunIdentity` / run 落盘 / 缓存读写 / `diff_runs()`
- [ ] `meta.json` 含完整六维身份 + 调用数 + 缓存命中数 + 总耗时
- [ ] `results.jsonl` 格式如上,`verdict` 三态(pass/fail/error)判定正确
- [ ] 缓存**只存原始响应文本**;删掉 `checks/` 的判据结果后重跑,零 API 调用即可重算全部判据
- [ ] 缓存键含渲染后 prompt hash + 上游注入内容(改 M0 → M1-M7 全部 miss)
- [ ] `--no-cache` 强制全量
- [ ] `diff_runs()` 四分类 + `skipped` + `new` 正确;跑 `--modules` 子集**不误报 regressed**
- [ ] 有退化时 CLI 退出码 1,无退化 0,脚本错误 2
- [ ] `--set-baseline` 写入 `runs/BASELINE`;`.gitignore` 规则确认(runs/ 忽略但 BASELINE 例外)
- [ ] 单测全绿(见「测试」),**零 API 调用**
- [ ] `pytest backend/tests/` 全绿

## 实现锚点(现状快照 2026-08-17,实施以代码为准)

- `backend/app/ai/cache_key.py` — **缓存键设计的参照系**。生产用 frozen dataclass 收敛十维度身份,注释解释了为何要 `prompt_hash`(防同 content_hash 不同 context 污染)与 `parent_hash`(链式隔离)。evalkit 缓存键沿用同一思路,但**独立实现,不复用生产 `CacheKey`**(维度不同:evalkit 多 case_id,少 target_date/language/entitlement)
- `backend/app/ai/cache.py` — 生产两级缓存(SQLite),**本 slice 不用**,evalkit 缓存是独立的文件缓存
- `backend/app/ai/prompts.py:39 PROMPT_VERSIONS` — 身份快照取 `m0_structure` ~ `m7_manual` 八项
- `backend/evalkit/cases.py` — S01 产出的 `CASES_HASH`
- `backend/evalkit/runner.py` — S01 产出,本 slice 接线
- `tools/check_prompt_sync.py` — 退出码约定参考(0 PASS / 1 FAIL / 2 脚本自身错误)
- `.gitignore` — S01 已加 `backend/evalkit/runs/` + `!.../BASELINE` 例外,本 slice 确认生效

## 红线与约束

- **确定性**:`run_id` 含时间戳但身份 hash 只由六维决定;同身份连跑两次,除时间戳外 `meta.json` 一致
- **缓存不缓存判据**:判据代码是会频繁改的,缓存了就等于每次改判据都要重新烧钱。只缓存 LLM 原始响应
- **错误显式传播**:缓存文件损坏 → 显式报错并指出文件路径,**不静默当 miss 重新调 API**(静默重调会悄悄烧钱);`BASELINE` 指向不存在的 run → 显式报错
- **跑子集不误报**:`--modules` / `--case-limit` 子集 diff 归 `skipped`,这是防止"人被红色淹没后开始无视红色"的关键
- **不碰生产**:不复用也不修改 `app/ai/cache.py` / `cache_key.py`
- **不擅自加依赖**:文件缓存用标准库 `json` + `hashlib` + `pathlib`,不引 diskcache 之类

## 测试

新增 `backend/tests/test_evalkit_store.py`,**用构造的 jsonl,零 API 调用**:

- `RunIdentity` 同六维 → 同身份 hash;任一维变 → 不同 hash(逐维参数化)
- diff 四分类:构造 baseline/current 两份 jsonl 覆盖 regressed / fixed / still_failing / unchanged 各至少一条
- `skipped`:current 缺某些 `(case, module)` → 归 skipped,**`regressed` 为空**
- `new`:current 多出某些键 → 归 new
- 缓存:写入后同键命中、改 prompt hash 后 miss、改上游注入内容后 miss
- 缓存文件损坏(写入非法 JSON)→ `pytest.raises`,不静默 miss
- `BASELINE` 指向不存在 run → `pytest.raises`

手工验收(需 API key,S05/S06 前可选):跑一轮 → 改一个模块的模板 + bump 版本 → 重跑,确认 CLI 摘要显示"仅 2 次调用(M5、M7),6 次命中缓存"。
