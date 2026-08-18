# Prompt 回归评测机(evalkit)— 实施分割索引

Parent 设计事实源:`docs/prompt评测机设计决策.md`(Q1-Q9,ACCEPTED 待实施)。
本目录为 2026-08-17 分割产物:6 个 vertical slice,每个独立可验证。

## 实施顺序

| Slice | 标题 | Blocked by | 一句话 |
|---|---|---|---|
| S01 | [evalkit 骨架与 20 盘 fixture 迁移](S01-evalkit骨架与fixture迁移.md) | 无 | `cases.py` 迁 fixture,`runner.py` 从 chain spike 提炼,`--dry-run` 全 20 盘 × 8 模块跑通,老 `run_spike.py` 标失效 |
| S02 | [L1 确定性校验层](S02-L1确定性校验层.md) | S01 | 把 `validate_v1_module_output()` 包装为 `checks/deterministic.py`,正/反例单测,全程不调 API |
| S03 | [L2 接地校验层](S03-L2接地校验层.md) | S01(**与 S02 并行**) | 五类接地校验新写 + 手写正反例单测。**本系列价值核心** |
| S04 | [run 持久化、响应缓存与跨 run diff](S04-run持久化与跨run-diff.md) | S02、S03 | `store.py`:run 落盘 / 缓存命中 / diff 四分类;改一个模块只重跑它和下游 |
| S05 | [L3 LLM 裁判](S05-L3-LLM裁判.md) | S04 | `rubric.py` + `judge.py` + `RUBRIC_VERSION`,独立 judge env,先 `--case-limit 1` 真跑验证 + 裁判校准 |
| S06 | [本地 Web UI 与首轮基线](S06-本地WebUI与首轮基线.md) | S04(S05 后收尾最佳) | `server.py` + `static/index.html`,跑首轮基线写 `runs/BASELINE`,CLAUDE.md 增补守护栏 |

依赖图(合法 DAG,无环):

```
S01 ──┬─→ S02 ──┐
      └─→ S03 ──┴─→ S04 ──→ S05 ──→ S06
                      └──────────────↗
```

## 全系列红线(每个 slice 文档内均有)

- **确定性**:固定 `now`(chain spike 已用 `datetime(2025, 1, 15, 12, 0, tzinfo=timezone.utc)`)保证当前大运/流年不随真实时间漂移;同输入 + 同 run 身份 → 同结果
- **错误显式传播**:裁判 JSON 解析失败**显式报错,不给默认分**;API 调用失败记进 `error` 字段不吞;CLI 检出退化必须非零退出。禁止空 catch / 用默认值掩盖失败
- **不擅自加依赖**:**零新依赖**。fastapi / uvicorn / httpx / pytest / pytest-asyncio 全部已在 `backend/requirements.txt`
- **不碰生产**:不改 `app/main.py`;不改 `PROMPT_VERSIONS`(评测机只读,bump 是人的决定);不扩生产禁词表 `ABSOLUTE_CONCLUSIONS`;evalkit 不进生产镜像
- **单一事实源**:神煞清单取 `app/engine/shensha.py:240 SHENSHA_NAMES`,禁止复制第二份;L1 判据取 `validate_v1_module_output()`,禁止重写
- **module-agnostic**:`checks/` 层签名按 `(module, parsed_output, engine_result)` 设计,二期接老 3 模块不返工
- **prompt 三边一致性**:本系列**不动** `app/ai/prompts.py` 模板本体 / `PromptContextBuilder*.swift` / promo `context_builder.py`,不触发 `check_prompt_sync`;但 S06 增补的 CLAUDE.md 守护栏与之并列(同一套「本地拦截」文化)
- **视觉**:一切 UI 决策先读 `DESIGN.md`(纸白背景 / hairline / 4pt 圆角 / 朱砂点缀 / **无阴影无渐变** / 系统字体不打包)
- **CLI 输出风格**:对齐 `tools/check_prompt_sync.py`——`print("=" * 64)` 分隔、`结果: PASS/FAIL(N 项)`、退出码 `0` = 无退化 / `1` = 有退化 / `2` = 脚本自身错误

## 关键现状事实(实施前必读)

1. **`spikes/prompt_validation/run_spike.py` 从未真跑过,且真跑会失败**:`run_spike.py:298` 同步调用 `ai_client.interpret(...)`,但该方法在 `app/ai/client.py:22` 是 `async def`。证据:`output_v1/results.jsonl` 全部 20 行 `"llm_response": null`。该脚本服务老 3 模块,**本系列只标失效,不修**(S01)。
2. **`run_v1_chain_spike.py` async 用法正确**(`await ai_client.interpret(...)` + `asyncio.run()` 入口),是应该被提炼的那条线。
3. **20 盘 fixture 完好**,含配额断言(15 普通 + 2 专旺 + 3 从格 = 20),迁移时原样保留断言。
4. **已知 fixture gap**(`fixtures.py` 注释记录):从格盘只有 3 个(从火/从水/从土),方案原要求 4 个(缺从财或从杀)。本系列**不补**,原样继承 gap 并在 `cases.py` 保留该注释。

## 不做(勿在本系列实现)

老 3 模块接入(`bazi_deep` / `compatibility` / `daily_fortune`,二期)/ 多裁判投票 / 置信区间与显著性检验 / GitHub Actions / 扩展生产禁词表 / 自动 bump `PROMPT_VERSIONS` / 评测路由挂进生产 app / 修 `run_spike.py` 的 async bug / 补第 4 个从格 fixture / 任何新依赖。
