# S01 evalkit 骨架与 20 盘 fixture 迁移

- **类型**: AFK
- **Blocked by**: 无
- **覆盖决策**: Q1(范围 v1 M0-M7)、Q2(落点 `backend/evalkit/`)
- **Parent**: `docs/prompt评测机设计决策.md`

## What to build

把 `spikes/prompt_validation/`(一次性脚本)提炼为常驻模块 `backend/evalkit/`,先只做**生成链路**,判据层留给 S02/S03。

1. **`backend/evalkit/cases.py`** — 从 `spikes/prompt_validation/fixtures.py` **原样迁入**:
   - 20 盘规格(15 普通盘四季 × 强弱 / 2 专旺 / 3 从格),字段 `birth_datetime` / `gender` / `longitude` / `zi_hour_rule` / `category` / `expected_strength` / `season_note` / `pattern_hint` / `source`
   - **保留配额断言**(`assert len(...) == 20` / `_NORMAL_COUNT == 15` / `_SPECIAL_COUNT == 5`)——数量错了要立即崩,不静默
   - **保留已知 gap 注释**:从格只有 3 个(从火/从水/从土),缺从财或从杀第 4 盘。本 slice **不补**
   - 新增 `CASES_HASH`:对 20 盘规格的规范化 JSON 求 sha256,供 Q5 run 身份用
   - 保留 `parse_birth()`

2. **`backend/evalkit/runner.py`** — 从 `run_v1_chain_spike.py` 提炼(**取 async 正确的那条线**),搬运这些既有逻辑,不重新发明:
   - `parse_llm_json()` — 处理 markdown code fence 包裹的 JSON
   - `_build_chart_json()` — `build_v1_chart(engine_result)` + `json.dumps(ensure_ascii=False, indent=2)`
   - `_call_module()` / `_run_one_module()` — 渲染 + 调用 + 落盘
   - `run_chain_for_case()` — M0→M7 依赖图注入,依赖关系原样保留:

     ```
     M0 → structure_fingerprint / main_axis / core_loop / structure_type
     M1 ← M0
     M2 ← M0 + M1.innate + M1.defensive
     M3 ← M0
     M4 ← M0 + age + current_concern            (用户输入,见 _M4_USER_INPUT)
     M5 ← M0 + M1.innate + M3.ideal_life_structure + assets_summary + preference
     M6 ← M0 + M1.innate + M1.defensive + M2.threshold + M0.core_loop
     M7 ← M1.one_leverage + M2.switch_actions + M3.environment_checklist + M6.leverage
          (M7 不传 chart:基于 M1-M6 结论的总结,不再读盘)
     ```
   - `_DryRunPlaceholderClient` — dry-run 占位,被误调时显式 `RuntimeError`(保留这个行为,它是分流逻辑的守卫)
   - 固定 `now = datetime(2025, 1, 15, 12, 0, tzinfo=timezone.utc)` 构造 `BaziEngine`

3. **CLI 骨架**(`python -m evalkit.runner`):
   - `--dry-run` 不调 API,只验证排盘 + chart 构建 + prompt 渲染 + 链式注入流转
   - `--case-limit N` 只跑前 N 盘
   - `--modules m0_structure,m1_talent` 只跑指定模块(**逗号分隔;跳过的上游模块必须显式报错而非静默注入空值**)
   - `--output-dir`(默认 `evalkit/runs/<run_id>/`)
   - 输出格式对齐 `tools/check_prompt_sync.py`:`print("=" * 64)` 分隔、`结果: PASS/FAIL(N 项)`、退出码 `0`/`1`/`2`

4. **落盘布局**(为 S04 预留,本 slice 先只写 `results.jsonl` + 逐模块文件):
   ```
   evalkit/runs/<run_id>/
     meta.json                    # run 身份(Q5 六维)+ 起止 + 计数
     results.jsonl                # 每行 = 一个 (case, module)
     case_00/m0_structure/prompt.txt
     case_00/m0_structure/response.json
   ```

5. **标注老脚本失效** — `spikes/prompt_validation/run_spike.py` docstring **顶部**加一段:
   ```
   ⚠️ 已知失效(2026-08-17 审计):第 298 行同步调用 async 的 ai_client.interpret,
   真跑会把 coroutine 存进 result_entry 后被 json.dumps 炸掉。output_v1/results.jsonl
   全部 llm_response=null 即证据(只跑过 --dry-run)。
   本脚本服务老 3 模块,不在 evalkit 系列范围内,故只标注不修。
   v1 链式评测请用 backend/evalkit/(见 docs/prompt评测机设计决策.md)。
   ```
   **只改 docstring,不动代码**。

