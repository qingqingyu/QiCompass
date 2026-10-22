# 模型选型 A/B 评测 · 执行手册

> **给执行者(另一个 AI)**:本文是一份完整的执行任务。按顺序做,遇到「停止条件」立即停下并报告,**不要自行变通**。
> 执行结果会交给另一位评审者(Claude)做 review 与最终评判——所以**原始数据比你的结论重要**,宁可多交原文,不要只交总结。
>
> 起草:2026-10-22 · 仓库:QiCompass(`backend/evalkit/`)· 本手册的 dry-run 路径(简体 160 条 + en / zh-hant 抽查脚本各 32 条)已在起草时实测通过

---

## 0. 背景(一段话读懂要做什么)

QiCompass 是一个八字命理 iOS App。后端用 LLM 把**确定性引擎算好的命盘**润色成命书(v1 链式 8 个模块 M0-M7)。当前生产用 **GLM**(经 z.ai 的 Anthropic 协议中转)。用户想知道「要不要换模型」。

仓库里有一个现成的 prompt 回归评测机 `backend/evalkit/`:固定 20 个命盘 × 8 模块 = 160 次生成,三层判据:

- **L1 确定性**:JSON 结构 / 必填字段 / 长度等
- **L2 接地**:输出是否违背引擎的事实(擅自推断喜忌、下「正官格」之类硬格局结论、从格盘没诚实降级、神煞写错……)
- **L3 裁判**:另一个 LLM 按 7 维 rubric 打 1-5 分(**只评 L1/L2 都通过的条目**)

本任务 = 用同一套 evalkit,让 **GLM** 和 **候选模型** 各跑一遍,再加一个小规模**英文 / 繁体**抽查(evalkit 本身只跑简体),把全部原始结果打包交回。

---

## 1. 硬性规则(违反任一条 = 本次结果作废)

1. **不改任何仓库代码与模板**:`backend/app/**`、`backend/evalkit/**`、`backend/app/ai/prompts/**` 一律只读。三语抽查用的脚本放在仓库**之外**(见 §4 Step 5)。
2. **不设基线**:不要运行 `python -m evalkit.store --set-baseline ...`,不要创建或修改 `backend/evalkit/runs/BASELINE`。定基线是用户本人的决定。
3. **不提交密钥**:`.env`、任何 API key 不得出现在提交、报告、日志摘录里。贴日志前先检查有没有 key 或带 key 的 URL。
4. **两边的裁判必须完全一致**:GLM run 和候选 run 用**同一个** `JUDGE_PROVIDER / JUDGE_MODEL / JUDGE_BASE_URL`。不一致,L3 分数就不能拿来对比。
5. **不合并到 main**:结果推到独立分支(§5),只推不合。
6. **如实报告**:报错、超时、JSON 解析失败都是有效数据,**原样记录,不要重跑到通过为止**。允许的重试只有一种:网络层失败(连接超时 / 5xx / 429)对同一条最多补跑一次,并在报告里注明。

---

## 2. 开跑前,需要用户本人提供的信息(填空)

> 执行者:下表任何一项为空,**先找用户问清,不要猜**。

| # | 项目 | 用户填写 |
|---|---|---|
| A1 | GLM 的**真实型号名**(z.ai 控制台上显示的,例如 `glm-x.x`) | |
| A2 | GLM 走的协议 + base URL(当前推测:Anthropic 协议,`https://api.z.ai/api/anthropic`) | |
| B1 | 候选模型:provider(`anthropic` 或 `openai` 兼容协议) | |
| B2 | 候选模型:型号名 | |
| B3 | 候选模型:base URL(官方留空;OpenAI 兼容网关填完整的 `/v1` 地址) | |
| J1 | 裁判:provider / 型号 / base URL | |
| $ | 预算确认:两个模型全量 run + 裁判 + 三语抽查约 **750 次 LLM 调用**(明细见 §6),用户同意花这笔钱 | ☐ 同意 |

