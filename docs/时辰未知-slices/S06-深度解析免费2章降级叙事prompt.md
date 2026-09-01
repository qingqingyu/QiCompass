# S06 深度解析免费 2 章降级叙事(prompt)

- **类型**: **HITL**(evalkit 首轮基线未定,「无 regression」判定前需先跑基线属真人步骤;降级叙事文案是产品 voice,需用户过目)
- **Blocked by**: S01(引擎输出 unknown_hour 语义)
- **覆盖决策**: D5(免费 2 章照给,降级叙事:日主为轴、不谈喜忌)/ 契约备注(prompt 双护栏 + PV bump)
- **Parent**: `docs/时辰未知设计决策.md`

## What to build

1. **模板降级分支**(`app/ai/prompts.py`,free 模板为 `BAZI_DEEP_FREE_TEMPLATE`):context 喜忌为空 / strength=unknown_hour 时,免费 2 章(性格底色 / 事业方向)的叙事依据从「喜忌」换成「日主×三柱结构」——模板写明:若上下文喜忌为空,如实按日主与年月日柱十神结构展开,**并诚实告知「时辰未知,喜忌与时柱分析需要准确出生时刻」**;禁止 LLM 推断喜忌或编造时柱影响(LLM 边界红线)。**机制镜像现成先例**:`render_prompt` 已有按 `day_master_strength` 条件追加约束段的机制——`day_master_strength == "special_pattern"` 时追加 `BAZI_DEEP_SPECIAL_PATTERN_SUFFIX`(从格诚实降级);unknown_hour 可同款做法(如 `BAZI_DEEP_UNKNOWN_HOUR_SUFFIX`,condition 为 `day_master_strength == "unknown_hour"`)。
   **但先例有一处不可照抄**(2026-09-01 review):`render_prompt` 现有实现在 `language != "zh"` 时对 special_pattern **直接 `raise FileNotFoundError`**(`prompts.py:811-820`)。`prompts/en/` 是已存在的活语言目录——照抄会让**每个英文用户 + 无时辰 = 硬报错**,不是降级解读。差别在概率:`special_pattern` 是罕见命局,拿 raise 当占位可以接受;`unknown_hour` 是本功能**刻意制造并主动引导**的常态。
   **要求**:zh / en **两份 suffix 同时落地**(或直接把降级指令写进各语言模板主体,绕开 suffix 拼接这条有历史债的路);无论哪种做法,`language="en"` 必须能渲染出完整 prompt,不得 raise
2. **PV bump**:`PROMPT_VERSIONS` 中 `bazi_deep` / `bazi_deep_free` / `bazi_deep_paid` 统一 +1(同次产品迭代一次 bump:free 叙事变化最大;paid 内容未变但一并 bump,老缓存随新版本号自然失效)
3. **双护栏(CLAUDE.md)**:
   - `python3 tools/check_prompt_sync.py` PASS(REQUIRED_FIELDS 不动,builder keys S05 已保证)
   - `cd backend && python -m evalkit.runner` 无 regression——**基线未定则先跑首轮基线(20 盘 × 8 模块 + L2 人工复核,真人步骤,这是本 slice HITL 的原因之一)**;有 regression 走 eval.sh UI 逐条判断,禁止改 BASELINE 掩盖
4. **文案 voice 过目(用户)**:降级叙事样例输出(至少性格底色 + 事业方向各 1 篇)给用户确认——「专业不忽悠」的语气基准

**付费 8 章模板不动**(iOS 侧 S07 全拦,无时辰用户到不了付费内容;付费模板的 unknown 分支无意义)。

## Acceptance criteria

- [ ] hour_known=false 的 context 渲染 free 模板 → prompt 含诚实告知句 + 日主为轴的叙事指令,不含「按喜忌展开」类硬引用
- [ ] hour_known=true 的 context 渲染 → 模板输出与现状语义一致(正常用户零变化)
- [ ] PV 三 key bump;evalkit 响应缓存按新 prompt hash 只重跑 deep 系列
- [ ] `check_prompt_sync.py` PASS;evalkit 无 regression(或基线流程完成 + 退化逐条裁决)
- [ ] 真实跑 ≥1 盘无时辰样本:输出不出现喜忌结论、不出现时柱内容、有明示局限句;禁词扫描照常过
- [ ] **`language="en"` + unknown_hour context 渲染成功**(不 raise FileNotFoundError),英文 prompt 尾部不出现中文 suffix
- [ ] `language="en"` + special_pattern 的现状行为不被本 slice 改变(该 raise 是既有债,不在本 slice 范围;若顺手补则需单独说明)
- [ ] 用户过目降级叙事样例并认可(voice 基准)

## 实现锚点(现状快照 2026-08-31,实施以代码为准)

- `backend/app/ai/prompts.py:626-642` — `_BAZI_DEEP_REQUIRED_FIELDS`(REQUIRED 不动,S05 保证 builder keys)
- `backend/app/ai/prompts.py:108-136` — `BAZI_DEEP_FREE_TEMPLATE`(免费 2 章模板,`_BAZI_DEEP_HEADER` 拼接)
- `backend/app/ai/prompts.py:39-60` — `PROMPT_VERSIONS`(bazi_deep / bazi_deep_free / bazi_deep_paid 三 key)
- `backend/app/ai/prompts.py:175-181` + `:811-823` — `BAZI_DEEP_SPECIAL_PATTERN_SUFFIX` 常量 + `render_prompt` 按 `day_master_strength == "special_pattern"` 条件追加的现成机制(**unknown_hour 分支直接镜像此先例**)
- `backend/evalkit/`(runner / eval.sh)+ `docs/prompt评测机设计决策.md`
- 参考先例:`docs/合盘五行共振章节决策.md` 的 prompt_version 一次 bump 策略

## 红线与约束

- LLM 只润色不判断:喜忌 unknown 由引擎给出,模板禁止诱导 LLM 自行推喜忌
- 有 regression 禁止改 BASELINE 掩盖(CLAUDE.md)
- 不动 `compatibility` / `daily_fortune` 模板(S09 另做)
- 中文模板为源,iOS/promo 是消费者

## 测试

- 渲染断言用例:unknown context 下含告知句 / 正常 context 与旧语义一致
- evalkit 全量跑通 + L2 抽查(基线流程)