6. **`.gitignore`** 增补:`backend/evalkit/runs/` 忽略,但 `!backend/evalkit/runs/BASELINE` 例外(S04 才写入,此处先留规则)。

## Acceptance criteria

- [ ] `backend/evalkit/` 建成,`cases.py` / `runner.py` 可 `python -m evalkit.runner --help`
- [ ] `cases.py` 20 盘配额断言保留且通过;`CASES_HASH` 稳定(连跑两次同值)
- [ ] `python -m evalkit.runner --dry-run` 全 20 盘 × 8 模块跑通,零异常,退出码 0
- [ ] dry-run 产物齐:每个 `case_NN/<module>/prompt.txt` 存在且非空,`meta.json` 含 Q5 六维身份
- [ ] `--case-limit 3` / `--modules m0_structure` 生效;`--modules m1_talent`(缺上游 M0)**显式报错**,不静默注入空 fingerprint
- [ ] `run_spike.py` docstring 顶部有失效标注,**代码零改动**(`git diff` 只有 docstring 行)
- [ ] `.gitignore` 规则就位
- [ ] 现有测试全绿:`cd backend && pytest`(确认没影响 30 用例对盘与既有 spike 测试)

## 实现锚点(现状快照 2026-08-17,实施以代码为准)

- `backend/spikes/prompt_validation/fixtures.py` — 20 盘 fixture 源,整份迁移
- `backend/spikes/prompt_validation/run_v1_chain_spike.py` — 提炼源:
  - `:115 parse_llm_json()`
  - `:257 _build_chart_json()`
  - `:263 _call_module()`(async)
  - `:292 run_chain_for_case()`
  - `:479 _run_one_module()`
  - `:527 run_spike()`(async,`asyncio.run()` 入口在 `:651`)
  - `:586 _DryRunPlaceholderClient`
  - `:75 _M4_USER_INPUT` / `:80 _M5_USER_INPUT` — M4/M5 的固定用户输入
  - `:88 _DRY_RUN_PLACEHOLDERS` / `:103 _apply_dry_run_placeholders()`
- `backend/app/engine/bazi_engine.py` — `BaziEngine.calculate(birth, gender, longitude, zi_hour_rule)`,返回 dict 含 `content_hash` / `day_master_strength` / `favorable_elements` / `unfavorable_elements` / `element_balance` / `shensha` / `pattern_hint` / `tiaoshou_applied`(见 `:184-193`)
- `backend/app/ai/prompts.py` — `render_prompt(module, context, language="zh")` / `validate_context(module, context)` / `PROMPT_VERSIONS` / `REQUIRED_FIELDS`(`:654` 起,v1 模块 `m0_structure` ~ `m7_manual` 在其尾部)
- `backend/app/ai/client.py:22` — `async def interpret(...)`,**必须 await**
- `backend/spikes/prompt_validation/run_spike.py:298` — 待标注的失效点
- `tools/check_prompt_sync.py` — CLI 输出/退出码 house style 参考
- `backend/tests/test_v1_chain_spike_helpers.py` — 既有 spike helper 测试,迁移后确认不破

## 红线与约束

- **提炼不重写**:`parse_llm_json` / 依赖图 / dry-run 分流全部搬运,改动仅限于适配新目录与新 CLI。重写等于丢掉已验证过的逻辑
- **async 必须 await**:这正是 `run_spike.py` 踩的坑,迁移时不能复现
- **确定性**:固定 `now`,不用 `datetime.now()`
- **错误显式传播**:排盘失败 / 渲染失败 / API 失败分别记进 `error` 字段并继续下一盘,但**不 catch 后当成功**;`--modules` 缺上游必须 raise
- **不碰生产**:不改 `app/` 下任何文件(`app/config.py` 的 JUDGE_* 留到 S05)
- **不改 `run_spike.py` 代码**:只加 docstring

## 测试

- `pytest backend/tests/` 全绿(回归确认)
- `python -m evalkit.runner --dry-run` 手工验收(本 slice 主要交付信号)
- 新增 `backend/tests/test_evalkit_cases.py`:断言 20 盘配额 + `CASES_HASH` 稳定性 + `parse_birth()` 往返
