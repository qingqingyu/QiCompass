# S05 iOS 三柱盘展示 + 时柱列留白

- **类型**: AFK
- **Blocked by**: S01(契约);可与 S04 并行
- **覆盖决策**: D7 触点 1(命盘时柱列留白 dashed)/ 契约备注(pillars.hour 显式 null 的 iOS 消费)/ D5(三柱照常展示)
- **Parent**: `docs/时辰未知设计决策.md`

## What to build

1. **DTO Optional 化**(`BaziDTOs`):`Pillars.hour: PillarDTO?`;同时预留 S02 歧义标记字段的解码位(day/year/month unknown 表达、`year_branch_zodiac?`、神煞完整性标注)——全部 `decodeIfPresent`
2. **PillarsTable**:时柱列无数据 → 留白 + **dashed hairline 圆位**(DESIGN.md dashed=锁定/临时态语义,现成),点击进补时辰——**一期占位**(轻提示或 disabled,S10 接线);年/月/日柱 unknown(S02 歧义)→ 同款留白表达
3. **DualPillarsTable**(合盘对卡):同款 Optional 渲染
4. **`ChartPayloadDTO.from(baziResponse:)` 必须显式处理**(2026-09-01 review 补入,原分割漏项):`DailyFortuneOrchestrator.swift:355-372` 有两处会在 hour Optional 化后出事——`:362` `dayMasterStrength ?? "special_pattern"` 会把 `unknown_hour` **静默伪装成从格盘**(假精度,整个设计的前提被破坏);`:369` `PillarRefDTO(gan: p.hour.gan, …)` 强取 hour,Optional 化后编译不过。**正确解法是 hour 缺失时不下发 `hour` 键**(S01 已扩 `ChartPayload` 契约允许缺省)+ strength 透传 `unknown_hour`,**禁止** `p.hour?.gan ?? ""` 这类兜底
5. **PromptContextBuilder unknown 分支**:`hour_known=false` 时全部 `hour_*` context key 走占位值(如「时辰未知」/空串,由 S06 模板语义决定)——共 **7 个**:builder `:52-57` 六个(`hour_gan/hour_zhi/hour_gan_element/hour_zhi_element/hour_shishen_gan/hour_hide_gan`)+ `:62` 的 `hour_nayin`(**勿漏**,deep REQUIRED 两者都查);builder 侧 key **只增不删**,保证 REQUIRED ⊆ builder keys 校验持续 PASS;日柱/年柱歧义对应 `day_*` / 年柱 key 同理
6. **其余展示**:五行统计/神煞列表消费后端降级输出(空列表/标注自然呈现);生肖 `year_branch_zodiac=null` 的生肖屏处理归 S08,本 slice 只保证不 crash
7. **深度解析 Tab 顶部 instant / anchor_sentence**:日主在缺时辰时完整(决策「反向事实」),照常展示;日柱歧义用户的表达(S07 全拦,不进内容页)

## Acceptance criteria

- [ ] 无时辰盘渲染:三柱正常 + 时柱列留白 dashed,无 crash 无 Optional 强解
- [ ] 时柱列点击:一期占位行为(不 crash,轻提示或无操作,注释标 S10 接线)
- [ ] 合盘对卡(若对内有无时辰盘,展示层)同款渲染
- [ ] PromptContextBuilder:hour_known=false 输出含全部 `hour_*` key(占位值),`python3 tools/check_prompt_sync.py` PASS(iOS builder keys 静态提取不受影响)
- [ ] S02 歧义标记(年/月/日 unknown)解码 + 留白渲染
- [ ] `ChartPayloadDTO.from` 对无时辰盘:`dayMasterStrength` 输出 `"unknown_hour"`(**不是** `special_pattern`)、`fourPillars` 不含 `hour` 键;有时辰盘输出与现状逐字段一致
- [ ] 全仓 grep 无 `p.hour?.` + `??` 形式的兜底(假精度回归)
- [ ] 老盘(hour 字段存在)渲染与现状一致
- [ ] XCTest:DTO 解码(null/缺字段/正常)/ 表格渲染分支 / context builder unknown 分支

## 实现锚点(现状快照 2026-08-31,实施以代码为准)

- `iOS/QiCompass/QiCompass/Networking/DTOs/BaziDTOs.swift:71` — `let hour: PillarDTO` 非 Optional
- `iOS/QiCompass/QiCompass/**/PillarsTable.swift:19` — 时柱列
- `iOS/QiCompass/QiCompass/**/DualPillarsTable.swift:153-156` — 对卡四柱
- `iOS/QiCompass/QiCompass/Services/PromptContextBuilder.swift` — `p.hour` 消费共 **10 处**:`:52-57`(6 个 `hour_*` key)+ `:62`(`hour_nayin`)+ `:216`(`pillarDict(p.hour)`)+ `:229`(`hour_stem`)+ `:234`(`hour_branch`,**原分割漏列**)
- `iOS/QiCompass/QiCompass/Services/DailyFortuneOrchestrator.swift:355-372` — `ChartPayloadDTO.from`(`:362` 静默兜底 / `:369` 强取 hour)
- `iOS/QiCompass/QiCompass/Shared/InkKit.swift` — dashed hairline 现成语义

## 红线与约束

- 留白是水墨表达不是错误提示:无红字无感叹号,dashed hairline + 空位
- 不猜:任何 unknown 柱禁止渲染占位干支(如「?」柱或默认柱)
- check_prompt_sync 必须跑且 PASS(CLAUDE.md 护栏,builder 是三份实现之一)
- 不动 `prompts.py`(那是 S06/S09)
- 一期轻提示(若采用)文案进 L10n / xcstrings(中英)

## 测试

- `iOS/Tests/` DTO 解码三态(null / 缺字段 / 正常)+ 渲染快照/分支断言 + context builder 用例
- `python3 tools/check_prompt_sync.py` PASS