**裁判怎么选(给用户的建议)**:最好**既不是 GLM,也不是候选模型的同一家**,避免「自己给自己打分」。实在做不到,就在报告里写明裁判与哪一方同家族,评审时会对 L3 打折。

**关于 A1(重要)**:`.env.example` 里 `ANTHROPIC_MODEL` 的默认值是 `claude-sonnet-4-6`,而 base URL 指向 z.ai。如果实际 `.env` 也这么写,请求虽然打到了 z.ai(实际由 GLM 生成),evalkit 和生产缓存记录的模型身份却是 Claude——**本次 GLM run 必须把 `ANTHROPIC_MODEL` 设成 A1 的真实型号名**。同时在报告里写明:用户当前生产 `.env` 的 `ANTHROPIC_MODEL` 实际值是什么(只写型号名,不写 key)。

---

## 3. 环境说明(执行者必读)

- 所有命令在 `backend/` 目录下执行。Python ≥ 3.11,依赖 `pip install -r requirements.txt`(仓库可能已有 `.venv`,有就用它)。用户本机是 Apple Silicon Mac,仓库其他文档用的写法是 `arch -arm64 .venv/bin/python`;本文统一写 `python`,按实际环境替换即可。
- 配置**在 import 时从环境变量读取**,所以每次 run 之前要在**同一个 shell** 里设好变量,不同模型之间开新 shell 或重新 `export`。
- 相关变量:

  | 变量 | 作用 |
  |---|---|
  | `AI_PROVIDER` | `anthropic` 或 `openai` |
  | `ANTHROPIC_API_KEY` / `ANTHROPIC_MODEL` / `ANTHROPIC_BASE_URL` | Anthropic 协议(z.ai 中转也走这组) |
  | `OPENAI_API_KEY` / `OPENAI_MODEL` / `OPENAI_BASE_URL` | OpenAI 兼容协议 |
  | `JUDGE_PROVIDER` / `JUDGE_MODEL` / `JUDGE_API_KEY` / `JUDGE_BASE_URL` | L3 裁判 |

- ⚠️ **裁判陷阱(必须避开)**:裁判走 `anthropic` 协议且**没设** `JUDGE_BASE_URL` 时,会回落到生成侧的 `ANTHROPIC_BASE_URL`。GLM run 里这个变量指向 z.ai,结果就是**裁判在不知不觉中变成了 GLM**。所以无论裁判走哪种协议,**都要显式 export `JUDGE_BASE_URL`**。如果裁判就是 Anthropic 官方,填 `https://api.anthropic.com`。
- 每个 run 的产物在 `--output-dir` 指定的目录下:
  ```
  <run_dir>/
    meta.json            # run 身份(provider / model / judge_model / prompt_versions / cases_hash)
    results.jsonl        # 每行一个 (case, module) 条目:verdict / l1 / l2 / l3 / elapsed_ms / error
    case_XX/chart.json   # 命盘输入
    case_XX/<module>/prompt.txt     # 渲染后的 prompt
    case_XX/<module>/response.json  # 模型输出(JSON 解析失败时不存在,失败原因在 results.jsonl)
  ```
- 退出码:`0` 全过 / `1` 有 fail、error 或退化 / `2` CLI 或配置错误。**退出码 1 是正常的评测结果,不是任务失败**,继续往下做;退出码 2 才需要停下排查。

---

## 4. 执行步骤

### Step 0 · 预检(零成本)

```bash
cd backend
( set -a; source .env; set +a; python -m evalkit.runner --dry-run )
```

> 后端启动时强制要求 `JWT_SECRET_KEY`(缺了会报 `ValueError: JWT_SECRET_KEY 必填`),所以**每条命令都要先加载 `backend/.env`**。`.env` 里已有就行,不需要改它。

