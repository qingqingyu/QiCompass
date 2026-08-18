# S05 L3 LLM 裁判

- **类型**: AFK
- **Blocked by**: S04
- **覆盖决策**: Q3(判据分层 — L3)、Q4(裁判配置)
- **Parent**: `docs/prompt评测机设计决策.md`

> L3 只判 L1/L2 判不了的:术语准确性 / 是否读着像算命软件 / 行文是否有洞察。**能沉到 L2 的判据不要留在这里**。

## What to build

### 1. `backend/evalkit/rubric.py`

把 `spikes/prompt_validation/eval_prompt.md`(已写好的 7 维 rubric)代码化。

- `RUBRIC_VERSION: int = 1` — **rubric 改必 bump**。老分数不与新分数比,同 `PROMPT_VERSIONS` bump 让缓存自然失效的思路
- `JUDGE_TEMPLATE` — 模板文本,占位符与 `eval_prompt.md` 一致:
  `day_master_strength` / `favorable_elements` / `unfavorable_elements` / `element_balance` / `shensha_list` / `current_luck_pillar` / `current_year_pillar` / `tiaoshou_applied` / `pattern_hint` / `llm_response` 等
- `build_judge_prompt(module, parsed_output, engine_result) -> str` — 从 `engine_result` 组 ground truth 段 + 塞 LLM 输出
- 用 `str.format_map` + 严格 dict(缺 key 抛清晰 KeyError),**照抄 `app/ai/prompts.py:695 _StrictFormatDict` 的做法**,不静默填空

**7 个维度**(原样保留,各 1-5 分):五行完整 / 十神配置 / 神煞准确 / 大运流年 / 无硬性格局 / 严格遵守后端喜忌 / special_pattern 诚实(普通盘 N/A,不计入 overall)。

> **注意重叠**:「神煞准确」「无硬性格局」「严格遵守后端喜忌」「special_pattern 诚实」四维已被 S03 的 L2 用确定性判据覆盖。**保留它们做交叉验证**——L2 说过、L3 也说过的,是高置信度问题;只有 L3 说的,要人工判断是真问题还是裁判幻觉。这个重叠是有意的,不要为了省 token 删掉。

### 2. `backend/evalkit/judge.py`

- `create_judge_client()` — 复用 `app/ai/client.py:create_ai_client()`,**只喂不同参数,不新写 HTTP client**
- `async def judge_one(module, parsed_output, engine_result, judge_client) -> JudgeResult`
- **严格 JSON 解析**:复用 S01 迁入的 `parse_llm_json()`;解析失败 → **显式 raise,不给默认分**
  - 这是 CLAUDE.md「禁止用默认值掩盖失败」最直白的一条:给个默认 3 分会让一个坏掉的裁判看起来在正常工作
  - 解析失败的条目 `verdict` 记 `"error"`,与质量 fail 区分
- 校验返回结构:`scores` 七键齐、每项 1-5 或 `"N/A"`、`overall` 为数字、`failures` 为 list;缺项或越界同样 raise
- 并发:同一盘的 8 个模块可并发裁判(裁判之间无依赖,不同于生成阶段的链式约束)。用 `asyncio.gather` + 信号量限并发,默认 4

### 3. 配置(Q4)

`backend/app/config.py` **尾部追加**,沿用现有 `os.environ.get(...) or 默认` + 空值显式 raise 的写法:

```
JUDGE_PROVIDER   默认 = AI_PROVIDER
JUDGE_MODEL      默认 = 对应 provider 的默认模型
JUDGE_API_KEY    默认 = 对应 provider 的 key
```

- 三个都有默认值,**不影响现有启动**(现有部署不设这些 env 时行为不变)
- 校验风格对齐现有:非法 provider / 空 model 显式 raise
- ADR-0010「AI provider 单选无 fallback」在评测侧同样适用:judge provider 单选,不做 fallback
- **这是本系列唯一允许改 `app/` 的地方**,且只在文件尾部追加常量,不改任何既有逻辑

### 4. runner / store 接线

- `--skip-judge` 跳过 L3(默认**开启裁判**;S04 阶段的 `l3: null` 行为由此标志保留)
- `results.jsonl` 的 `l3` 字段:
  ```jsonc
  "l3": {
    "scores": {"五行完整": 5, "十神配置": 4, ..., "special_pattern_诚实": "N/A"},
    "overall": 4.3,
    "failures": ["十神配置: 引用了后端未给的正财"],
    "passed": true,
    "judge_provider": "...", "judge_model": "...", "rubric_version": 1
  }
  ```
- `verdict` 补全(S04 留的口子):L1/L2 任一 fail → `fail`;`error` 非空 → `error`;否则 L3 `overall >= 4.0` → `pass`,`< 4.0` → `warn`
- `RunIdentity` 的 `rubric_version` / `judge_model` 从占位值改为真实值

## 裁判校准(本 slice 的硬验收)

**裁判本身需要被验证**。一个给编造内容打 5 分的裁判比没有裁判更糟——它提供虚假的安全感。

分三步放开,不要一上来跑全量:

1. `--case-limit 1 --skip-judge=false` — 1 盘 × 8 模块,验证链路通、JSON 解析稳
2. **人工校准**:取上一步的 8 条裁判输出,逐条人读。重点看三件事:
   - 裁判给明显编造的输出打了高分吗?(可故意手改一条 response.json 塞进"天医"神煞,看裁判是否扣「神煞准确」)
   - 裁判的扣分理由是否引用了具体原文,还是空泛套话?
   - 与 L2 的判定是否矛盾?矛盾处以 L2 为准(确定性判据优先),并记录到交付报告
3. 校准不过关 → **先修 rubric 再谈基线**,不要带着坏裁判跑全量

## Acceptance criteria

- [ ] `rubric.py` 建成,`RUBRIC_VERSION = 1`,7 维模板与 `eval_prompt.md` 逐项一致
- [ ] 模板渲染用严格 dict,缺 key 抛清晰 KeyError(照抄 `_StrictFormatDict` 做法)
- [ ] `judge.py` 复用 `create_ai_client()`,**代码内无新 httpx 调用**(review 时 grep 确认)
- [ ] 裁判 JSON 解析失败 → **raise,不给默认分**;结构校验(七键齐 / 1-5 或 N/A / overall 数字)同样 raise
- [ ] `app/config.py` 追加三个 JUDGE_* env,**不设时行为与现在完全一致**;`pytest backend/tests/` 全绿证明无回归
- [ ] `--skip-judge` 生效;裁判并发有信号量上限
- [ ] `verdict` 四态(pass / warn / fail / error)判定正确
- [ ] `RunIdentity` 的 `rubric_version` / `judge_model` 为真实值,变更任一 → 新 run 身份
- [ ] **裁判校准三步完成**,校准结论写进交付报告(含故意注入编造内容的那次验证结果)
- [ ] 跨 provider 验证:至少跑通一次「Anthropic 生成 / OpenAI 裁判」或反向
- [ ] 单测全绿(见「测试」)

## 实现锚点(现状快照 2026-08-17,实施以代码为准)

- `backend/spikes/prompt_validation/eval_prompt.md` — **7 维 rubric 原文**,含每维 1/3/5 分的判定标准与严格 JSON 输出格式。代码化时逐项对照
- `backend/app/ai/client.py`
  - `:22 async def interpret(prompt, *, temperature=0.6, max_tokens=None, timeout=None) -> str`
  - `:29 create_ai_client(provider, anthropic_api_key, anthropic_model, openai_api_key, openai_model, openai_base_url, anthropic_base_url)` — 裁判 client 走这里
- `backend/app/config.py`
  - `:18 AI_PROVIDER`(含非法值 raise 的写法)/ `:27-36` 各 key 与 model / `:38-43` 空值 raise —— JUDGE_* 追加时**照这个风格写**
- `backend/app/ai/prompts.py:695 _StrictFormatDict` — 缺 key 抛清晰 KeyError 的做法,rubric 渲染照抄
- `backend/evalkit/runner.py:parse_llm_json`(S01 迁入)— 裁判响应解析复用
- `backend/tests/test_anthropic_client.py` / `test_openai_client.py` / `test_ai_client_factory.py` — client 测试风格参考(含 mock 方式)
- `backend/tests/fixtures/mock_ai.py` — 既有 mock AI client,裁判单测复用
- `docs/adr/0010-ai-provider-single-no-fallback.md` — provider 单选无 fallback

## 红线与约束

- **不给默认分**:解析或结构校验失败一律 raise。这是本 slice 最重要的一条
- **不新写 HTTP client**:裁判走 `create_ai_client()`
- **rubric 版本化**:rubric 改必 bump `RUBRIC_VERSION`,老分数不与新分数比
- **保留 L2/L3 重叠**:四个重叠维度是有意的交叉验证,不为省 token 删
- **L2 优先**:L2 与 L3 判定矛盾时以 L2 为准(确定性判据 > 概率判据),矛盾记录进报告
- **`app/config.py` 只追加不改**:三个 env 全有默认值,现有部署零感知
- **不擅自加依赖**:`asyncio` 标准库,不引并发框架
- **不碰 `PROMPT_VERSIONS`**:评测机只读

## 测试

新增 `backend/tests/test_evalkit_judge.py`,**用 mock client,零真实 API 调用**:

- rubric 渲染:缺 context key → `pytest.raises(KeyError)`,错误信息含占位符名
- mock 裁判返回合法 JSON → `JudgeResult` 字段正确
- mock 返回被 ```json fence 包裹 → 正常解析(复用 `parse_llm_json`)
- mock 返回非 JSON 文本 → `pytest.raises`,**不返回默认分**
- mock 返回缺维度 / 分数越界(如 7)/ `overall` 为字符串 → 各自 `pytest.raises`
- `special_pattern_诚实` 为 `"N/A"` 时不计入 `overall` 平均
- `--skip-judge` 时 `l3` 为 `null` 且零 client 调用
- `verdict` 四态参数化:各 L1/L2/L3/error 组合 → 期望 verdict

新增 `backend/tests/test_evalkit_config.py`:不设任何 JUDGE_* env 时,三个常量回落到 `AI_*` 对应值。

手工验收(需 API key):裁判校准三步(见上文),结论进交付报告。
