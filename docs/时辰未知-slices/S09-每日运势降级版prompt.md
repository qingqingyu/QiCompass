# S09 每日运势降级版 prompt

- **类型**: **HITL**(同 S06:evalkit 基线 + 降级叙事 voice 需用户过目;另 REQUIRED_FIELDS 变更牵动三边同步,判据需人工校准)
- **Blocked by**: S01(契约)、S06(降级叙事 voice 基准先在免费 2 章定调)
- **覆盖决策**: D5(每日运势降级提供:日柱×流日十神关系叙事,明示局限;日柱歧义者全拦)/ 契约备注(REQUIRED_FIELDS 三边同步 + evalkit + PV bump)
- **Parent**: `docs/时辰未知设计决策.md`

## What to build

1. **REQUIRED_FIELDS 收窄**(`app/ai/prompts.py` daily_fortune):现状硬含 `favorable_elements` / `unfavorable_elements` / `hour_pillars_with_relations` 等时柱依赖字段——收窄为「降级可用集」或按 context 分字段集(实现时定,**校验语义:未知时辰 context 不再要求喜忌类字段非空**);三边同步(CLAUDE.md:backend REQUIRED_FIELDS / iOS `PromptContextBuilder` / promo `context_builder.py`),`check_prompt_sync.py` PASS
2. **模板降级叙事**:日柱×流日十神关系(日主 vs 当日干支)为轴;明示「这份运势基于日柱推演,时辰与喜忌维度需准确出生时刻」;**删除场景**:12 时辰运势段(时辰柱不可得)不输出;LLM 边界:禁止自推喜忌
3. **PV bump**:`daily_fortune` +1(一次)
4. **evalkit**:无 regression(基线同 S06 前置);判据若因降级样本误报,修 `evalkit/checks/` 不改 BASELINE
5. **iOS 半边**:
   - 无时辰用户每日运势照常入口与生成(降级内容),末尾一行静默提示位预留(S10 接线文案)
   - **日柱歧义用户(hour_known=false + 日柱 unknown)每日运势全拦**:拦截页一句话 + 补时辰入口占位(REQUIRED_FIELDS 里 `day_master` / `day_pillar` / `day_relation` 全塌,免费降级不成立——决策 D5 明确)
6. **历史/缓存**:24h 缓存与 content_hash 语义自动适配(S01 hash 分叉);历史 7 天回看对无时辰盘照常(降级内容)

## Acceptance criteria

- [ ] 无时辰盘每日运势:可生成,内容为日柱×流日叙事 + 明示局限句;**无**喜忌结论、无 12 时辰段;禁词扫描照常
- [ ] 日柱歧义盘每日运势:拦截态,不发起 interpret 请求
- [ ] 有时辰盘:输出与现状一致(模板对正常 context 语义不变)
- [ ] REQUIRED_FIELDS 三边同步:`check_prompt_sync.py` PASS(含 promo 缺失自动 SKIP 场景)
- [ ] PV bump;evalkit 无 regression(或基线流程完成 + 裁决)
- [ ] 用户过目降级运势样例 ≥2 天(voice)
- [ ] XCTest:日柱歧义拦截分支 / 正常回归

## 实现锚点(现状快照 2026-08-31,实施以代码为准)

- `backend/app/ai/prompts.py:665-674` — daily_fortune REQUIRED_FIELDS(含 day_master/day_pillar/day_relation/hour_pillars_with_relations)
- `backend/app/ai/prompts.py` daily 模板 + `:39-60` `PROMPT_VERSIONS`
- `iOS/QiCompass/QiCompass/Services/DailyFortuneOrchestrator.swift` / `Features/DailyFortune/DailyFortuneViewModel.swift` — 生成入口(拦截位;注意 ViewModel 在 Features 不在 Services)
- `iOS/QiCompass/QiCompass/Services/PromptContextBuilder.swift` / `tmp/promo-site/context_builder.py` — 三边另两份
- `backend/evalkit/` + `docs/prompt评测机设计决策.md`

## 红线与约束

- REQUIRED_FIELDS 是三份实现之一,动了必跑 check_prompt_sync(CLAUDE.md 护栏)
- 不猜:日柱歧义宁可全拦,不做「猜一侧日主」的运势
- LLM 边界:降级叙事禁止自推喜忌
- 不动 bazi_deep / compatibility 模板

## 测试

- backend:REQUIRED 校验新语义用例 + 渲染断言(降级/正常)
- iOS:拦截分支 + 回归;evalkit 全量