预期:20 盘排盘 + 160 个 prompt 渲染全部成功、不调 AI。
**停止条件**:dry-run 报错 → 停,把完整报错交回(这说明仓库本身有问题,不是模型问题)。

同时记录:`git rev-parse HEAD` 的 commit、`ls evalkit/runs/`(是否已有历史 run;有的话**不要删**,也不要用)。

### Step 1 · 写两份 env 文件(放仓库外,不提交)

```bash
mkdir -p ~/qc-eval && chmod 700 ~/qc-eval
```

两份文件的**第一段都先加载 `backend/.env`**(拿到 `JWT_SECRET_KEY` 等非模型配置),再覆盖模型相关变量。

`~/qc-eval/glm.env`(按 §2 填):
```bash
set -a; source <repo 绝对路径>/backend/.env; set +a
export AI_PROVIDER=anthropic
export ANTHROPIC_API_KEY=<GLM key>
export ANTHROPIC_MODEL=<A1 真实型号名>
export ANTHROPIC_BASE_URL=<A2>
# 裁判(两份文件这几行必须一字不差)
export JUDGE_PROVIDER=<J1>
export JUDGE_MODEL=<J1>
export JUDGE_API_KEY=<J1 key>
export JUDGE_BASE_URL=<J1 base url,必须显式写>
```

`~/qc-eval/cand.env`:生成侧换成候选模型(B1-B3),**并 `unset` 掉另一协议遗留的变量**。例如候选走 openai 协议:
```bash
set -a; source <repo 绝对路径>/backend/.env; set +a
unset ANTHROPIC_BASE_URL ANTHROPIC_MODEL ANTHROPIC_API_KEY
export AI_PROVIDER=openai
export OPENAI_API_KEY=<key>
export OPENAI_MODEL=<B2>
export OPENAI_BASE_URL=<B3>
# 裁判四行与 glm.env 完全相同
```

### Step 2 · 冒烟(每个模型 8 次调用)

```bash
( source ~/qc-eval/glm.env  && python -m evalkit.runner --case-limit 1 --skip-judge --no-cache --output-dir evalkit/runs/ab-smoke-glm )
( source ~/qc-eval/cand.env && python -m evalkit.runner --case-limit 1 --skip-judge --no-cache --output-dir evalkit/runs/ab-smoke-cand )
```

检查各自 `meta.json` 的 `provider` / `model` 是否就是你以为的那个模型。
**停止条件**:鉴权失败、404、`model` 字段不对 → 停,报告给用户修配置。8 条全部 `error` 也停。

再单独验证裁判能通(1 盘,带裁判):
```bash
( source ~/qc-eval/glm.env && python -m evalkit.runner --case-limit 1 --output-dir evalkit/runs/ab-smoke-judge )
```
确认 `meta.json` 的 `judge_model` 正确,`results.jsonl` 里有 `l3` 分数。冒烟 run 的目录**保留**,一起交回。

### Step 3 · 简体全量 · GLM

```bash
( source ~/qc-eval/glm.env && \
  python -m evalkit.runner --no-cache --output-dir evalkit/runs/ab-glm-zh 2>&1 | tee ~/qc-eval/ab-glm-zh.log )
```

用 `--no-cache` 是为了防止命中历史 run 留下、身份可能贴错标签的缓存。

### Step 4 · 简体全量 · 候选

```bash
( source ~/qc-eval/cand.env && \
  python -m evalkit.runner --no-cache --output-dir evalkit/runs/ab-cand-zh 2>&1 | tee ~/qc-eval/ab-cand-zh.log )
```

两个 run 不要并行跑(避免限流互相干扰延迟数据)。

### Step 5 · 英文 / 繁体抽查(4 盘 × 8 模块 × 2 语言 × 2 模型 = 128 次)

evalkit 只渲染简体,这里用一个**仓库外**的临时脚本,把渲染语言换成 `en` / `zh-hant` 后复用同一条流水线。L1/L2 判据是按简体设计的,在英文和繁体上可能误报——**这部分的 verdict 只作参考,真正要看的是原文**,所以跳过裁判。

`~/qc-eval/lang_run.py`(原样保存,不要放进仓库):
```python
"""三语抽查:把 evalkit 的渲染语言换成 en / zh-hant,其余流水线不变。仓库外临时脚本。"""
import asyncio
import functools
import json
import sys
from pathlib import Path

sys.path.insert(0, ".")  # 在 backend/ 下执行

import evalkit.runner as runner
from app.ai.prompts import render_prompt

lang, out_dir = sys.argv[1], Path(sys.argv[2])
assert lang in ("en", "zh-hant"), lang

# 抽 4 盘:普通 2 + 专旺 1 + 从格 1(原 CASES 下标 0 / 4 / 15 / 17)
picked = [0, 4, 15, 17]
runner.CASES = [runner.CASES[i] for i in picked]
runner.render_prompt = functools.partial(render_prompt, language=lang)

summary = asyncio.run(runner.execute_run(
    case_limit=None, run_id=out_dir.name, runs_dir=out_dir.parent,
    no_cache=True, skip_judge=True,
))
(out_dir / "lang_meta.json").write_text(json.dumps(
    {"language": lang, "original_case_indices": picked,
     "note": "case_XX 按抽样后的顺序重新编号,对应原 CASES 下标见 original_case_indices"},
    ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps({k: summary[k] for k in ("run_id", "total", "pass", "warn", "fail", "error")}, ensure_ascii=False))
```

```bash
for L in en zh-hant; do
  ( source ~/qc-eval/glm.env  && python ~/qc-eval/lang_run.py $L evalkit/runs/ab-glm-$L  2>&1 | tee ~/qc-eval/ab-glm-$L.log )
  ( source ~/qc-eval/cand.env && python ~/qc-eval/lang_run.py $L evalkit/runs/ab-cand-$L 2>&1 | tee ~/qc-eval/ab-cand-$L.log )
done
```

**停止条件**:脚本在调用任何模型之前就报错(import 失败、模板缺失 `FileNotFoundError`)→ 停,原样报告。不要修改脚本去绕过,模板缺失本身就是需要用户知道的仓库问题。

### Step 6 · 机器可算的汇总(执行者自己算,填进报告)

对 `ab-glm-zh` 和 `ab-cand-zh` 各算一遍(用 `results.jsonl`):

1. verdict 分布:pass / warn / fail / error 各多少(总 160)
2. **按模块**的 pass 率(M0-M7 各 20 条)
3. **按盘类别**的 pass 率:用 `results.jsonl` 的 `category` 字段区分 `normal`(case_00-14)和 `special_pattern`(case_15-19)
4. L1 / L2 failure 原因的 Top 10(原样引用 failure 文案并计数)
5. JSON 解析失败条数(failure 文案含「JSON 解析失败」)
6. L3:7 个维度各自的平均分(两边都 pass、都被裁判打过分的条目才计入),外加两边**同一 (case, module)** 都有分的条目数
7. 延迟:`elapsed_ms` 的中位数 / P90 / 最大值,按模块拆分
8. 成本:从两家控制台读出本次的 token 用量和费用(读不到就写「未取得」,**不要估算**)

三语抽查(4 个 run)只算第 1 和第 5 项。

---

## 5. 交付

### 5.1 打包原始数据,推送到独立分支

```bash
cd <repo 根目录>
git checkout -b eval/model-ab-$(date +%Y%m%d)
D=docs/model-eval/$(date +%Y%m%d)
mkdir -p $D
for r in ab-smoke-glm ab-smoke-cand ab-smoke-judge ab-glm-zh ab-cand-zh ab-glm-en ab-cand-en ab-glm-zh-hant ab-cand-zh-hant; do
  cp -R backend/evalkit/runs/$r $D/ 2>/dev/null || echo "缺 $r"
done
cp ~/qc-eval/*.log $D/
# 提交前:确认没有 key
grep -rIl -E "sk-[A-Za-z0-9]|api[_-]?key\s*[:=]\s*\S{12,}" $D && echo "!!! 发现疑似密钥,先处理再提交"
```

`evalkit/runs/` 被 gitignore 了,所以要**复制**到 `docs/model-eval/` 下再提交,不要 `git add -f` 原目录,也不要复制 `.cache/`。

再把报告(§5.2)写成 `$D/REPORT.md`,然后:
```bash
git add docs/model-eval
git commit   # 按仓库约定写三段式 body:Why / What / Impact
git push -u origin eval/model-ab-<日期>
```

### 5.2 `REPORT.md` 模板(照这个结构填)

```markdown
# 模型 A/B 评测报告 · <日期>

## 1. 运行身份
- 仓库 commit:
- GLM:provider / 真实型号 / base URL(不含 key)
- 用户当前生产 .env 的 ANTHROPIC_MODEL 实际值:
- 候选:provider / 型号 / base URL
- 裁判:provider / 型号 / base URL;与哪一方同家族:无 / GLM / 候选
- 各 run 的 meta.json 的 identity 是否与上述一致:是 / 否(不一致处:)
- 网络重试过的条目:(case, module, 原因)

## 2. 简体全量对比(160 条)
| 指标 | GLM | 候选 |
|---|---|---|
| pass / warn / fail / error | | |
| JSON 解析失败 | | |
| 普通盘 pass 率 | | |
| special_pattern 盘 pass 率 | | |
| 延迟中位 / P90 / 最大(ms) | | |
| 本次 token / 费用 | | |

### 2.1 按模块 pass 率
| 模块 | GLM | 候选 |
|---|---|---|
| m0_structure … m7_manual | | |

### 2.2 L1/L2 failure Top 10(各自)
### 2.3 L3 七维平均分(配对条目数 = N)

## 3. 三语抽查(4 盘 × 8 模块)
| run | pass / warn / fail / error | JSON 解析失败 |
|---|---|---|

## 4. 执行者的主观观察(可选,标明是主观)
- 读了哪些条目的原文、看到了什么。**不要给出「该换 / 不该换」的结论**,那是评审的工作。

## 5. 异常与偏差
- 所有没按本手册执行的地方、所有停止过的点、所有你不确定的地方。
```

### 5.3 交回给用户的一句话

告诉用户:分支名 + `docs/model-eval/<日期>/REPORT.md` 的路径 + 有没有遇到停止条件。用户会把分支名转交给评审者。

---

## 6. 调用量与预算估算

| 阶段 | 生成 | 裁判 | 小计 |
|---|---|---|---|
| 冒烟(2 模型 × 8 + 裁判冒烟 8 生成 + ≤8 裁判) | 24 | ≤8 | ~32 |
| 简体全量 · GLM | 160 | ≤160 | ≤320 |
| 简体全量 · 候选 | 160 | ≤160 | ≤320 |
| 三语抽查 | 128 | 0 | 128 |
| **合计** | **472** | **≤328** | **≤800** |

裁判只评 L1/L2 都通过的条目,所以裁判的实际调用次数通常少于上限。命书模块输出偏长,费用以控制台实际读数为准。

---

## 7. 评审者会看什么(让执行者知道哪些数据不能缺)

评审者会重点抽读原文,所以下面这些**必须完整交回**:

- 两边 special_pattern 盘(case_15-19)全部 8 个模块的 `response.json`:看模型能不能守住「喜忌留空、不硬判、诚实降级」
- 所有 L2 failure 条目的 `prompt.txt` + `response.json`:判断是真越界还是判据误报
- 三语抽查全部原文:看英文是否自然、术语是否与引擎一致、繁体有没有混入简体或大陆用语
- 每个 run 的 `meta.json`:核对身份,防止「以为在测 A,其实在测 B」
